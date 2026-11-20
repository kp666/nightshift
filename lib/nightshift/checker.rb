# frozen_string_literal: true

module Nightshift
  # `ns check`: proves the plan can be worked on before a night is spent on it.
  #   - tasks.json is valid and every hidden (holdout) file it names exists;
  #   - every acceptance check FAILS now (a check that already passes tests nothing, and one whose
  #     command cannot run can never pass);
  #   - the global gates PASS now (otherwise every attempt fails for reasons outside the task).
  class Checker
    # The shell could not run the command at all: tool not installed, or a typo.
    NOT_RUNNABLE = [126, 127].freeze

    def initialize(project)
      @project = project
      @tasks = project.load_tasks
    end

    # Returns true when the plan is ready to approve.
    def run(commands: true, allow_red_global: false)
      UI.heading("Plan: #{@tasks.size} tasks")
      errors = Plan.problems(@tasks) + holdout_problems
      errors.each { |e| UI.step(false, e) }
      return false if errors.any?
      return UI.step(true, "static checks passed (commands not run)") || true unless commands
      return false unless bootstrap

      bad = checks_fail_now
      bad += 1 unless global_gates_pass || allow_red_global
      report(bad)
    end

    private

    def holdout_problems
      @tasks.flat_map do |t|
        files = Plan.holdout_files(t)
        missing = files.reject { |rel| File.file?(File.join(@project.holdout, rel)) }
                       .map { |rel| "#{t['id']}: holdout file missing: #{rel}" }
        no_checks = files.any? && Plan.holdout_checks(t).empty?
        missing + (no_checks ? ["#{t['id']}: has holdout files but no holdout.checks to run them"] : [])
      end
    end

    def bootstrap
      cmds = Array(@project.cfg["project"]["bootstrap"])
      return true if cmds.empty?

      r = Gates.run_commands("bootstrap", cmds, shell: @project.shell, repo: @project.repo,
                                                run_dir: Dir.mktmpdir("ns-boot-"), timeout_s: 3600)
      UI.step(r.ok?, "bootstrap: #{cmds.join('; ')}#{"\n#{r.detail}" unless r.ok?}")
      r.ok?
    end

    def gate_kw
      @gate_kw ||= begin
        run_dir = File.join(@project.runs, "check-#{Time.now.strftime('%Y%m%d-%H%M%S')}")
        FileUtils.mkdir_p(run_dir)
        { shell: @project.shell, repo: @project.repo, run_dir: run_dir,
          timeout_s: Float(@project.cfg["gates"]["verify_timeout_min"]) * 60 }
      end
    end

    # Returns the number of acceptance checks that already pass or cannot run.
    def checks_fail_now
      UI.heading("Every acceptance check must FAIL now (otherwise it tests nothing):")
      @tasks.sum do |task|
        placed = Gates.install_holdout(@project.holdout, @project.repo, Plan.holdout_files(task))
        begin
          (Plan.checks(task) + Plan.holdout_checks(task)).count { |cmd| !fails_now?(task, cmd) }
        ensure
          Gates.remove_files(placed)
        end
      end
    end

    def fails_now?(task, cmd)
      kw = gate_kw
      r = Exec.run_shell(cmd, kw[:shell], cwd: @project.repo, timeout_s: kw[:timeout_s],
                                          stdout: File.join(kw[:run_dir], "#{task['id']}.out"),
                                          stderr: File.join(kw[:run_dir], "#{task['id']}.err"))
      runnable = !NOT_RUNNABLE.include?(r.rc)
      note = if r.ok? then "  (already passes!)"
             elsif !runnable then "  (command not found: install the tool via project.bootstrap, or fix the command)"
             end
      good = !r.ok? && runnable
      UI.step(good, "#{task['id']}: `#{cmd}` -> exit #{r.rc}#{note}")
      good
    end

    def global_gates_pass
      cmds = @project.cfg["gates"]["global"]
      return true if cmds.empty?

      UI.heading("Global gates must PASS now (otherwise every attempt fails for reasons outside the task):")
      r = Gates.run_commands("global", cmds, **gate_kw)
      UI.step(r.ok?, "global gates#{"\n#{r.detail}" unless r.ok?}")
      r.ok?
    end

    def report(bad)
      if bad.zero?
        UI.step(true, "check passed")
        UI.next_step("ns approve \"#{@project.dir}\"")
      else
        UI.step(false, "#{bad} problem(s). Fix the plan or the tests, then run ns check again.")
      end
      bad.zero?
    end
  end
end
