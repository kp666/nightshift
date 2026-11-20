# frozen_string_literal: true

module Nightshift
  # `ns doctor`: preflight checks before leaving a night unattended.
  class Doctor
    GUARD = File.join(HOME, "adapters", "pi", "unattended-guard.ts")

    def initialize(project)
      @project = project
      @git = Git.new(project.repo)
    end

    # Returns true when every check passed.
    def run
      results = checks
      results.each { |ok, message| UI.step(ok, message) }
      bad = results.count { |ok, _| !ok }
      UI.step(bad.zero?, bad.zero? ? "doctor: all good" : "doctor: #{bad} problem(s)")
      bad.zero?
    end

    # [ok, message] pairs.
    def checks
      tasks = @project.load_tasks
      [[File.directory?(@project.repo), "repo #{@project.repo}"],
       [!%w[main master].include?(@git.branch), "branch #{@git.branch}"],
       *isolation_checks,
       [File.file?(@project.lock_file), "contract approved (contract.lock)"],
       [Plan.problems(tasks).empty?, "tasks.json valid (#{tasks.size} tasks)"],
       [Exec.available?(@project.shell.first), "gate shell #{@project.shell.first}"],
       *adapter_checks,
       [File.file?(GUARD), "pi guard extension #{GUARD}"],
       *server_check]
    end

    private

    # A clone must have no remotes. In place the repo keeps its remotes (that is the trade-off
    # you chose; see TRADEOFFS.md), but it must be on nightshift's branch and clean.
    def isolation_checks
      return [[@git.remotes.empty?, "no git remotes in the clone"]] unless @project.in_place?

      remotes = @git.remotes
      [[true, "in place: the worker edits #{@project.repo} " \
              "(remotes: #{remotes.empty? ? 'none' : remotes.join(', ')}; see TRADEOFFS.md)"],
       [@project.branch.empty? || @git.branch == @project.branch, "on the nightshift branch #{@project.branch}"],
       [!@git.dirty?, "no uncommitted or untracked files (a failed attempt runs git clean)"]]
    end

    def adapter_checks
      @project.cfg["roles"].reject { |_, name| name.to_s.empty? }.map do |role, name|
        spec = @project.adapter(name)
        exe = Adapters.render(Array(spec["cmd"]).first, Adapters.base_vars)
        Exec.resolve(exe)
        [true, "#{role}: #{name} (#{exe}, network: #{spec.fetch('network', '?')})"]
      rescue Error => e
        [false, "#{role}: #{name}: #{e.message}"]
      end
    end

    def server_check
      url = @project.cfg["server"]["health_url"]
      return [] if url.to_s.empty?

      up = Machine.healthy?(url)
      [[up, "model server #{url}#{' (down; start it, or set server.start_cmd so nightshift starts it)' unless up}"]]
    end
  end
end
