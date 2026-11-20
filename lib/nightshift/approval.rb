# frozen_string_literal: true

module Nightshift
  # `ns approve`: freezes the contract. Commits the tasks and acceptance tests in the clone,
  # records the hashes of every protected file in contract.lock (the gates reject any attempt
  # that changes one), and by default gives blocked tasks a fresh start.
  module Approval
    module_function

    # Returns the lock that was written.
    def approve(project, keep_blocked: false)
      git = Git.new(project.repo)
      check_ready(project, git)
      commit_contract(git)
      lock = write_lock(project, git)
      update_state(project, lock["commit"], keep_blocked: keep_blocked)
      UI.step(true, "approved at #{lock['commit'][0, 10]}; #{lock['files'].size} protected files locked")
      UI.next_step("ns doctor \"#{project.dir}\", then ns run")
      lock
    end

    def check_ready(project, git)
      problems = Plan.problems(project.load_tasks)
      raise Error, "Fix tasks.json first:\n  #{problems.join("\n  ")}" if problems.any?

      branch = git.branch
      raise Error, "The clone is on #{branch}; nightshift needs its own branch." if %w[main master].include?(branch)
      return unless File.exist?(File.join(project.repo, Planner::PLAN_DIR))

      raise Error, "#{Planner::PLAN_DIR}/ is still in the repo; run `ns plan --harvest` first."
    end

    def commit_contract(git)
      git.run("add", "-A")
      return if git.run("diff", "--cached", "--name-only").empty?

      git.run("commit", "-q", "--no-verify", "-m", "nightshift: approve contract (tasks, acceptance tests)")
    end

    def write_lock(project, git)
      files = Gates.protected_hashes(project.repo, git.lines("ls-files"), project.cfg["gates"]["protect"])
      lock = { "commit" => git.head, "approved" => Util.now_iso, "files" => files }
      Util.write_json(project.lock_file, lock)
      lock
    end

    def update_state(project, sha, keep_blocked:)
      state = project.load_state
      state["head"] = sha
      unblock(project, state) unless keep_blocked
      project.save_state(state)
    end

    def unblock(project, state)
      state["tasks"].each do |id, ts|
        next unless ts["status"] == "blocked"

        ts.merge!("status" => "pending", "attempts" => 0, "last_err" => "", "last_diff" => "")
        FileUtils.rm_f(project.failure_file(id))
      end
    end
  end
end
