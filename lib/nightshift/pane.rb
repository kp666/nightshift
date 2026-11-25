# frozen_string_literal: true

module Nightshift
  # Watching a night live: `ns run --tmux` runs the loop inside a tmux session, and every
  # attempt opens a pane below the loop's log with the agent's own interactive screen in it.
  #
  # The harness still owns the agent. The pane runs lib/nightshift/pane_runner.rb, which starts
  # the agent and writes its pid and exit code to files in the run dir; Pane#run waits for the
  # exit code, and on timeout kills the agent's process tree (by that pid) and the pane. The
  # previous attempt's pane stays open, showing its last screen, until the next attempt starts.
  #
  # Tested with psmux 3.4 (a native Windows tmux) and written to the plain tmux command set.
  class Pane
    RUNNER = File.join(__dir__, "pane_runner.rb")
    POLL_S = 1
    LINGER_S = 12 * 3600 # the last pane of a night stays readable until the morning
    LAYOUT = %w[-v -l 75%].freeze # agent pane below the loop's log, taking most of the height
    PANE_ID = '#{pane_id}' # rubocop:disable Lint/InterpolationCheck -- a tmux format

    class << self
      # True inside a tmux pane (tmux sets both variables in every pane it starts).
      def inside? = !ENV["TMUX"].to_s.empty? && !ENV["TMUX_PANE"].to_s.empty?

      def tmux = Exec.resolve("tmux")

      # Start `ns run` (+ns_args+) in a new detached session and attach to it when there is a
      # terminal. Returns the session name.
      def launch(name, ns_args, cwd:)
        unless Exec.available?("tmux")
          raise Error,
                "tmux mode needs tmux on PATH (on Windows: winget install marlocarlo.psmux)"
        end
        if system(tmux, "has-session", "-t", name, out: File::NULL, err: File::NULL)
          raise Error, "tmux session #{name} already exists (a night may be running): tmux attach -t #{name}"
        end

        cmd = [Util.norm(RbConfig.ruby), File.join(HOME, "bin", "ns"), *ns_args]
        ok = system(tmux, "new-session", "-d", "-s", name, "-x", "200", "-y", "50", "-c", cwd.to_s, "--", *cmd)
        raise Error, "could not start tmux session #{name}" unless ok

        # pi warns about modified Enter keys without it; harmless when unsupported.
        system(tmux, "set-option", "-t", name, "extended-keys", "on", out: File::NULL, err: File::NULL)
        name
      end

      # `ns run --tmux` from a plain terminal: start the night in a new session, attach to it
      # when there is a terminal, and say how to come back. Detaching leaves the night running.
      def open_night(name, ns_args, cwd:)
        launch(name, ns_args, cwd: cwd)
        UI.step(true, "the night runs in tmux session #{name}")
        system(tmux, "attach", "-t", name) if $stdin.tty? && $stdout.tty?
        UI.next_step("watch it with: tmux attach -t #{name}   (detach: Ctrl+b d; the night keeps running)")
      end

      # Inside that session: run the loop (the block gets a Pane for the attempts) and keep the
      # session open afterwards, so the summary or an error can still be read in the morning.
      # Then the last agent pane is closed too: it would keep the session alive.
      def host_night(pane = new)
        code = 1
        code = yield pane
      rescue StandardError => e
        UI.warning("#{e.class}: #{e.message}")
        raise
      ensure
        hold_open(code)
        pane.close
      end

      def hold_open(code)
        return unless $stdin.tty?

        UI.info("\nThe run has ended (exit code #{code}). Press Enter to close this tmux session.")
        $stdin.gets
      rescue Interrupt
        nil
      end

      # A tmux session name from a project name: tmux treats "." and ":" as separators.
      def session_name(project_name) = "ns-#{project_name.to_s.downcase.gsub(/[^a-z0-9_-]+/, '-')}"[0, 50]
    end

    attr_reader :pane_id

    # +target+: the pane the loop runs in (new panes are split from it).
    def initialize(target: ENV.fetch("TMUX_PANE", nil), linger_s: LINGER_S)
      @target = target
      @linger_s = linger_s
      @pane_id = nil
    end

    # Run +argv+ in a new pane and wait for it, like Exec.run (same Result). The agent's output
    # goes to its screen, not to files: the caller arranges a transcript (pi saves a session).
    def run(argv, cwd:, timeout_s:, run_dir:, label:, env: {}, title: nil, on_timeout: nil)
      close
      files = { spec: "pane.json", pid: "pid", rc: "rc" }.transform_values do |ext|
        File.join(run_dir, "#{label}.#{ext}")
      end
      write_spec(files, argv, cwd, env)
      started = Util.monotonic
      @pane_id = open_pane(files[:spec])
      name(title) if title
      wait(files, started, timeout_s, on_timeout)
    end

    # Close the last pane (the agent in it is already gone, or is killed with it).
    def close
      return unless @pane_id

      tmux_quiet("kill-pane", "-t", @pane_id)
      @pane_id = nil
    end

    private

    # The runner's instructions (see pane_runner.rb); stale pid/rc files from a rerun go first.
    def write_spec(files, argv, cwd, env)
      FileUtils.rm_f([files[:pid], files[:rc]])
      spec = { "argv" => [Exec.resolve(argv.first), *argv.drop(1).map(&:to_s)], "cwd" => cwd.to_s,
               "env" => env.transform_values(&:to_s), "pid_file" => files[:pid], "rc_file" => files[:rc],
               "linger_s" => @linger_s }
      Util.write(files[:spec], JSON.pretty_generate(spec))
    end

    def open_pane(spec)
      target = @target ? ["-t", @target] : []
      args = ["split-window", "-d", *target, *LAYOUT, "-P", "-F", PANE_ID,
              "--", Util.norm(RbConfig.ruby), RUNNER, spec]
      out, err, status = Open3.capture3(self.class.tmux, *args)
      raise Error, "tmux split-window failed: #{err.strip}" unless status.success? && out.strip.start_with?("%")

      out.strip
    end

    def name(title) = tmux_quiet("select-pane", "-t", @pane_id, "-T", title)

    def wait(files, started, timeout_s, on_timeout)
      loop do
        return finished(files[:rc], started) if File.exist?(files[:rc])

        unless open? # closed by hand: make sure nothing it started lives on
          kill(files[:pid], nil)
          return Exec::Result.new(rc: 1, seconds: Util.monotonic - started, timed_out: false)
        end
        break if Util.monotonic - started > timeout_s

        sleep POLL_S
      end
      kill(files[:pid], on_timeout)
      Exec::Result.new(rc: Exec::TIMEOUT_RC, seconds: Util.monotonic - started, timed_out: true)
    rescue Interrupt
      kill(files[:pid], nil)
      raise
    end

    def finished(rc_file, started)
      rc = Integer(Util.read(rc_file).strip, exception: false) || 1
      Exec::Result.new(rc: rc, seconds: Util.monotonic - started, timed_out: false)
    end

    # The pane still exists (someone may have closed it by hand).
    def open?
      tmux_quiet("display-message", "-p", "-t", @pane_id, PANE_ID).strip == @pane_id
    end

    def kill(pid_file, on_timeout)
      begin
        on_timeout&.call
      rescue StandardError
        nil # a failing cleanup hook must not stop the kill
      end
      pid = Integer(Util.read(pid_file).strip, exception: false)
      Exec.kill_tree(pid) if pid
      close
    end

    def tmux_quiet(*)
      out, _status = Open3.capture2(self.class.tmux, *, err: File::NULL)
      out
    rescue SystemCallError
      ""
    end
  end
end
