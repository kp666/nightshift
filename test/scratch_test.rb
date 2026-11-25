# frozen_string_literal: true

require "test_helper"

# End-to-end: a project from scratch. `ns init --new` creates the repo, the planner (simulated
# here) writes the skeleton plus the plan, and a run builds the features on top of it with the
# fake agent. Runs once (ScratchFixture) and each test checks one outcome.
module ScratchFixture
  def self.method_src(signature, body) = "def #{signature}\\n  #{body}\\nend\\n"

  TASKS = [
    { "id" => "T01", "title" => "greet", "files" => ["lib/greeter.rb"],
      "description" => "Define greet(name) returning \"Hello, <name>!\" in lib/greeter.rb.",
      "checks" => ["ruby tests/acceptance/t01_greet.rb"],
      "holdout" => { "files" => ["tests/holdout/t01_greet_hidden.rb"],
                     "checks" => ["ruby tests/holdout/t01_greet_hidden.rb"] },
      # The single quotes are deliberate: this is Ruby source the fake agent writes into the repo.
      "notes" => TestHelpers.fake("write lib/greeter.rb <<<#{method_src('greet(name)', '"Hello, #{name}!"')}>>>") }, # rubocop:disable Lint/InterpolationCheck
    { "id" => "T02", "title" => "shout", "files" => ["lib/greeter.rb"], "dependsOn" => ["T01"],
      "description" => "Add shout(name) returning greet(name) in upper case.",
      "checks" => ["ruby tests/acceptance/t02_shout.rb"],
      "notes" => TestHelpers.fake("append lib/greeter.rb <<<#{method_src('shout(name)', 'greet(name).upcase')}>>>") },
    { "id" => "T03", "title" => "cli", "files" => ["bin/greet"], "dependsOn" => ["T01"],
      "description" => "bin/greet prints greet(ARGV[0]).",
      "checks" => ["ruby tests/acceptance/t03_cli.rb"],
      "notes" => TestHelpers.fake(
        %(write bin/greet <<<require_relative "../lib/greeter"\\nputs greet(ARGV.fetch(0))\\n>>>)
      ) }
  ].freeze

  REQUIRE = %(require_relative "../../lib/greeter"\n)

  def self.data = @data ||= build

  def self.build
    tmp = Dir.mktmpdir("ns-scratch-")
    Minitest.after_run { FileUtils.rm_rf(tmp) unless ENV["NS_KEEP"] == "1" }
    src = File.join(tmp, "greeter")
    state = File.join(tmp, "state")
    log = File.join(tmp, "scratch.log")
    r = { "tmp" => tmp, "src" => src, "log" => log }
    TestHelpers.quietly(log) do
      r["init_rc"] = TestHelpers.ns("init", state, "--source", src, "--new", "--branch", "nightshift/test")
      r["init_again_rc"] = without_stderr { TestHelpers.ns("init", File.join(tmp, "state2"), "--source", src, "--new") }
      configure(state)
      project = Nightshift::Project.new(state)
      r["prompt"] = planner_prompt(state)
      write_skeleton(project.repo)
      Nightshift::Util.write_json(project.tasks_file,
                                  { "tasks" => [TASKS[0].merge("checks" => ["greetcheck t01"],
                                                               "holdout" => nil).compact] })
      r["missing_tool_rc"] = TestHelpers.ns("check", state)
      write_plan(project.repo)
      r["harvest_rc"] = TestHelpers.ns("plan", state, "--harvest")
      r["check_rc"] = TestHelpers.ns("check", state)
      r["approve_rc"] = TestHelpers.ns("approve", state)
      r["run_rc"] = TestHelpers.ns("run", state)
      r["project"] = project
    end
    r.merge("state_json" => r["project"].load_state,
            "log_lines" => TestHelpers.git(r["project"].repo, "log", "--format=%s").lines(chomp: true))
  end

  # `ns plan --print-prompt` also saves the prompt; read that copy.
  def self.planner_prompt(state)
    without_stderr { TestHelpers.ns("plan", state, "--print-prompt") }
    File.read(File.join(state, "planner-prompt.md"))
  end

  # Expected warnings and errors would only clutter the test output.
  def self.without_stderr
    saved = $stderr
    File.open(File::NULL, "w") do |null|
      $stderr = null
      yield
    end
  ensure
    $stderr = saved
  end

  def self.configure(state)
    cfg_file = File.join(state, "nightshift.yml")
    cfg = YAML.safe_load_file(cfg_file)
    cfg["roles"].merge!("worker" => "fake", "planner" => "fake")
    cfg["server"]["health_url"] = ""
    cfg["gates"]["global"] = ["ruby tests/run_all.rb"] # what the planner told the human to add
    File.write(cfg_file, YAML.dump(cfg))
  end

  # What the planner builds with the human: layout, a working test runner, AGENTS.md.
  def self.write_skeleton(repo)
    w = ->(rel, text) { TestHelpers.write(File.join(repo, rel), text) }
    w.call("AGENTS.md", "Ruby, stdlib only. Code in lib/, tests in tests/. Run: ruby tests/run_all.rb\n")
    w.call("lib/greeter.rb", "# Greetings.\n")
    w.call("tests/run_all.rb", %(Dir[File.join(__dir__, "unit", "*.rb")].each { |f| require f }\nputs "ok"\n))
    w.call("tests/unit/smoke.rb", "abort unless 1 + 1 == 2\n")
  end

  # The planner's output: visible tests in the repo, the plan and hidden tests in .nightshift-plan/.
  def self.write_plan(repo)
    w = ->(rel, text) { TestHelpers.write(File.join(repo, rel), text) }
    w.call("tests/acceptance/t01_greet.rb", %(#{REQUIRE}abort unless greet("Ann") == "Hello, Ann!"\n))
    w.call("tests/acceptance/t02_shout.rb", %(#{REQUIRE}abort unless shout("Ann") == "HELLO, ANN!"\n))
    w.call("tests/acceptance/t03_cli.rb",
           %(out = IO.popen([RbConfig.ruby, File.join(__dir__, "../../bin/greet"), "Bo"], &:read)\n) +
             %(abort unless out.strip == "Hello, Bo!"\n))
    w.call(".nightshift-plan/holdout/tests/holdout/t01_greet_hidden.rb",
           %(#{REQUIRE}abort unless greet("Zed") == "Hello, Zed!"\n))
    Nightshift::Util.write_json(File.join(repo, ".nightshift-plan", "tasks.json"), { "tasks" => TASKS })
  end
end

class ScratchTest < Minitest::Test
  def data = ScratchFixture.data
  def log_hint = "log: #{data['log']} (set NS_KEEP=1 to keep it)"

  def test_init_new_creates_a_committed_repo
    assert_equal 0, data["init_rc"], log_hint
    assert File.file?(File.join(data["src"], "README.md"))
    assert_equal ["Start greeter"], TestHelpers.git(data["src"], "log", "--format=%s").lines(chomp: true)
    assert_equal 1, data["init_again_rc"], "--new refuses an existing repo"
  end

  def test_planner_is_told_to_build_the_skeleton
    assert_includes data["prompt"], "This is a new project"
    assert_includes data["prompt"], "every dependency"
    assert_includes data["prompt"], "scope is the human's decision"
    refute_includes data["prompt"], "{{"
  end

  def test_check_rejects_a_check_whose_tool_is_missing
    assert_equal 1, data["missing_tool_rc"], log_hint
    assert_includes File.read(data["log"]), "command not found"
  end

  def test_plan_check_and_approve
    assert_equal 0, data["harvest_rc"], log_hint
    assert_equal 0, data["check_rc"], log_hint
    assert_equal 0, data["approve_rc"], log_hint
  end

  def test_run_builds_every_feature
    assert_equal 0, data["run_rc"], log_hint
    %w[T01 T02 T03].each do |id|
      assert_equal "passed", data["state_json"]["tasks"].dig(id, "status"), "#{id}: #{log_hint}"
    end
    repo = data["project"].repo
    out = IO.popen([RbConfig.ruby, File.join(repo, "bin", "greet"), "Cy"], &:read)

    assert_equal "Hello, Cy!", out.strip
  end

  def test_history_is_start_contract_then_one_commit_per_task
    lines = data["log_lines"]

    assert_equal "Start greeter", lines.last
    assert_match(/approve contract/, lines[-2])
    assert_equal 3, lines.count { |subject| subject.match?(/T0[123]/) }, lines.inspect
  end
end
