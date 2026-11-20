# frozen_string_literal: true

module Nightshift
  # The task plan (tasks.json): what the planner wrote and the human approved.
  #
  # A task is a Hash with string keys (it round-trips through JSON):
  #   id, title, description, files, checks, holdout {files, checks}, dependsOn, notes,
  #   maxAttempts, maxTurns
  module Plan
    module_function

    def depends_on(task) = Array(task["dependsOn"])
    def holdout_files(task) = Array(task.dig("holdout", "files"))
    def holdout_checks(task) = Array(task.dig("holdout", "checks"))
    def checks(task) = Array(task["checks"])

    # Returns a list of problems with the plan (empty means OK).
    def problems(tasks)
      errors = []
      ids = Set.new
      tasks.each do |task|
        id = task["id"]
        if id.to_s.empty?
          errors << "task without id: #{task['title']}"
          next
        end
        errors << "duplicate id #{id}" if ids.include?(id)
        ids << id
        errors << "#{id}: needs at least one check command" if checks(task).empty?
      end
      # A second pass: the dependencies can only be checked once every id is known.
      tasks.each do |task| # rubocop:disable Style/CombinableLoops
        depends_on(task).each do |dep|
          errors << "#{task['id']}: depends on unknown task #{dep}" unless ids.include?(dep)
        end
      end
      errors.concat(cycles(tasks))
    end

    # Depth-first search for dependency cycles.
    def cycles(tasks)
      graph = tasks.filter_map { |t| [t["id"], depends_on(t)] if t["id"] }.to_h
      errors = []
      done = Set.new
      on_path = Set.new
      visit = lambda do |node|
        if on_path.include?(node)
          errors << "dependency cycle through #{node}"
          return
        end
        return if done.include?(node)

        on_path << node
        graph.fetch(node, []).each { |next_node| visit.call(next_node) }
        on_path.delete(node)
        done << node
      end
      graph.each_key { |node| visit.call(node) }
      errors.uniq
    end
  end
end
