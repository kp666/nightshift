# frozen_string_literal: true

module Nightshift
  # Agent adapters: the only place that knows how a particular coding agent is launched.
  #
  # An adapter is pure data (adapters/adapters.yml). The harness gives it a prompt file, a
  # working directory and a time limit, and gets back an exit code and a transcript. The
  # adapter never decides whether work is done; gates do. Supporting a new agent, provider or
  # LoRA means adding a YAML entry, not code.
  #
  # Adapter fields
  #   cmd              argv for headless runs (placeholders are filled in)
  #   pane_cmd         argv for watched runs (`ns run --tmux`): the agent's own interactive screen
  #                    in a tmux pane. It must exit by itself when done and write its final answer
  #                    to {out}. Without it, the adapter runs headless even in tmux mode.
  #   pane_env         extra environment for pane_cmd, on top of env
  #   interactive_cmd  argv for attended use (planning with you at the keyboard)
  #   prompt_via       "stdin" (default) | "arg" ({prompt} holds the text) | "file" ({prompt_file})
  #   env              extra environment variables (placeholders allowed)
  #   timeout_min      per-attempt hard limit (default: budgets.attempt_timeout_min)
  #   kill_cmd         extra command run on timeout before the process tree is killed (docker kill)
  #   requires_server  true if the model server health check must pass before each attempt
  #   network          "none" | "local" | "internet" (documentation; shown by doctor)
  #
  # Placeholders: {repo} {run_dir} {prompt_file} {prompt} {message} {container} {state} {home}
  #               {ruby} {protect_csv} {guard_minutes} {max_turns} {out} (the transcript file)
  module Adapters
    DEFAULT_MESSAGE = "Carry out the task described in the prompt, then stop."
    PLACEHOLDER = /\{([a-z_]+)\}/

    Run = Data.define(:rc, :seconds, :timed_out, :stdout, :stderr, :said) do
      def timed_out? = timed_out
    end

    module_function

    # Fill {placeholders} in a string, or in every string inside an Array/Hash.
    # Unknown placeholders are left as they are.
    def render(value, vars)
      case value
      when String then value.gsub(PLACEHOLDER) do
        vars.key?(Regexp.last_match(1)) ? vars[Regexp.last_match(1)].to_s : Regexp.last_match(0)
      end
      when Array then value.map { |item| render(item, vars) }
      when Hash then value.transform_values { |item| render(item, vars) }
      else value
      end
    end

    def base_vars = { "home" => HOME, "ruby" => Util.norm(RbConfig.ruby) }

    # Run an agent on one prompt. Headless, output goes to <run_dir>/<label>.out/.err. With a
    # +pane+ (a Pane, in `ns run --tmux`) and a pane_cmd, the agent runs on screen in a tmux
    # pane instead, and writes its final answer to <label>.out itself.
    def run_agent(spec, prompt_file:, cwd:, run_dir:, timeout_s:, extra_vars: {}, label: "worker", pane: nil,
                  title: nil)
      out = File.join(run_dir, "#{label}.out")
      err = File.join(run_dir, "#{label}.err")
      vars = agent_vars(spec, prompt_file, cwd, run_dir, label).merge("out" => out).merge(extra_vars)
      env = render(spec.fetch("env", {}), vars).transform_values(&:to_s)
      opts = { cwd: cwd, timeout_s: timeout_s, on_timeout: timeout_hook(spec, vars, cwd) }
      result =
        if pane && spec["pane_cmd"]
          [out, err].each { |path| Util.write(path, "") }
          pane.run(render(Array(spec["pane_cmd"]), vars), run_dir: run_dir, label: label, title: title,
                                                          env: env.merge(render(spec.fetch("pane_env", {}), vars)),
                                                          **opts)
        else
          stdin = spec.fetch("prompt_via", "stdin") == "stdin" ? prompt_file : nil
          Exec.run(render(Array(spec.fetch("cmd")), vars), stdout: out, stderr: err, stdin: stdin, env: env, **opts)
        end
      Run.new(rc: result.rc, seconds: result.seconds, timed_out: result.timed_out,
              stdout: out, stderr: err, said: last_claim(out))
    end

    def agent_vars(spec, prompt_file, cwd, run_dir, label)
      base_vars.merge(
        "repo" => cwd.to_s, "run_dir" => run_dir.to_s, "prompt_file" => prompt_file.to_s,
        "prompt" => Util.read(prompt_file), "message" => spec.fetch("message", DEFAULT_MESSAGE),
        "container" => "ns-#{File.basename(run_dir)}-#{label}".downcase.tr("_", "-")[0, 60]
      )
    end

    # Run on timeout before the process tree is killed: the adapter's kill_cmd, if any.
    def timeout_hook(spec, vars, cwd)
      kill_cmd = render(Array(spec["kill_cmd"]), vars)
      lambda do
        next if kill_cmd.empty?

        Exec.run(kill_cmd, cwd: cwd, timeout_s: 60, stdout: File::NULL, stderr: File::NULL)
      end
    end

    # The agent's last DONE/STUCK line. Logged for humans; never trusted.
    def last_claim(path)
      Util.read(path).lines.grep(/^\s*(DONE|STUCK)\b/).last.to_s.strip[0, 300]
    end

    # Attended run with the terminal attached (planning while you are awake).
    def run_interactive(spec, prompt_file:, cwd:)
      vars = base_vars.merge("repo" => cwd.to_s, "prompt_file" => prompt_file.to_s,
                             "prompt" => Util.read(prompt_file),
                             "message" => "Read #{prompt_file} and follow it.")
      argv = render(Array(spec["interactive_cmd"] || spec.fetch("cmd")), vars)
      exe = Exec.resolve(argv.first)
      system([exe, exe], *argv.drop(1), chdir: cwd.to_s)
      $?&.exitstatus || 1 # rubocop:disable Style/SpecialGlobalVars
    end
  end
end
