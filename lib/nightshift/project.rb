# frozen_string_literal: true

module Nightshift
  # A project state directory and its configuration.
  #
  # The state directory lives OUTSIDE the repo, so workers can neither read nor edit it:
  #
  #   <state>/nightshift.yml     project config (human)
  #   <state>/requirements.md    what you want (human)
  #   <state>/tasks.json         task graph (planner writes, human approves)
  #   <state>/holdout/           hidden tests at their repo paths; copied in only during verification
  #   <state>/contract.lock      hashes of protected files at approval time
  #   <state>/state.json         per-task progress (harness only)
  #   <state>/journal.jsonl      every event (harness only)
  #   <state>/runs/<tag>/        prompt, transcript, diff, gate output per attempt
  #   <state>/REPORT.md          morning report
  #   <state>/STOP               create this file to stop after the current attempt
  #   <state>/repo/              dedicated clone the worker edits (no remotes)
  class Project
    CONFIG_FILE = "nightshift.yml"

    # Every setting nightshift knows, with its default. nightshift.yml overrides any of them.
    DEFAULTS = {
      "project" => {
        "name" => "", "source" => "", "repo" => "repo", "branch" => "", "bootstrap" => [],
        "acceptance_dir" => "tests/acceptance/", "holdout_dir" => "tests/holdout/"
      },
      "roles" => { "worker" => "pi-local", "escalate" => "", "planner" => "claude-code" },
      "budgets" => {
        "hours" => 0, "until" => "", # no time limit unless one is set
        "max_iterations" => 60, "attempt_timeout_min" => 75, "max_attempts" => 3,
        "max_consecutive_failures" => 5, "max_escalations" => 4
      },
      "gates" => {
        "shell" => [], "setup" => [], "global" => [], "regression" => true, "verify_timeout_min" => 15,
        "protect" => ["tests/acceptance/", "AGENTS.md", ".nightshift/"],
        "test_paths" => ["tests/"], "check_skip_markers" => true, "check_test_deletion" => true,
        "hardcode_scan" => true,
        "stray_paths" => true,  # reject files created under a new top-level folder (garbled paths)
        "allow_new_dirs" => []  # top-level folders the worker may create, e.g. ["bench/"]
      },
      "server" => { "health_url" => "", "start_cmd" => [], "down_grace_min" => 10, "check_every_s" => 15 },
      "notify" => { "cmd" => [] },
      "adapters" => {}
    }.freeze

    attr_reader :dir, :cfg, :name, :repo, :runs, :holdout

    def initialize(state_dir)
      @dir = File.expand_path(state_dir.to_s)
      cfg_file = File.join(@dir, CONFIG_FILE)
      raise Error, "#{cfg_file} not found; run `ns init` first" unless File.file?(cfg_file)

      catalog = self.class.load_yaml(CATALOG)
      @cfg = Util.deep_merge(Util.deep_copy(DEFAULTS), { "adapters" => catalog.fetch("adapters", {}) })
      @cfg = Util.deep_merge(@cfg, self.class.load_yaml(cfg_file))
      normalize!
      @name = cfg["project"]["name"].to_s.empty? ? File.basename(@dir) : cfg["project"]["name"]
      @repo = File.expand_path(cfg["project"]["repo"], @dir)
      @runs = File.join(@dir, "runs")
      @holdout = File.join(@dir, "holdout")
    end

    def self.load_yaml(path)
      return {} unless File.file?(path)

      data = YAML.safe_load(Util.read(path), aliases: true) || {}
      raise Error, "#{path}: expected a mapping at the top level" unless data.is_a?(Hash)

      data
    rescue Psych::SyntaxError => e
      raise Error, "#{path}: #{e.message}"
    end

    # Git Bash on Windows (so gate commands look the same on every OS), else bash.
    def self.default_shell
      return %w[bash -c] unless WINDOWS

      git_bash = File.join(ENV.fetch("ProgramFiles", "C:/Program Files"), "Git", "bin", "bash.exe")
      File.file?(git_bash) ? [Util.norm(git_bash), "-c"] : %w[pwsh -NoProfile -Command]
    end

    # "HH:MM" from YAML. Unquoted 07:00 is read by YAML as seconds after midnight (25200).
    def self.clock(value)
      return value.to_s unless value.is_a?(Integer)

      format("%<h>02d:%<m>02d", h: value / 3600, m: (value % 3600) / 60)
    end

    def config_file = File.join(dir, CONFIG_FILE)
    def tasks_file = File.join(dir, "tasks.json")
    def state_file = File.join(dir, "state.json")
    def journal_file = File.join(dir, "journal.jsonl")
    def lock_file = File.join(dir, "contract.lock")
    def stop_file = File.join(dir, "STOP")
    def progress_file = File.join(dir, "progress.txt")
    def report_file = File.join(dir, "REPORT.md")
    def failure_file(task_id) = File.join(dir, "last-failure-#{task_id}.txt")

    def adapter(name)
      spec = cfg["adapters"][name]
      raise Error, "adapter '#{name}' is not defined (catalog: #{CATALOG})" if spec.nil? || spec.empty?

      spec
    end

    # The gate shell with {repo}/{state} filled in.
    def shell = Adapters.render(cfg["gates"]["shell"], "repo" => repo, "state" => dir)

    def load_tasks = Util.read_json(tasks_file, { "tasks" => [] }).fetch("tasks", [])
    def save_tasks(tasks) = Util.write_json(tasks_file, { "tasks" => tasks })
    def load_state = Util.read_json(state_file, { "tasks" => {}, "head" => "", "night" => {} })
    def save_state(state) = Util.write_json(state_file, state)
    def lock = Util.read_json(lock_file, nil)

    private

    def normalize!
      cfg["gates"]["shell"] = self.class.default_shell if Array(cfg["gates"]["shell"]).empty?
      cfg["budgets"]["until"] = self.class.clock(cfg["budgets"]["until"])
    end
  end
end
