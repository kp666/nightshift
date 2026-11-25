# frozen_string_literal: true

require_relative "test_helper"

# The command line itself: dispatch, option checks, exit codes, and the commands `land`
# prints. The commands' work is covered by night_test and scratch_test.
class CLITest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("ns-cli-")
    @state = File.join(@tmp, "state")
  end

  def teardown = FileUtils.rm_rf(@tmp)

  def ns(*)
    rc = nil
    out, err = capture_io { rc = TestHelpers.ns(*) }
    [rc, out, err]
  end

  # A state dir with a clone of a one-commit repo.
  def init_project
    source = File.join(@tmp, "src")
    ns("init", @state, "--source", source, "--new", "--name", "demo")
  end

  def test_version_and_help_list_every_command
    _, version, = ns("--version")
    _, help, = ns("help")

    assert_includes version, "nightshift #{Nightshift::VERSION}"
    %w[init plan check approve run stop status report doctor land].each do |cmd|
      assert_match(/^  ns #{cmd}\b/, help)
    end
  end

  def test_unknown_options_and_missing_arguments_fail
    rc_unknown, _, err_unknown = ns("check", @state, "--bogus")
    rc_missing, = ns("status")

    assert_equal 1, rc_unknown
    assert_includes err_unknown, "--bogus"
    assert_equal 1, rc_missing
  end

  def test_a_service_error_is_one_line_on_stderr
    rc, out, err = ns("status", @state)

    assert_equal 1, rc
    assert_empty out
    assert_equal ["ns: #{File.join(@state, 'nightshift.yml')} not found; run `ns init` first"], err.lines(chomp: true)
  end

  def test_times_and_numbers_are_checked_before_any_work
    rc_until, _, err_until = ns("run", @state, "--until", "25:00")
    rc_hours, _, err_hours = ns("run", @state, "--hours", "-1")

    assert_equal 1, rc_until
    assert_includes err_until, "--until must be a time like 23:30"
    assert_equal 1, rc_hours
    assert_includes err_hours, "--hours must be greater than 0"
  end

  def test_init_writes_a_clone_config_by_default
    init_project
    project = YAML.safe_load_file(File.join(@state, "nightshift.yml"))["project"]

    assert_equal ["repo", false], project.values_at("repo", "in_place")
  end

  def test_init_refuses_an_existing_state_dir
    first, = init_project
    again, _, err = init_project

    assert_equal 0, first
    assert_equal 1, again
    assert_includes err, "already initialised"
  end

  def test_land_prints_fetch_and_merge_commands
    init_project
    rc, text, = ns("land", @state)
    branch = "nightshift/#{Time.now.strftime('%Y%m%d')}"

    assert_equal 0, rc
    assert_includes text, "fetch \"#{Nightshift::Util.norm(File.join(@state, 'repo'))}\" #{branch}:#{branch}"
    assert_includes text, "merge --no-ff #{branch}"
  end

  def test_doctor_reports_a_server_start_cmd_that_is_not_on_path
    init_project
    config = File.join(@state, "nightshift.yml")
    text = File.read(config).sub(/^  # start_cmd: .*$/, "  start_cmd: [ns-no-such-starter, --port, \"8080\"]")
    File.write(config, text.sub(/^  health_url: .*$/, '  health_url: ""'), mode: "wb")
    rc, out, = ns("doctor", @state)

    assert_equal 1, rc
    assert_includes out, "server start_cmd ns-no-such-starter (not found on PATH)"
  end

  def test_stop_writes_the_stop_file
    init_project
    rc, = ns("stop", @state)

    assert_equal 0, rc
    assert_path_exists Nightshift::Project.new(@state).stop_file
  end
end
