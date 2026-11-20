# frozen_string_literal: true

module Nightshift
  # `ns init`: makes a state directory holding a dedicated clone of the user's repo (on its own
  # branch, with every remote removed so the worker can never push), the config and the
  # requirements template. With new_repo: it first turns an empty folder into a git repo with
  # one commit, for projects started from scratch. With in_place: there is no clone: a new
  # branch is checked out in the user's repo and the worker edits that repo (see TRADEOFFS.md).
  module Setup
    module_function

    # Returns the absolute path of the new state directory.
    def init(state, source:, new_repo: false, in_place: false, name: nil, branch: nil, ref: nil)
      state = File.expand_path(state)
      source = File.expand_path(source)
      raise Error, "#{state} is already initialised" if File.exist?(File.join(state, Project::CONFIG_FILE))

      name ||= File.basename(source)
      create_repo(source, name) if new_repo
      check_source(source, in_place: in_place)
      branch ||= "nightshift/#{Time.now.strftime('%Y%m%d')}"
      if in_place
        check_outside(state, source)
        repo = branch_in_place(source, branch: branch, ref: ref)
      else
        repo = clone(source, File.join(state, "repo"), branch: branch, ref: ref)
      end
      write_templates(state, name: name, source: source, branch: branch, in_place: in_place)
      report(state, repo, branch, in_place: in_place)
      state
    end

    def check_source(source, in_place: false)
      unless File.exist?(File.join(source, ".git"))
        raise Error, "#{source} is not a git repository (commit it first, or add --new to start a new project there)"
      end
      return unless Git.new(source).dirty?
      # Every failed attempt runs `git clean -fd`, which would delete uncommitted work.
      raise Error, "#{source} has uncommitted or untracked files; commit or stash them first (--in-place)" if in_place

      UI.warning("#{source} has uncommitted changes; they will NOT be in the clone")
    end

    # In place, the worker's root is the repo, so the state dir (hidden tests, journal) must
    # not be inside it.
    def check_outside(state, source)
      inside = "#{Util.norm(state)}/".downcase.start_with?("#{Util.norm(source)}/".downcase)
      raise Error, "#{state} is inside #{source}; put the state dir outside the repo" if inside
    end

    # An empty or missing folder becomes a repo whose first commit is a README, so the clone has
    # a base to reset to. The planner then builds the skeleton with the human.
    def create_repo(dir, name)
      raise Error, "#{dir} is already a git repository; drop --new" if File.exist?(File.join(dir, ".git"))
      if File.directory?(dir) && !Dir.empty?(dir)
        raise Error, "#{dir} is not empty. Use a new or empty folder with --new, or commit it and drop --new."
      end

      FileUtils.mkdir_p(dir)
      Util.write(File.join(dir, "README.md"), "# #{name}\n")
      system("git", "init", "-q", "-b", "main", dir, exception: true)
      git = Git.new(dir)
      git.run("add", "-A")
      git.run(*fallback_identity(git), "commit", "-q", "-m", "Start #{name}")
      UI.step(true, "created a new git repository at #{dir}")
    end

    # A fresh machine may have no git identity yet; commit as nightshift then.
    def fallback_identity(git)
      return [] unless git.run("config", "user.name", check: false).strip.empty?

      %w[-c user.name=nightshift -c user.email=nightshift@localhost]
    end

    def clone(source, repo, branch:, ref:)
      FileUtils.mkdir_p(File.dirname(repo))
      system("git", "clone", "-q", source, repo, exception: true)
      git = Git.new(repo)
      git.run("checkout", "-q", ref) if ref
      git.remotes.each { |remote| git.run("remote", "remove", remote) } # the worker can never push anywhere
      git.run("checkout", "-q", "-b", branch)
      repo
    end

    # Creates the branch in the user's own repo and checks it out there.
    def branch_in_place(source, branch:, ref:)
      git = Git.new(source)
      unless git.run("rev-parse", "--verify", "-q", "refs/heads/#{branch}", check: false).empty?
        raise Error, "branch #{branch} already exists in #{source}; pick another with --branch"
      end

      git.run("checkout", "-q", "-b", branch, *ref)
      source
    end

    def write_templates(state, name:, source:, branch:, in_place: false)
      template = Util.read(File.join(HOME, "templates", "project.yml"))
      vars = { "NAME" => name, "SOURCE" => Util.norm(source), "BRANCH" => branch,
               "REPO" => in_place ? Util.norm(source) : "repo", "IN_PLACE" => in_place.to_s }
      Util.write(File.join(state, Project::CONFIG_FILE), Prompts.render(template, vars))
      FileUtils.cp(File.join(HOME, "templates", "requirements.md"), File.join(state, "requirements.md"))
      FileUtils.mkdir_p([File.join(state, "holdout"), File.join(state, "runs")])
    end

    def report(state, repo, branch, in_place: false)
      UI.step(true, "initialised #{state}")
      if in_place
        UI.info("    in place: #{repo} is now on branch #{branch}; the worker edits this folder")
        UI.warning("in place: keep this repo on #{branch} with no uncommitted changes while a run is active; " \
                   "its remotes and ignored files (.env, ...) are within the worker's reach. See TRADEOFFS.md.")
      else
        UI.info("    clone: #{repo} (branch #{branch}, remotes removed)")
      end
      UI.next_step("edit #{File.join(state, Project::CONFIG_FILE)} (checks, protect list, adapters), " \
                   "write #{File.join(state, 'requirements.md')}, then: ns plan \"#{state}\"")
    end
  end
end
