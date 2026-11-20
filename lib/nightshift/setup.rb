# frozen_string_literal: true

module Nightshift
  # `ns init`: makes a state directory holding a dedicated clone of the user's repo (on its own
  # branch, with every remote removed so the worker can never push), the config and the
  # requirements template. With new_repo: it first turns an empty folder into a git repo with
  # one commit, for projects started from scratch.
  module Setup
    module_function

    # Returns the absolute path of the new state directory.
    def init(state, source:, new_repo: false, name: nil, branch: nil, ref: nil)
      state = File.expand_path(state)
      source = File.expand_path(source)
      raise Error, "#{state} is already initialised" if File.exist?(File.join(state, Project::CONFIG_FILE))

      name ||= File.basename(source)
      create_repo(source, name) if new_repo
      check_source(source)
      branch ||= "nightshift/#{Time.now.strftime('%Y%m%d')}"
      repo = clone(source, File.join(state, "repo"), branch: branch, ref: ref)
      write_templates(state, name: name, source: source, branch: branch)
      report(state, repo, branch)
      state
    end

    def check_source(source)
      unless File.exist?(File.join(source, ".git"))
        raise Error, "#{source} is not a git repository (commit it first, or add --new to start a new project there)"
      end

      UI.warning("#{source} has uncommitted changes; they will NOT be in the clone") if Git.new(source).dirty?
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

    def write_templates(state, name:, source:, branch:)
      template = Util.read(File.join(HOME, "templates", "project.yml"))
      Util.write(File.join(state, Project::CONFIG_FILE),
                 Prompts.render(template, "NAME" => name, "SOURCE" => Util.norm(source), "BRANCH" => branch))
      FileUtils.cp(File.join(HOME, "templates", "requirements.md"), File.join(state, "requirements.md"))
      FileUtils.mkdir_p([File.join(state, "holdout"), File.join(state, "runs")])
    end

    def report(state, repo, branch)
      UI.step(true, "initialised #{state}")
      UI.info("    clone: #{repo} (branch #{branch}, remotes removed)")
      UI.next_step("edit #{File.join(state, Project::CONFIG_FILE)} (checks, protect list, adapters), " \
                   "write #{File.join(state, 'requirements.md')}, then: ns plan \"#{state}\"")
    end
  end
end
