# frozen_string_literal: true

module Nightshift
  # Running external programs with a hard time limit. On timeout the whole process tree is
  # killed (agents start shells, test runners and servers; killing only the parent leaks them).
  module Exec
    TIMEOUT_RC = 124 # same convention as coreutils `timeout`

    class NotFound < Error; end

    Result = Data.define(:rc, :seconds, :timed_out) do
      def ok? = rc.zero?
      def timed_out? = timed_out
    end

    module_function

    # Resolve a program name to a full path. On Windows this also finds npm-style shims
    # (pi.cmd, npx.cmd) through PATHEXT, which Process.spawn would not do on its own.
    def resolve(name)
      name = name.to_s
      return name if name.include?("/") || name.include?("\\")

      candidates =
        if WINDOWS
          exts = ENV.fetch("PATHEXT", ".COM;.EXE;.BAT;.CMD").downcase.split(";")
          exts.include?(File.extname(name).downcase) ? [name] : exts.map { |ext| name + ext }
        else
          [name]
        end
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        candidates.each do |candidate|
          path = File.join(dir, candidate)
          return path if File.file?(path)
        end
      end
      raise NotFound, "executable not found on PATH: #{name}"
    end

    def available?(name)
      resolve(name)
      true
    rescue NotFound
      false
    end

    # Run +argv+ to completion, or kill it and its children after +timeout_s+ seconds.
    # stdout/stderr go to files (an overnight transcript can be megabytes). +stdin+ is a file
    # path or nil. +on_timeout+ runs before the kill (e.g. `docker kill <container>`).
    def run(argv, cwd:, timeout_s:, stdout:, stderr:, stdin: nil, env: {}, on_timeout: nil)
      exe = resolve(argv.first)
      opts = { chdir: cwd.to_s, out: [stdout.to_s, "w"], err: [stderr.to_s, "w"],
               in: stdin ? stdin.to_s : File::NULL }
      opts[WINDOWS ? :new_pgroup : :pgroup] = true
      started = Util.monotonic
      # [exe, exe] forces "no shell" even when argv has a single element.
      pid = Process.spawn(env.transform_values(&:to_s), [exe, exe], *argv.drop(1).map(&:to_s), **opts)
      waiter = Process.detach(pid)
      if waiter.join(timeout_s)
        status = waiter.value
        return Result.new(rc: status.exitstatus || 1, seconds: Util.monotonic - started, timed_out: false)
      end

      begin
        on_timeout&.call
      rescue StandardError
        nil # a failing cleanup hook must not stop us from killing the process
      end
      kill_tree(pid)
      waiter.join(30)
      Result.new(rc: TIMEOUT_RC, seconds: Util.monotonic - started, timed_out: true)
    end

    # Run a gate command string through the configured shell, e.g. ["bash", "-c"].
    def run_shell(cmd, shell, **)
      run([*shell, cmd], **)
    end

    def kill_tree(pid)
      if WINDOWS
        system("taskkill", "/PID", pid.to_s, "/T", "/F", out: File::NULL, err: File::NULL)
      else
        Process.kill(:KILL, -pid)
      end
    rescue Errno::ESRCH
      nil # already gone
    end
  end
end
