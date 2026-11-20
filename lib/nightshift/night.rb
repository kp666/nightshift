# frozen_string_literal: true

module Nightshift
  # The night loop. The orchestrator owns the loop, git, verification and the "done" decision.
  #
  # Per iteration:
  #   pick task -> reset repo to last good commit -> fresh worker session (adapter)
  #   -> stage diff -> gates (Verifier) -> commit (keep) or reset (discard) -> fingerprint -> next
  #
  # Nothing the worker says is trusted; its DONE/STUCK lines are logged only.
  class Night
    HIDDEN_FAIL_NOTE = "A hidden acceptance test (one you cannot see) failed. Re-read the task description: " \
                       "the implementation must be correct in general, not only for the cases in the visible " \
                       "tests. Never hard-code expected values."
    MIN_MINUTES_LEFT = 10 # do not start an attempt with less time than this before the deadline (if any)

    attr_reader :project, :cfg, :git, :tasks, :state, :shell

    # Hash of an error message with timings and hashes blanked out, so "the same failure twice"
    # is recognised even when durations or object ids differ.
    def self.fingerprint(text)
      normalized = text.gsub(/\d+(\.\d+)?\s*(ms|s|sec|seconds)\b/, "N")
                       .gsub(/0x[0-9a-f]+|\b[0-9a-f]{7,40}\b/, "H")
                       .gsub(/\s+/, " ")
      Digest::SHA256.hexdigest(normalized)[0, 16]
    end

    # The local time to stop, or nil for no time limit (the run then ends when the work is done
    # or a safety stop trips). --until / budgets.until is "HH:MM" (next occurrence); hours > 0
    # means now + hours; neither means no limit.
    def self.deadline(budgets, start, until_arg = nil)
      clock = until_arg.to_s.empty? ? budgets["until"].to_s : until_arg.to_s
      if clock.empty?
        hours = Float(budgets["hours"] || 0)
        return hours.positive? ? start + (hours * 3600) : nil
      end

      hour, minute = clock.split(":").map { |part| Integer(part, 10) }
      stop = Time.new(start.year, start.month, start.day, hour, minute, 0)
      stop <= start ? stop + 86_400 : stop
    end

    # Summarise the pi guard's path repairs/misses (guard.jsonl) as lines for the next prompt.
    # Returns [lines, fixed_count, missed_count].
    def self.path_events(run_dir)
      lines = []
      fixed = missed = 0
      Util.read(File.join(run_dir, "guard.jsonl")).each_line do |raw|
        event = JSON.parse(raw)
        case event["kind"]
        when "path_repaired"
          fixed += 1
          lines << "- you used '#{event['from']}'; the correct path is '#{event['to']}'"
        when "path_miss"
          missed += 1
          suggestions = Array(event["suggestions"]).first(3)
          lines << "- '#{event['path']}' does not exist#{" (existing: #{suggestions.join(', ')})" if suggestions.any?}"
        end
      rescue JSON::ParserError
        next
      end
      [lines.uniq.first(12), fixed, missed]
    end

    def initialize(project, until_time: nil, max_iterations: nil, fresh: false)
      @project = project
      @cfg = project.cfg
      @budgets = cfg["budgets"]
      @gates = cfg["gates"]
      @git = Git.new(project.repo)
      @tasks = project.load_tasks
      @state = project.load_state
      @shell = project.shell
      @server = Machine::Server.new(cfg["server"], method(:log))
      @max_iterations = max_iterations || Integer(@budgets["max_iterations"])
      @until_time = until_time
      @fresh = fresh
    end

    # ------------------------------------------------------------------ bookkeeping

    def log(kind, **fields)
      record = { "t" => Util.now_iso, "kind" => kind }.merge(fields.transform_keys(&:to_s))
      Util.append(project.journal_file, "#{JSON.generate(record)}\n")
      message = fields[:msg] || fields.except(:detail).map { |key, value| "#{key}=#{value}" }.join(" ")
      $stdout.puts "#{record['t']} [#{kind}] #{message}"
      $stdout.flush
    end

    def progress(line) = Util.append(project.progress_file, "#{Util.now_iso} #{line}\n")

    def task_state(id) = (state["tasks"][id] ||= { "status" => "pending", "attempts" => 0 })

    def save = project.save_state(state)

    # Paths tracked at the last good commit.
    def tracked = git.tracked(state["head"])

    def protect = @gates["protect"]

    def satisfied?(id) = task_state(id)["status"] == "passed"

    def counts = tasks.map { |task| task_state(task["id"])["status"] }.tally

    # ------------------------------------------------------------------ main

    # Runs until a stop condition; returns 0 if every task passed, else 1.
    def run
      preflight
      night = start_or_resume
      state["night"] = night
      save
      reason = "?"
      begin
        reason = work_until_stopped(night, night["deadline"] && Time.parse(night["deadline"]))
      rescue Interrupt, StandardError => e
        reason = "crashed: #{e.class}: #{e.message}"[0, 300]
        raise
      ensure
        night.merge!("active" => false, "ended" => Util.now_iso, "stop_reason" => reason)
        save
      end
      finish(reason)
    end

    private

    def preflight
      problems = Plan.problems(tasks)
      raise Error, "tasks.json problems:\n  #{problems.join("\n  ")}" if problems.any?

      lock = project.lock
      raise Error, "No contract.lock. Review the plan and run `ns approve` first." unless lock

      state["head"] = lock["commit"] if state["head"].to_s.empty?
      recover_repo(state["head"])
      lock["files"].each do |rel, hash|
        path = File.join(project.repo, rel)
        next if File.file?(path) && Util.sha256(path) == hash

        raise Error, "Protected file changed since approval: #{rel}. Re-run `ns approve` if intended."
      end
      return if state["inflight"].to_s.empty?

      log("recover", msg: "attempt #{state['inflight']} was interrupted (crash/reboot); discarded")
      state["inflight"] = ""
    end

    # Bring the repo back to the last good commit, e.g. after a crash mid-attempt.
    def recover_repo(head)
      branch = git.branch
      raise Error, "Refusing to run on '#{branch}'." if %w[main master].include?(branch)

      if project.in_place?
        check_in_place(head)
      elsif git.remotes.any?
        log("warn", msg: "repo has remotes; nightshift never pushes, but removing them is safer")
      end
      return unless git.head != head || git.dirty?

      log("recover", msg: "repo not at last good commit #{head[0, 8]}; resetting (interrupted attempt?)")
      git.reset_to(head)
    end

    # In place the repo is yours, so nightshift refuses to start rather than reset away work it
    # did not make. The one exception is the leftovers of its own interrupted attempt.
    def check_in_place(head)
      change = outside_change(head)
      return if change.nil? || (!change.start_with?("on branch") && !state["inflight"].to_s.empty?)

      raise Error, "In-place repo #{project.repo}: #{change}. nightshift never discards work it did not make: " \
                   "commit it on another branch (or stash it), check out #{project.branch}, then run again."
    end

    # nil, or how the in-place repo differs from where nightshift left it.
    def outside_change(head)
      branch = git.branch
      return "on branch #{branch}, not #{project.branch}" if !project.branch.empty? && branch != project.branch
      return "new commits after the last good commit #{head[0, 8]}" if git.head != head
      return "uncommitted or untracked files" if git.dirty?

      nil
    end

    def start_or_resume
      now = Time.now
      night = state["night"] || {}
      if !@fresh && night["active"] && (night["deadline"].nil? || Time.parse(night["deadline"]) > now)
        log("resume", msg: "resuming night #{night['id']} (deadline #{night['deadline'] || 'none'})")
        return night
      end

      deadline = self.class.deadline(@budgets, now, @until_time)
      night = { "id" => now.strftime("%Y%m%d-%H%M%S"), "started" => Util.now_iso,
                "deadline" => deadline&.strftime("%Y-%m-%dT%H:%M:%S"), "iterations" => 0, "consec_fail" => 0,
                "escalations" => 0, "active" => true }
      until_text = night["deadline"] || "the work is done (no time limit)"
      log("night", msg: "night #{night['id']} until #{until_text}, worker=#{cfg['roles']['worker']}")
      night
    end

    # The loop body. Returns the stop reason.
    def work_until_stopped(night, deadline)
      loop do
        return "STOP file present" if File.exist?(project.stop_file)

        minutes_left = deadline ? (deadline - Time.now) / 60 : Float::INFINITY
        return "deadline reached" if minutes_left < MIN_MINUTES_LEFT
        return "iteration cap #{@max_iterations}" if night["iterations"] >= @max_iterations
        if night["consec_fail"] >= Integer(@budgets["max_consecutive_failures"])
          return "circuit breaker: #{night['consec_fail']} failed attempts in a row"
        end

        change = project.in_place? && outside_change(state["head"])
        return "in-place repo changed outside nightshift (#{change}); stopped so nothing of yours is lost" if change

        task = eligible
        return "no eligible task left" if task.nil?
        return "model server down" unless @server.ensure_up

        night["iterations"] += 1
        attempt(task, night, minutes_left)
        save
      end
    end

    def finish(reason)
      log("end", msg: "stopped: #{reason}")
      report = Report.write(project)
      tally = counts
      summary = tally.map { |status, n| "#{status} #{n}" }.join(", ")
      Machine.notify(cfg["notify"]["cmd"], "nightshift #{project.name}", "#{reason}; #{summary}. Report: #{report}")
      tally.fetch("passed", 0) == tasks.size ? 0 : 1
    end

    # ------------------------------------------------------------------ selection

    # The first pending task whose dependencies are satisfied.
    def eligible
      tasks.find do |task|
        task_state(task["id"])["status"] == "pending" && Plan.depends_on(task).all? { |dep| satisfied?(dep) }
      end
    end

    # ------------------------------------------------------------------ one attempt

    def attempt(task, night, minutes_left)
      id = task["id"]
      ts = task_state(id)
      head = state["head"]
      number = ts["attempts"] + 1
      tag = format("%<night>s-%<iter>03d-%<id>s-a%<n>d", night: night["id"], iter: night["iterations"], id: id,
                                                         n: number)
      run_dir = File.join(project.runs, tag)
      FileUtils.mkdir_p(run_dir)
      git.reset_to(head)

      max_attempts = Integer(task.fetch("maxAttempts", @budgets["max_attempts"]))
      adapter_name = cfg["roles"][pick_role(number, max_attempts, night)]
      spec = project.adapter(adapter_name)
      prompt_file = File.join(run_dir, "prompt.md")
      Util.write(prompt_file, Briefing.new(self).worker_prompt(task))
      time_left_min = [minutes_left - 5, 10].max # always leave room for one real attempt
      timeout_min = [Float(spec.fetch("timeout_min", @budgets["attempt_timeout_min"])), time_left_min].min
      state["inflight"] = tag
      save
      log("attempt", task: id, attempt: number, adapter: adapter_name,
                     msg: "[#{tag}] #{task['title']} via #{adapter_name}")

      run = Adapters.run_agent(spec, prompt_file: prompt_file, cwd: project.repo, run_dir: run_dir,
                                     timeout_s: timeout_min * 60,
                                     extra_vars: { "state" => project.dir, "protect_csv" => protect.join(","),
                                                   "guard_minutes" => [timeout_min - 8, 5].max.to_i.to_s,
                                                   "max_turns" => task.fetch("maxTurns", 50).to_s })
      ensure_branch
      changed = git.stage_all_from(head)
      patch = git.staged_patch(File.join(run_dir, "diff.patch"))
      verdict = Verifier.new(self).verify(task, git.staged_status, patch, run_dir)
      result = verdict.result
      minutes = (run.seconds / 60).round(1)
      path_lines, path_fixed, path_missed = self.class.path_events(run_dir)
      record = { task: id, attempt: number, adapter: adapter_name, rc: run.rc, timed_out: run.timed_out,
                 said: run.said, changed: changed.size, minutes: minutes,
                 gate: result.gate.empty? ? "all" : result.gate,
                 ok: result.ok?, path_fixed: path_fixed, path_missed: path_missed }
      if path_fixed.positive? || path_missed.positive?
        ts["path_fixed"] = ts.fetch("path_fixed", 0) + path_fixed
        ts["path_missed"] = ts.fetch("path_missed", 0) + path_missed
      end
      outcome = result.ok? ? "KEEP" : "DISCARD at #{result.gate}"
      log("result", **record, msg: "[#{tag}] agent rc=#{run.rc}#{' TIMEOUT' if run.timed_out?} " \
                                   "changed=#{changed.size} -> #{outcome} (#{minutes} min)")
      ts["attempts"] = number
      (ts["history"] ||= []) << record.slice(:attempt, :adapter, :minutes, :gate, :ok).transform_keys(&:to_s)
      ts["advisories"] = (Array(ts["advisories"]) + verdict.advisories).uniq.sort if verdict.advisories.any?

      if result.ok?
        keep(task, ts, night, tag: tag, adapter: adapter_name, changed: changed, minutes: minutes)
      else
        git.reset_to(head)
        on_failure(task, ts, night, result: result, run: run, changed: changed, patch: patch,
                                    number: number, max_attempts: max_attempts, path_lines: path_lines)
      end
      state["inflight"] = ""
    end

    # In place, someone may switch branches while the agent runs. Staging and committing would then
    # move that other branch, so stop instead; the next run's preflight explains what to do.
    def ensure_branch
      return unless project.in_place? && !project.branch.empty?

      branch = git.branch
      raise Error, "In-place repo switched to #{branch} during an attempt; stopping" if branch != project.branch
    end

    # The last attempt of a task may go to a stronger (paid) adapter.
    def pick_role(number, max_attempts, night)
      return "worker" if number < max_attempts
      return "worker" if cfg["roles"]["escalate"].to_s.empty?
      return "worker" if night["escalations"] >= Integer(@budgets["max_escalations"])

      night["escalations"] += 1
      "escalate"
    end

    def keep(task, ts, night, tag:, adapter:, changed:, minutes:)
      id = task["id"]
      sha = git.commit_index("#{id}: #{task['title']}", "nightshift #{tag}\nadapter: #{adapter}")
      state["head"] = sha
      git.reset_to(sha)
      night["consec_fail"] = 0
      ts.merge!("status" => "passed", "commit" => sha, "minutes" => minutes, "last_err" => "", "last_diff" => "")
      progress("#{id} PASS on attempt #{ts['attempts']} (#{minutes} min). Files: #{changed.first(8).join(', ')}")
      FileUtils.rm_f(project.failure_file(id))
    end

    # Write the failure note for the next attempt; block the task after max attempts or when the
    # same failure happens twice with the same (or no) change.
    def on_failure(task, ts, night, result:, run:, changed:, patch:, number:, max_attempts:, path_lines:)
      id = task["id"]
      detail = result.gate == "holdout" ? HIDDEN_FAIL_NOTE : result.detail
      err_fp = self.class.fingerprint(detail)
      diff_fp = self.class.fingerprint(patch)
      same = ts["last_err"] == err_fp && (changed.empty? || ts["last_diff"] == diff_fp)
      ts.merge!("last_err" => err_fp, "last_diff" => diff_fp)
      why = if run.timed_out? then "the session hit the time limit before finishing"
            elsif changed.empty? then "you made no changes"
            else "the '#{result.gate}' check failed"
            end
      note = "Attempt #{number} failed because #{why}. All changes from that attempt were discarded; " \
             "the repository is back at the last good commit.\n#{detail}\n"
      if path_lines.any?
        note << "\nPath mistakes in that attempt (paths are relative to the repository root, which is " \
                "your working directory):\n#{path_lines.join("\n")}\n"
      end
      Util.write(project.failure_file(id), note)
      progress("#{id} FAIL attempt #{number} at #{result.gate.empty? ? 'agent' : result.gate}")
      night["consec_fail"] += 1
      reason = if number >= max_attempts then "#{number} attempts failed"
               elsif same then "same failure with the same (or no) change twice"
               end
      return unless reason

      ts.merge!("status" => "blocked", "blocked_reason" => reason, "blocked_gate" => result.gate)
      log("blocked", task: id, msg: "#{id} BLOCKED: #{reason}")
    end
  end
end
