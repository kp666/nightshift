# frozen_string_literal: true

require_relative "test_helper"

# Tmux mode (`ns run --tmux`): the pane runner, how adapters choose pane_cmd, and, when tmux is
# installed, a real pane: exit code, timeout kill, a pane closed by hand. Set NS_SKIP_TMUX=1 to
# skip the real-tmux tests.
class PaneTest < Minitest::Test
  RUBY = Nightshift::Util.norm(RbConfig.ruby)

  # Records what Adapters.run_agent hands to the pane; "runs" the agent by writing its answer.
  class FakePane
    attr_reader :calls

    def initialize(answer)
      @answer = answer
      @calls = []
    end

    def run(argv, **opts)
      @calls << [argv, opts]
      File.write(opts[:env].fetch("FINAL"), @answer)
      Nightshift::Exec::Result.new(rc: 0, seconds: 0.1, timed_out: false)
    end
  end

  def setup = @tmp = Dir.mktmpdir("ns-pane-")
  def teardown = FileUtils.rm_rf(@tmp)

  def runner(argv, env: {})
    spec = File.join(@tmp, "w.pane.json")
    File.write(spec, JSON.generate("argv" => argv, "cwd" => @tmp, "env" => env, "linger_s" => 0,
                                   "pid_file" => File.join(@tmp, "w.pid"), "rc_file" => File.join(@tmp, "w.rc")))
    _, err, status = Open3.capture3(RUBY, Nightshift::Pane::RUNNER, spec)
    [status, err]
  end

  def test_runner_reports_pid_and_exit_code
    status, = runner([RUBY, "-e", 'File.write("env.txt", ENV["NS_X"]); exit 3'], env: { "NS_X" => "a b" })

    assert_predicate status, :success?
    assert_equal "3\n", File.read(File.join(@tmp, "w.rc"))
    assert_match(/\A\d+\n\z/, File.read(File.join(@tmp, "w.pid")))
    assert_equal "a b", File.read(File.join(@tmp, "env.txt"))
  end

  def test_runner_reports_127_when_the_agent_cannot_start
    _, err = runner([File.join(@tmp, "no-such-agent.exe")])

    assert_equal "127\n", File.read(File.join(@tmp, "w.rc"))
    assert_includes err, "could not start"
  end

  def test_run_agent_uses_pane_cmd_and_pane_env_in_a_pane
    spec = { "cmd" => ["never-run"], "pane_cmd" => [RUBY, "{prompt_file}"], "env" => { "A" => "{repo}" },
             "pane_env" => { "FINAL" => "{out}" }, "prompt_via" => "file" }
    prompt = File.join(@tmp, "prompt.md")
    File.write(prompt, "do it")
    pane = FakePane.new("thinking...\nDONE: built it\n")
    run = Nightshift::Adapters.run_agent(spec, prompt_file: prompt, cwd: @tmp, run_dir: @tmp, timeout_s: 60,
                                               pane: pane, title: "T01")
    argv, opts = pane.calls.fetch(0)

    assert_equal [RUBY, prompt], argv
    assert_equal({ "A" => @tmp, "FINAL" => File.join(@tmp, "worker.out") }, opts[:env])
    assert_equal ["T01", 60], [opts[:title], opts[:timeout_s]]
    assert_equal "DONE: built it", run.said
  end

  def test_run_agent_without_pane_cmd_runs_headless_even_with_a_pane
    spec = { "cmd" => [RUBY, "-e", 'puts "DONE: headless"'], "prompt_via" => "file" }
    prompt = File.join(@tmp, "prompt.md")
    File.write(prompt, "x")
    pane = FakePane.new("")
    run = Nightshift::Adapters.run_agent(spec, prompt_file: prompt, cwd: @tmp, run_dir: @tmp, timeout_s: 60, pane: pane)

    assert_empty pane.calls
    assert_equal "DONE: headless", run.said
  end

  def test_catalog_pi_adapters_have_a_pane_mode_that_quits_by_itself
    catalog = YAML.load_file(Nightshift::CATALOG, aliases: true)["adapters"]
    %w[pi-local pi-openrouter].each do |name|
      spec = catalog.fetch(name)

      refute_includes spec["pane_cmd"], "-p", name
      assert_equal({ "PI_GUARD_FINAL" => "{out}", "PI_GUARD_EXIT_ON_SETTLE" => "1" }, spec["pane_env"], name)
    end
  end

  def test_session_names_are_safe_for_tmux
    assert_equal "ns-port-js", Nightshift::Pane.session_name("port-js")
    assert_equal "ns-my-app-v2", Nightshift::Pane.session_name("My App.v2")
  end

  def test_launch_explains_how_to_get_tmux_when_it_is_missing
    saved = ENV.fetch("PATH", nil)
    ENV["PATH"] = @tmp # nothing to find there
    error = assert_raises(Nightshift::Error) { Nightshift::Pane.launch("ns-x", [], cwd: @tmp) }

    assert_includes error.message, "needs tmux"
  ensure
    ENV["PATH"] = saved
  end

  # ------------------------------------------------------------------ real tmux

  def with_tmux_session(&)
    skip "tmux not installed" unless Nightshift::Exec.available?("tmux")
    skip "NS_SKIP_TMUX is set" if ENV["NS_SKIP_TMUX"]
    in_new_tmux_session(&)
  end

  def in_new_tmux_session
    name = "ns-test-#{Process.pid}-#{rand(10_000)}"
    tmux = Nightshift::Pane.tmux

    assert system(tmux, "new-session", "-d", "-s", name, "-x", "120", "-y", "40")
    target = IO.popen([tmux, "display-message", "-p", "-t", name, Nightshift::Pane::PANE_ID], &:read).strip
    yield Nightshift::Pane.new(target: target, linger_s: 30)
  ensure
    system(tmux, "kill-session", "-t", name, out: File::NULL, err: File::NULL) if name
  end

  def test_real_pane_returns_the_exit_code_and_lingers_until_the_next_run
    with_tmux_session do |pane|
      result = pane.run([RUBY, "-e", "exit 3"], cwd: @tmp, timeout_s: 60, run_dir: @tmp, label: "a", title: "first")

      assert_equal [3, false], [result.rc, result.timed_out?]
      first = pane.pane_id

      assert pane.send(:open?), "the finished pane stays open, readable"
      pane.run([RUBY, "-e", "exit 0"], cwd: @tmp, timeout_s: 60, run_dir: @tmp, label: "b")

      refute_equal first, pane.pane_id
      pane.instance_variable_set(:@pane_id, first)

      refute pane.send(:open?), "the previous pane is closed when the next run starts"
    end
  end

  def test_hosting_a_night_closes_the_last_agent_pane_at_the_end
    with_tmux_session do |pane|
      $stdin = StringIO.new # not a terminal: no "Press Enter" wait
      code = Nightshift::Pane.host_night(pane) do
        pane.run([RUBY, "-e", "exit 0"], cwd: @tmp, timeout_s: 60, run_dir: @tmp, label: "h")
        7
      end

      assert_equal 7, code
      assert_nil pane.pane_id, "the lingering pane would keep the tmux session alive"
    end
  ensure
    $stdin = STDIN
  end

  def test_real_pane_kills_the_agent_tree_on_timeout
    with_tmux_session do |pane|
      hook = []
      child = [RUBY, "-e", 'pid = spawn(RbConfig.ruby, "-e", "sleep 300"); File.write("child.pid", pid); sleep 300']
      result = pane.run(child, cwd: @tmp, timeout_s: 4, run_dir: @tmp, label: "t", on_timeout: -> { hook << 1 })
      grandchild = Integer(File.read(File.join(@tmp, "child.pid")))
      sleep 1

      assert_equal [Nightshift::Exec::TIMEOUT_RC, true, [1]], [result.rc, result.timed_out?, hook]
      assert_nil pane.pane_id
      refute alive?(grandchild), "the agent's children are killed too"
    end
  end

  def test_real_pane_closed_by_hand_ends_the_attempt
    with_tmux_session do |pane|
      Thread.new do
        sleep 3
        system(Nightshift::Pane.tmux, "kill-pane", "-t", pane.pane_id)
      end
      result = pane.run([RUBY, "-e", "sleep 300"], cwd: @tmp, timeout_s: 60, run_dir: @tmp, label: "k")

      assert_equal [1, false], [result.rc, result.timed_out?]
      assert_operator result.seconds, :<, 30
    end
  end

  def alive?(pid)
    if Nightshift::WINDOWS
      IO.popen(["tasklist", "/FI", "PID eq #{pid}", "/NH"], &:read).include?(" #{pid} ")
    else
      Process.kill(0, pid) && true
    end
  rescue Errno::ESRCH
    false
  end
end
