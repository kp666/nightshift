# frozen_string_literal: true

module Nightshift
  # `ns plan`: the attended planning step. Builds the planner prompt from requirements.md and the
  # repo, runs a planner agent (with the human by default), then harvests what it wrote:
  # .nightshift-plan/tasks.json becomes the state dir's tasks.json, and .nightshift-plan/holdout/
  # moves out of the repo into holdout/, where the worker can never see it.
  class Planner
    PLAN_DIR = ".nightshift-plan"
    # A repo holding only these files is a new project: the planner must build its skeleton first.
    SCAFFOLD = /\A(README|LICENSE)(\.\w+)?\z|\A\.git(ignore|attributes)\z/i
    TREE_LIMIT = 400

    def initialize(project)
      @project = project
    end

    def prompt_file = File.join(@project.dir, "planner-prompt.md")

    # Writes the prompt to planner-prompt.md and returns its text.
    def write_prompt
      text = prompt
      Util.write(prompt_file, text)
      text
    end

    # Runs the planner agent, interactively unless headless, then harvests its plan.
    def run(adapter: nil, headless: false)
      name = adapter || @project.cfg["roles"]["planner"]
      spec = @project.adapter(name)
      write_prompt
      headless ? run_headless(spec) : run_with_human(spec, name)
      harvest
    end

    # Moves the planner's output out of the repo and returns the harvested tasks.
    def harvest
      plan_dir = File.join(@project.repo, PLAN_DIR)
      tasks_json = File.join(plan_dir, "tasks.json")
      raise Error, "No #{PLAN_DIR}/tasks.json in #{@project.repo}; nothing to harvest." unless File.file?(tasks_json)

      backup_tasks
      data = JSON.parse(Util.read(tasks_json))
      @project.save_tasks(data.is_a?(Array) ? data : data.fetch("tasks", []))
      hidden = move_holdout(File.join(plan_dir, "holdout"))
      FileUtils.rm_rf(plan_dir)
      report(hidden)
    end

    private

    def prompt
      files = Git.new(@project.repo).lines("ls-files")
      tree = files.first(TREE_LIMIT).join("\n")
      tree += "\n... (#{files.size - TREE_LIMIT} more)" if files.size > TREE_LIMIT
      Prompts.build(@project, "planner.md", "TREE" => tree, "NEW_PROJECT" => new_project_note(files), **prompt_vars)
    end

    def new_project_note(files)
      return "" unless files.all? { |file| file.match?(SCAFFOLD) }

      Prompts.build(@project, "planner-new.md", "CONFIG" => @project.config_file)
    end

    def prompt_vars
      cfg = @project.cfg
      gates = cfg["gates"]
      { "PROJECT" => @project.name, "REQUIREMENTS" => Util.read(File.join(@project.dir, "requirements.md")),
        "PLAN_DIR" => PLAN_DIR, "PROTECT" => gates["protect"].join(", "),
        "GLOBAL" => gates["global"].empty? ? "(none configured)" : gates["global"].join("\n"),
        "SHELL" => @project.shell.join(" "), "WORKER" => cfg["roles"]["worker"],
        "ACCEPT_DIR" => cfg["project"]["acceptance_dir"], "HOLDOUT_DIR" => cfg["project"]["holdout_dir"] }
    end

    def run_headless(spec)
      run_dir = File.join(@project.runs, "plan-#{Time.now.strftime('%Y%m%d-%H%M%S')}")
      FileUtils.mkdir_p(run_dir)
      r = Adapters.run_agent(spec, prompt_file: prompt_file, cwd: @project.repo, run_dir: run_dir,
                                   timeout_s: Float(spec.fetch("timeout_min", 60)) * 60, label: "planner")
      UI.step(r.ok?, "planner exited rc=#{r.rc} after #{(r.seconds / 60).round(1)} min; transcript #{r.stdout}")
    end

    def run_with_human(spec, name)
      UI.info("Opening #{name} in #{@project.repo}. Discuss the plan with it; quit when it has written #{PLAN_DIR}/.")
      Adapters.run_interactive(spec, prompt_file: prompt_file, cwd: @project.repo)
    end

    def backup_tasks
      return unless File.file?(@project.tasks_file)

      stamp = Time.now.strftime("%Y%m%d-%H%M%S")
      FileUtils.cp(@project.tasks_file, File.join(@project.dir, "tasks.#{stamp}.bak.json"))
    end

    # Returns whether there were hidden tests to move.
    def move_holdout(holdout)
      FileUtils.mkdir_p(@project.holdout)
      return false unless File.directory?(holdout)

      FileUtils.cp_r(File.join(holdout, "."), @project.holdout)
      true
    end

    def report(hidden)
      tasks = @project.load_tasks
      UI.step(true, "harvested #{tasks.size} tasks into #{@project.tasks_file}" \
                    "#{" and hidden tests into #{@project.holdout}" if hidden}")
      tasks.each do |task|
        UI.info("    #{task['id'].to_s.ljust(8)} #{task['title']}")
      end
      UI.next_step("review tasks.json, the new tests in the repo and holdout/, then: ns check")
      tasks
    end
  end
end
