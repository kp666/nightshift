# frozen_string_literal: true

require "test_helper"

# `ns init --in-place`: no clone; the worker edits the user's own repo on its own branch. One
# night runs once (InPlaceFixture); each test checks one outcome. Tests that disturb the repo
# put it back in an ensure, so they do not depend on their order.
module InPlaceFixture
  BRANCH = "nightshift/inplace"
  ADD = ->(body) { "def add(a, b)\\n  #{body}\\nend\\n" } # "\n" is turned into a newline by the fake agent

  TASKS = [
    { "id" => "T01", "title" => "add (wrong once, so a reset runs)", "checks" => ["ruby tests/acceptance/check_add.rb"],
      "notes" => TestHelpers.fake("append@1 src/calc.rb <<<#{ADD.call('a - b')}>>>",
                                  "append@2 src/calc.rb <<<#{ADD.call('a + b')}>>>") }
  ].freeze

  def self.data = @data ||= build

  def self.build
    tmp = Dir.mktmpdir("ns-inplace-")
    Minitest.after_run { FileUtils.rm_rf(tmp) unless ENV["NS_KEEP"] }
    log = File.join(tmp, "night.log")
    source = make_repo(File.join(tmp, "app"))
    state = File.join(tmp, "state")
    main_before = TestHelpers.git(source, "rev-parse", "main")
    result = { "tmp" => tmp, "log" => log, "source" => source, "state" => state, "main_before" => main_before }
    TestHelpers.quietly(log) do
      result["init_rc"] = TestHelpers.ns("init", state, "--source", source, "--in-place", "--branch", BRANCH)
      configure(state)
      result["check_rc"] = TestHelpers.ns("check", state)
      result["approve_rc"] = TestHelpers.ns("approve", state)
      result["run_rc"] = TestHelpers.ns("run", state, "--max-iterations", "5")
    end
    result.merge("project" => Nightshift::Project.new(state))
  end

  # A committed repo with a remote (never contacted) and an ignored .env, as a real one has.
  def self.make_repo(src)
    TestHelpers.write(File.join(src, "src", "calc.rb"), "# calculator\n")
    TestHelpers.write(File.join(src, "tests", "acceptance", "check_add.rb"),
                      %(require_relative "../../src/calc"\nabort unless add(2, 3) == 5\n))
    TestHelpers.write(File.join(src, ".gitignore"), ".env\n")
    system("git", "init", "-q", "-b", "main", src, exception: true)
    TestHelpers.git(src, "add", "-A")
    TestHelpers.git(src, "-c", "user.name=t", "-c", "user.email=t@x", "commit", "-qm", "app")
    TestHelpers.git(src, "remote", "add", "origin", "https://example.invalid/app.git")
    TestHelpers.write(File.join(src, ".env"), "SECRET=1\n")
    src
  end

  def self.configure(state)
    cfg_file = File.join(state, "nightshift.yml")
    cfg = YAML.safe_load_file(cfg_file)
    cfg["roles"].merge!("worker" => "fake", "planner" => "fake")
    cfg["server"]["health_url"] = ""
    File.write(cfg_file, YAML.dump(cfg))
    Nightshift::Util.write_json(File.join(state, "tasks.json"), { "tasks" => TASKS })
  end
end

class InPlaceTest < Minitest::Test
  def data = InPlaceFixture.data
  def source = data["source"]
  def state = data["state"]
  def git(*) = TestHelpers.git(source, *)
  def log_hint = "night log: #{data['log']} (set NS_KEEP=1 to keep it)"

  def ns(*)
    rc = nil
    out, err = capture_io { rc = TestHelpers.ns(*) }
    [rc, out, err]
  end

  def test_init_works_in_the_repo_itself
    project = data["project"]

    assert_equal [0, 0, 0], data.values_at("init_rc", "check_rc", "approve_rc"), log_hint
    assert_predicate project, :in_place?
    assert_equal Nightshift::Util.norm(source), Nightshift::Util.norm(project.repo)
    refute_path_exists File.join(state, "repo")
  end

  def test_the_night_commits_on_the_branch_in_the_repo
    assert_equal 0, data["run_rc"], log_hint
    assert_equal InPlaceFixture::BRANCH, git("rev-parse", "--abbrev-ref", "HEAD")
    assert_includes git("log", "--format=%s", "-1"), "T01: add"
    assert_equal data["main_before"], git("rev-parse", "main")
    assert_empty git("status", "--porcelain")
  end

  def test_ignored_files_survive_resets
    assert_equal "SECRET=1\n", File.read(File.join(source, ".env")), "the reset after attempt 1 must keep ignored files"
  end

  def test_run_refuses_to_discard_files_it_did_not_make
    data
    mine = File.join(source, "my-notes.txt")
    File.write(mine, "work in progress\n")
    rc, _, err = ns("run", state)

    assert_equal 1, rc
    assert_includes err, "never discards work it did not make"
    assert_path_exists mine
  ensure
    FileUtils.rm_f(mine)
  end

  def test_run_refuses_on_another_branch
    data
    git("switch", "-q", "-c", "my-feature")
    rc, _, err = ns("run", state)

    assert_equal 1, rc
    assert_includes err, "on branch my-feature"
  ensure
    git("switch", "-q", InPlaceFixture::BRANCH)
    git("branch", "-q", "-D", "my-feature")
  end

  def test_doctor_accepts_remotes_in_place
    rc, out, = ns("doctor", state)

    assert_equal 0, rc, out
    assert_includes out, "remotes: origin"
  end

  def test_land_needs_no_fetch
    rc, text, = ns("land", state)

    assert_equal 0, rc
    refute_includes text, "fetch"
    assert_includes text, "merge --no-ff #{InPlaceFixture::BRANCH}"
  end

  def test_init_refuses_a_dirty_repo_and_a_state_dir_inside_it
    tmp = Dir.mktmpdir("ns-inplace-refuse-")
    repo = InPlaceFixture.make_repo(File.join(tmp, "app"))
    File.write(File.join(repo, "untracked.txt"), "x")
    dirty_rc, _, dirty_err = ns("init", File.join(tmp, "s1"), "--source", repo, "--in-place")
    FileUtils.rm_f(File.join(repo, "untracked.txt"))
    inside_rc, _, inside_err = ns("init", File.join(repo, "state"), "--source", repo, "--in-place")

    assert_equal [1, 1], [dirty_rc, inside_rc]
    assert_includes dirty_err, "commit or stash them first"
    assert_includes inside_err, "put the state dir outside the repo"
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end
end
