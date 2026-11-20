# frozen_string_literal: true

module Nightshift
  # Runs the gates (see Gates for the order) on one staged attempt and returns a Verdict.
  # Hidden holdout tests are copied into the repo only for the duration of the checks.
  class Verifier
    # result: Gates::Result; advisories: [String] from the hard-code scan (they never fail an attempt)
    Verdict = Data.define(:result, :advisories) do
      def initialize(result:, advisories: [])
        super
      end
    end

    def initialize(night)
      @night = night
      @project = night.project
      @gates = night.cfg["gates"]
    end

    def verify(task, status, patch, run_dir)
      result = Gates.integrity(status, patch, @gates, all_holdout_paths)
      return Verdict.new(result: result) unless result.ok?

      if @gates.fetch("stray_paths", true)
        result = stray_paths(task, status)
        return Verdict.new(result: result) unless result.ok?
      end

      opts = { shell: @night.shell, repo: @project.repo, run_dir: run_dir,
               timeout_s: Float(@gates["verify_timeout_min"]) * 60 }
      unless Array(@gates["setup"]).empty?
        result = Gates.run_commands("setup", @gates["setup"], **opts)
        return Verdict.new(result: result) unless result.ok?
      end

      passed = @night.tasks.select { |t| t["id"] != task["id"] && @night.satisfied?(t["id"]) }
      hold_files = (Plan.holdout_files(task) + passed.flat_map { |t| Plan.holdout_files(t) }).uniq.sort
      result = check_with_holdouts(task, passed, hold_files, opts)
      return Verdict.new(result: result) unless result.ok?

      Verdict.new(result: Gates::PASS, advisories: hardcode_advisories(patch, hold_files))
    end

    private

    def all_holdout_paths = @night.tasks.flat_map { |t| Plan.holdout_files(t) }

    def stray_paths(task, status)
      tracked = @night.tracked
      source_name = File.basename(@night.cfg["project"]["source"].to_s)
      real_dirs = tracked.flat_map { |t| Util.norm(t).split("/")[0...-1] }.to_set
      names = source_name.empty? || real_dirs.include?(source_name) ? [] : [source_name]
      allowed = Array(task["files"]) + Array(@gates["allow_new_dirs"])
      Gates.stray_paths(status, tracked, allowed, names)
    end

    # task -> holdout -> regression -> global, with holdouts installed.
    def check_with_holdouts(task, passed, hold_files, opts)
      placed = []
      placed = Gates.install_holdout(@project.holdout, @project.repo, hold_files)
      command_gates(task, passed).each do |gate, cmds|
        next if cmds.empty?

        result = Gates.run_commands(gate, cmds, **opts)
        return result unless result.ok?
      end
      Gates::PASS
    ensure
      Gates.remove_files(placed)
    end

    def command_gates(task, passed)
      regression = if @gates.fetch("regression", true)
                     passed.flat_map { |t| Plan.checks(t) + Plan.holdout_checks(t) }.uniq
                   else
                     []
                   end
      [["task", Plan.checks(task)], ["holdout", Plan.holdout_checks(task)],
       ["regression", regression], ["global", Array(@gates["global"])]]
    end

    def hardcode_advisories(patch, hold_files)
      return [] unless @gates.fetch("hardcode_scan", true)

      visible = @night.git.lines("ls-files").select { |f| Gates.test_path?(f, @gates["test_paths"]) }.first(200)
      refs = hold_files.map { |rel| Util.read(File.join(@project.holdout, rel)) } +
             visible.map { |rel| Util.read(File.join(@project.repo, rel)) }
      Gates.hardcode_scan(patch, refs, @gates["test_paths"])
    end
  end
end
