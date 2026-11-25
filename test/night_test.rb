# frozen_string_literal: true

require "test_helper"

# End-to-end self-test: a whole night on a toy Ruby repo, driven by the deterministic fake agent
# (adapters/fake_agent.rb). Every task is something a real agent does at night; the harness must
# handle each one. The night is run once (NightFixture) and each test checks one outcome.
module NightFixture
  CHECK = %(require_relative "../../src/calc"\n)

  # Ruby source for the fake agent's notes: "\n" here is a literal backslash-n, which the
  # fake agent turns into a newline.
  def self.method_src(signature, body) = "def #{signature}\\n  #{body}\\nend\\n"

  TASKS = [
    { "id" => "T01", "title" => "add", "checks" => ["ruby tests/acceptance/check_add.rb"],
      "notes" => TestHelpers.fake("append src/calc.rb <<<#{method_src('add(a, b)', 'a + b')}>>>") },
    { "id" => "T02", "title" => "div (fails once, then right)", "checks" => ["ruby tests/acceptance/check_div.rb"],
      "dependsOn" => ["T01"],
      "notes" => TestHelpers.fake("append@1 src/calc.rb <<<#{method_src('div(a, b)', 'a * b')}>>>",
                                  "append@2 src/calc.rb <<<#{method_src('div(a, b)', 'a / b')}>>>") },
    { "id" => "T03", "title" => "neg but tampers with a test", "checks" => ["ruby tests/acceptance/check_neg.rb"],
      "notes" => TestHelpers.fake("tamper tests/acceptance/check_add.rb",
                                  "append src/calc.rb <<<#{method_src('neg(a)', '-a')}>>>") },
    { "id" => "T04", "title" => "mul hard-coded", "checks" => ["ruby tests/acceptance/check_mul.rb"],
      "holdout" => { "files" => ["tests/holdout/check_mul_hidden.rb"],
                     "checks" => ["ruby tests/holdout/check_mul_hidden.rb"] },
      "notes" => TestHelpers.fake("append src/calc.rb <<<#{method_src('mul(a, b)', '6')}>>>") },
    { "id" => "T05", "title" => "pw but hangs", "checks" => ["ruby tests/acceptance/check_pow.rb"],
      "notes" => TestHelpers.fake("sleep 30") },
    { "id" => "T06", "title" => "sq, agent commits itself", "checks" => ["ruby tests/acceptance/check_sq.rb"],
      "notes" => TestHelpers.fake("append src/calc.rb <<<#{method_src('sq(a)', 'a * a')}>>>", "commit",
                                  "say DONE: all tests pass, trust me") },
    { "id" => "T07", "title" => "sub breaks add", "checks" => ["ruby tests/acceptance/check_sub.rb"],
      "dependsOn" => ["T01"],
      "notes" => TestHelpers.fake("write src/calc.rb <<<#{method_src('sub(a, b)', 'a - b')}>>>") },
    { "id" => "T08", "title" => "mod with skip marker", "checks" => ["ruby tests/acceptance/check_mod.rb"],
      "notes" => TestHelpers.fake("skip tests/unit/x_test.rb",
                                  "append src/calc.rb <<<#{method_src('mod(a, b)', 'a % b')}>>>") },
    { "id" => "T09", "title" => "abs, depends on blocked T03", "checks" => ["ruby tests/acceptance/check_abs.rb"],
      "dependsOn" => ["T03"], "notes" => TestHelpers.fake("append src/calc.rb <<<#{method_src('ab(a)', 'a.abs')}>>>") },
    { "id" => "T11", "title" => "tri, wrong path first", "checks" => ["ruby tests/acceptance/check_tri.rb"],
      "files" => ["src/tri.rb", "calc.rb"],
      "notes" => TestHelpers.fake(
        "write@1 toy/src/tri.rb <<<#{method_src('tri(n)', 'n * (n + 1) / 2')}>>>",
        %(guardlog@1 <<<{"kind": "path_repaired", "from": "k toy/src/calc.rb", "to": "src/calc.rb"}>>>),
        "write@2 src/tri.rb <<<#{method_src('tri(n)', 'n * (n + 1) / 2')}>>>"
      ) }
  ].freeze

  def self.data = @data ||= build

  def self.build
    tmp = Dir.mktmpdir("ns-selftest-")
    Minitest.after_run { FileUtils.rm_rf(tmp) unless ENV["NS_KEEP"] }
    log = File.join(tmp, "night.log")
    source = make_toy_repo(File.join(tmp, "toy"))
    state = File.join(tmp, "state")
    result = { "tmp" => tmp, "log" => log, "state" => state }
    TestHelpers.quietly(log) do
      result["init_rc"] = TestHelpers.ns("init", state, "--source", source, "--branch", "nightshift/test")
      configure(state)
      result["check_rc"] = TestHelpers.ns("check", state)
      result["approve_rc"] = TestHelpers.ns("approve", state)
      result["run_rc"] = TestHelpers.ns("run", state, "--max-iterations", "40")
    end
    project = Nightshift::Project.new(state)
    result.merge!("project" => project, "base" => project.lock["commit"], "state_json" => project.load_state,
                  "status" => TestHelpers.git(project.repo, "status", "--porcelain"),
                  "head" => TestHelpers.git(project.repo, "rev-parse", "HEAD"))
    result.merge!(crash_and_stop(project, log))
  end

  def self.make_toy_repo(src)
    w = ->(rel, text) { TestHelpers.write(File.join(src, rel), text) }
    w.call("src/calc.rb", "# calculator\n")
    {
      "add" => "abort unless add(2, 3) == 5 && add(-1, 1) == 0", "div" => "abort unless div(6, 3) == 2",
      "neg" => "abort unless neg(4) == -4", "mul" => "abort unless mul(2, 3) == 6",
      "pow" => "abort unless pw(2, 3) == 8", "sq" => "abort unless sq(3) == 9",
      "sub" => "abort unless sub(5, 3) == 2", "mod" => "abort unless mod(7, 3) == 1",
      "abs" => "abort unless ab(-2) == 2"
    }.each { |name, assertion| w.call("tests/acceptance/check_#{name}.rb", "#{CHECK}#{assertion}\n") }
    w.call("tests/acceptance/check_tri.rb", %(require_relative "../../src/tri"\nabort unless tri(3) == 6\n))
    w.call("tests/unit/x_test.rb", "# unit test placeholder\n")
    system("git", "init", "-q", "-b", "main", src, exception: true)
    TestHelpers.git(src, "add", "-A")
    TestHelpers.git(src, "-c", "user.name=t", "-c", "user.email=t@x", "commit", "-qm", "toy")
    src
  end

  def self.configure(state)
    cfg_file = File.join(state, "nightshift.yml")
    cfg = YAML.safe_load_file(cfg_file)
    cfg["roles"].merge!("worker" => "fake", "planner" => "fake")
    cfg["budgets"].merge!("until" => "", "hours" => 0, "max_consecutive_failures" => 50)
    cfg["server"]["health_url"] = ""
    cfg["adapters"] = { "fake" => { "timeout_min" => 0.1 } } # the hang in T05 must time out quickly
    File.write(cfg_file, YAML.dump(cfg))
    Nightshift::Util.write_json(File.join(state, "tasks.json"), { "tasks" => TASKS })
    TestHelpers.write(File.join(state, "holdout", "tests", "holdout", "check_mul_hidden.rb"),
                      "#{CHECK}abort unless mul(4, 5) == 20\n")
  end

  # Simulate a crash mid-attempt (dirty tree, inflight marker), plus a STOP file: the next run
  # must recover the repo and then stop at once.
  def self.crash_and_stop(project, log)
    repo = project.repo
    File.write(File.join(repo, "src", "calc.rb"), "garbage from a crashed attempt\n")
    File.write(File.join(repo, "junk.txt"), "x")
    st = project.load_state
    st["inflight"] = "crashed-attempt"
    project.save_state(st)
    File.write(project.stop_file, "stop")
    TestHelpers.quietly(log) { Nightshift::Night.new(Nightshift::Project.new(project.dir), fresh: true).run }
    FileUtils.rm_f(project.stop_file)
    { "crash_state" => project.load_state, "crash_status" => TestHelpers.git(repo, "status", "--porcelain") }
  end
