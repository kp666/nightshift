# frozen_string_literal: true

module Nightshift
  # Builds the worker prompt for one attempt (templates/prompts/worker.md): the task, exact
  # verified file paths, the repo layout, the earlier attempts of this task, what earlier tasks
  # added (the warm handoff, see Handover) and recent progress.
  class Briefing
    def initialize(night)
      @night = night
      @project = night.project
    end

    def worker_prompt(task)
      files, layout = path_context(task)
      Prompts.build(@project, "worker.md",
                    "PROJECT" => @project.name, "ID" => task["id"], "TITLE" => task["title"],
                    "DESCRIPTION" => task["description"], "FILES" => files, "LAYOUT" => layout,
                    "CHECKS" => checks(task), "NOTES" => task["notes"],
                    "PROGRESS" => recent_progress, "PROTECT" => @night.protect.join(", "),
                    "LAST_FAILURE" => last_failure(task), "BUILT" => built)
    end

    # Exact paths for the prompt: each task file marked as existing or new (and corrected when
    # the planner got it wrong), plus the top-level layout and the files next to the task files.
    # Local models guess paths; giving them verified ones prevents most path mistakes.
    def path_context(task)
      tracked = @night.tracked
      known = tracked.to_set
      by_name = tracked.group_by { |t| File.basename(t).downcase }
      task_files = Array(task["files"]).map { |f| Util.norm(f) }
      items = task_files.map do |file|
        same_name = by_name.fetch(File.basename(file).downcase, [])
        if known.include?(file) then "- `#{file}` (exists)"
        elsif same_name.size == 1 then "- `#{same_name.first}` (exists; the plan said `#{file}`)"
        else "- `#{file}` (new file)"
        end
      end
      tops = tracked.map { |t| t.include?("/") ? "#{t.split('/').first}/" : t }.uniq.sort
      dirs = task_files.select { |f| f.include?("/") }.to_set { |f| File.dirname(f) }
      near = tracked.select { |t| t.include?("/") && dirs.include?(File.dirname(t)) }.first(40)
      layout = "Top level: #{tops.first(40).map { |t| "`#{t}`" }.join(', ')}"
      layout << "\nFiles next to the task files:\n#{near.map { |t| "- `#{t}`" }.join("\n")}" if near.any?
      [items.empty? ? "(your choice)" : items.join("\n"), layout]
    end

    private

    def checks(task) = Plan.checks(task).map { |c| "    #{c}" }.join("\n")

    def recent_progress
      lines = Util.read(@project.progress_file).lines.last(12)
      lines.empty? ? "(nothing yet)" : lines.join.chomp
    end

    def last_failure(task)
      Handover.previous_attempts(@night.task_state(task["id"])["tried"],
                                 Util.read(@project.failure_file(task["id"])))
    end

    # Definitions added by the tasks kept so far, in plan order.
    def built
      kept = @night.tasks.filter_map do |task|
        ts = @night.task_state(task["id"])
        [task["id"], ts["added"]] if ts["status"] == "passed"
      end
      Handover.built(kept)
    end
  end
end
