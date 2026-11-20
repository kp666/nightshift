# frozen_string_literal: true

module Nightshift
  # The morning report (REPORT.md): what happened, what to review, what is blocked and why.
  # Built only from facts the harness observed (state.json, journal.jsonl, git), never from
  # what workers claimed.
  class Report
    def self.write(project) = new(project).write

    def initialize(project)
      @project = project
      @state = project.load_state
      @tasks = project.load_tasks
      @night = @state["night"] || {}
      @git = Git.new(project.repo)
      @base = (project.lock || {}).fetch("commit", "")
    end

    # Writes REPORT.md and returns its path.
    def write
      sections = [summary, task_table, advisories, blocked, commits, next_steps].compact
      Util.write(@project.report_file, sections.join("\n"))
      @project.report_file
    end

    # `ns status`: the night, one line per task, and the last journal lines.
    def status(lines: 12)
      head = "#{@project.name}: night #{@night.fetch('id', '-')} #{@night['active'] ? 'ACTIVE' : 'idle'}, " \
             "iteration #{@night.fetch('iterations', 0)}, deadline #{@night['deadline'] || 'none'}, " \
             "stop: #{@night.fetch('stop_reason', '-')}"
      rows = @tasks.map do |task|
        ts = @state["tasks"].fetch(task["id"], {})
        format("  %-8<id>s %-8<status>s att %<n>d  %<title>s",
               id: task["id"], status: ts.fetch("status", "pending"), n: ts.fetch("attempts", 0), title: task["title"])
      end
      [head, *rows, *recent(lines)].join("\n")
    end

    # `ns land`: the git commands that bring the night's branch into the real repo. Nothing is
    # run: the human reviews and merges.
    def land
      source = @project.cfg["project"]["source"]
      branch = @git.branch
      base = @base.empty? ? "main" : @base[0, 10]
      <<~TEXT
        # Review and bring nightshift's work into your repo (nothing is merged automatically):
        git -C "#{source}" fetch "#{Util.norm(@project.repo)}" #{branch}:#{branch}
        git -C "#{source}" log --stat #{base}..#{branch}
        git -C "#{source}" diff #{base}..#{branch}
        # when satisfied (from your normal branch):
        git -C "#{source}" merge --no-ff #{branch}      # or cherry-pick individual task commits
      TEXT
    end

    private

    def recent(count)
      journal = Util.read(@project.journal_file).lines.last(count)
      return [] if journal.empty?

      ["recent:", *journal.map do |line|
        r = JSON.parse(line)
        "  #{r['t']} [#{r['kind']}] #{r['msg'].to_s[0, 150]}"
      end]
    end

    # Journal events of the current night only.
    def events
      @events ||= begin
        inside = @night["id"].to_s.empty?
        Util.read(@project.journal_file).each_line.filter_map do |line|
          record = JSON.parse(line)
          inside = record["msg"].to_s.include?(@night["id"].to_s) if record["kind"] == "night"
          record if inside
        rescue JSON::ParserError
          nil
        end
      end
    end

    def summary
      results = events.select { |e| e["kind"] == "result" }
      kept = results.count { |e| e["ok"] }
      minutes = results.sum { |e| Float(e.fetch("minutes", 0)) }
      adapters = results.group_by { |e| e.fetch("adapter", "?") }
                        .map { |name, rs| "#{name} #{rs.count { |e| e['ok'] }}/#{rs.size} kept" }
      <<~MD
        # nightshift report: #{@project.name}

        - Night: `#{@night.fetch('id', '-')}`, #{@night.fetch('started', '?')} to #{@night.fetch('ended', 'running')}
        - Stopped because: **#{@night.fetch('stop_reason', 'still running')}**
        - Attempts this night: #{results.size} (#{kept} kept), agent time #{minutes.round} min
        - Adapters: #{adapters.empty? ? 'none' : adapters.join(', ')}
        - Branch `#{@git.branch}` in `#{@project.repo}`
      MD
    end

    def task_table
      rows = @tasks.map do |task|
        ts = @state["tasks"].fetch(task["id"], { "status" => "pending", "attempts" => 0 })
        title = task["title"].to_s.tr("|", "/")
        "| #{task['id']} | #{title} | #{ts['status']} | #{ts.fetch('attempts', 0)} | #{note(ts)} |"
      end
      ["## Tasks", "", "| id | title | status | attempts | notes |", "|---|---|---|---|---|", *rows, ""].join("\n")
    end

    def note(ts)
      text = if ts["status"] == "blocked" then "#{ts['blocked_reason']} (gate: #{ts.fetch('blocked_gate', '?')})"
             elsif ts["commit"] then "commit `#{ts['commit'][0, 8]}`"
             else +""
             end
      text += " ⚠ #{ts['advisories'].size} advisory" if Array(ts["advisories"]).any?
      text
    end

    def advisories
      items = @tasks.flat_map do |task|
        Array(@state["tasks"].dig(task["id"], "advisories")).map { |a| "- **#{task['id']}**: #{a}" }
      end
      return nil if items.empty?

      ["## Review these first (advisories)", "",
       "Passing code that may be special-casing tests. Gates passed, but look closely.", "",
       *items, ""].join("\n")
    end

    def blocked
      tasks = @tasks.select { |t| @state["tasks"].dig(t["id"], "status") == "blocked" }
      return nil if tasks.empty?

      parts = tasks.map do |task|
        failure = Util.read(@project.failure_file(task["id"]))
        failure = failure.empty? ? "(no failure note)" : failure[-2500..] || failure
        "### #{task['id']}: #{task['title']}\n\n```\n#{failure}\n```\n"
      end
      ["## Blocked", "", *parts].join("\n")
    end

    def commits
      return nil if @base.empty?

      log = @git.run("log", "--format=%h %s", "#{@base}..HEAD", check: false)
      stat = @git.run("diff", "--stat", @base, "HEAD", check: false)
      text = "## Commits since approval\n\n```\n#{log.empty? ? '(none)' : log}\n```\n"
      text << "\n```\n#{stat[-3000..] || stat}\n```\n" unless stat.empty?
      text
    end

    def next_steps
      <<~MD
        ## Next steps

        1. Read the diffs: `git -C "#{@project.repo}" log -p #{@base.empty? ? '<base>' : @base[0, 8]}..HEAD`
        2. Bring the branch into your real repo: `ns land "#{@project.dir}"` (prints the commands; nothing is merged for you)
        3. For blocked tasks: read the failure note, then fix the task description, split it, or do it yourself, then `ns approve` and run another night.
      MD
    end
  end
end