end

class NightTest < Minitest::Test
  def data = NightFixture.data
  def project = data["project"]
  def repo = project.repo
  def task(id) = data["state_json"]["tasks"].fetch(id, {})
  def status(id) = task(id).fetch("status", "pending")
  def run_dir(glob) = Dir[File.join(project.runs, glob)].min
  def log_hint = "night log: #{data['log']} (set NS_KEEP=1 to keep it)"

  def test_init_check_and_approve
    assert_equal 0, data["init_rc"], log_hint
    assert_equal 0, data["check_rc"], "every acceptance check fails before work; plan valid. #{log_hint}"
    assert_equal 0, data["approve_rc"], log_hint
  end

  def test_honest_pass
    assert_equal "passed", status("T01"), log_hint
    assert_equal 1, task("T01")["attempts"]
  end

  def test_retry_gets_failure_note
    assert_equal "passed", status("T02"), log_hint
    assert_equal 2, task("T02")["attempts"]
    assert_includes File.read(File.join(run_dir("*-T02-a2"), "prompt.md")), "Attempt 1 failed"
  end

  # Warm handoff: the retry sees what the discarded attempt wrote and said; every task sees the
  # definitions that earlier kept tasks added.
  def test_retry_sees_what_the_failed_attempt_did
    prompt = File.read(File.join(run_dir("*-T02-a2"), "prompt.md"))

    assert_includes prompt, "It changed: `src/calc.rb`"
    assert_includes prompt, "`src/calc.rb: def div(a, b)`"
    assert_includes prompt, "Its last answer: \"DONE fake attempt 1\""
    assert_equal ["src/calc.rb: def div(a, b)"], task("T02")["tried"].first["defs"]
  end

  def test_later_tasks_see_what_earlier_tasks_added
    assert_equal ["src/calc.rb: def add(a, b)"], task("T01")["added"]
    assert_includes File.read(File.join(run_dir("*-T01-a1"), "prompt.md")), "(nothing yet)"
    assert_includes File.read(File.join(run_dir("*-T02-a1"), "prompt.md")), "- `src/calc.rb: def add(a, b)` (T01)"
  end

  def test_tampering_with_a_test_is_rejected
    assert_equal "blocked", status("T03"), log_hint
    assert_equal "integrity", task("T03")["blocked_gate"]
    refute_includes File.read(File.join(repo, "tests/acceptance/check_add.rb")), "tampered"
  end

  def test_hard_coding_caught_by_holdout
    assert_equal "blocked", status("T04"), log_hint
    assert_equal "holdout", task("T04")["blocked_gate"]
    note = File.read(project.failure_file("T04"))

    assert_includes note, "hidden acceptance test"
    refute_includes note, "mul(4, 5)", "hidden test content must not leak into the next prompt"
    refute_path_exists File.join(repo, "tests/holdout/check_mul_hidden.rb"), "holdout removed after verify"
  end

  def test_hang_times_out
    assert_equal "blocked", status("T05"), log_hint
    results = File.readlines(project.journal_file).map { |line| JSON.parse(line) }.select { |r| r["kind"] == "result" }

    assert(results.any? { |r| r["task"] == "T05" && r["timed_out"] })
  end

  def test_self_commit_folded_and_claims_ignored
    assert_equal "passed", status("T06"), log_hint
    subjects = TestHelpers.git(repo, "log", "--format=%s", "#{data['base']}..#{data['head']}").lines(chomp: true)

    refute_includes subjects, "fake", "the worker's own commit must be folded into the harness commit"
    assert_includes subjects, "T06: sq, agent commits itself"
  end

  def test_regression_blocks
    assert_equal "blocked", status("T07"), log_hint
    assert_equal "regression", task("T07")["blocked_gate"]
    assert_includes TestHelpers.git(repo, "show", "#{data['head']}:src/calc.rb"), "def add"
  end

  def test_skip_marker_rejected
    assert_equal "blocked", status("T08"), log_hint
    assert_equal "integrity", task("T08")["blocked_gate"]
  end

  def test_dependency_on_blocked_task_waits
    assert_equal "pending", status("T09"), log_hint
  end

  def test_wrong_path_recovered
    t11 = task("T11")

    assert_equal "passed", t11["status"], log_hint
    assert_equal(%w[paths all], t11["history"].map { |h| h["gate"] })
    assert_equal 1, t11["path_fixed"]
    refute_path_exists File.join(repo, "toy")
  end

  def test_wrong_path_feedback_reaches_the_next_attempt
    prompt = File.read(File.join(run_dir("*-T11-a2"), "prompt.md"))

    assert_includes prompt, "did you mean 'src/tri.rb'"            # stray-path gate
    assert_includes prompt, "the correct path is 'src/calc.rb'"    # guard log fed back
    assert_includes prompt, "`src/calc.rb` (exists; the plan said `calc.rb`)"
    assert_includes prompt, "`src/tri.rb` (new file)"
  end

  def test_repo_clean_and_report
    assert_empty data["status"]
    assert_equal data["state_json"]["head"], data["head"]
    report = File.read(project.report_file)

    assert_includes report, "| T04 |"
    assert_equal "no eligible task left", data["state_json"]["night"]["stop_reason"], log_hint
    assert_equal 1, data["run_rc"], "not every task passed, so the exit code is nonzero"
  end

  def test_crash_recovery_and_stop
    st = data["crash_state"]

    assert_equal "STOP file present", st["night"]["stop_reason"], log_hint
    assert_empty data["crash_status"], "dirty tree reset to the last good commit"
    assert_equal "", st["inflight"]
    refute_equal data["state_json"]["night"]["id"], st["night"]["id"], "a new night gets its own id"
    assert_includes File.read(project.report_file), "Attempts this night: 0", "report counts this night only"
  end
end
