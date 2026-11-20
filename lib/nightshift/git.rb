# frozen_string_literal: true

module Nightshift
  # Git operations on the repo the worker edits (the clone, or your own repo in place). The
  # harness owns git; workers never commit (and if they do, their commits are folded back into
  # the index and judged like any edit).
  class Git
    class Failed < Error; end

    attr_reader :repo

    def initialize(repo)
      @repo = repo.to_s
    end

    # Run `git -C <repo> args...` and return stripped stdout. Raises Failed on a nonzero exit
    # unless check: false.
    def run(*args, check: true)
      out, err, status = Open3.capture3("git", "-C", repo, *args.map(&:to_s))
      out = out.force_encoding(Encoding::UTF_8).scrub
      if check && !status.success?
        err = err.force_encoding(Encoding::UTF_8).scrub.strip
        raise Failed, "git #{args.join(' ')} failed (#{status.exitstatus}): #{err}"
      end
      out.strip
    end

    def lines(*) = run(*).lines.map(&:chomp).reject(&:empty?)

    def head = run("rev-parse", "HEAD")
    def branch = run("rev-parse", "--abbrev-ref", "HEAD")
    def dirty? = !run("status", "--porcelain").empty?
    def remotes = lines("remote")

    # Discard everything the worker did: tracked edits, commits and untracked files.
    # Ignored files (node_modules, build output) survive, which keeps resets fast.
    def reset_to(sha)
      run("reset", "-q", "--hard", sha)
      run("clean", "-fdq")
    end

    # Fold any worker commits back into the index and stage the full change set relative to
    # +base+. Returns the changed paths.
    def stage_all_from(base)
      run("reset", "-q", "--soft", base) if head != base
      run("add", "-A")
      lines("diff", "--cached", "--name-only", "--no-renames")
    end

    # [[status, path], ...] for the staged change set, e.g. [["A", "src/x.ts"], ["M", "README.md"]].
    def staged_status
      lines("diff", "--cached", "--name-status", "--no-renames").map do |line|
        status, path = line.split("\t", 2)
        [status.strip, path.to_s.strip]
      end
    end

    def staged_patch(out_file)
      patch = run("diff", "--cached", "--binary")
      Util.write(out_file, "#{patch}\n")
      patch
    end

    def commit_index(subject, body = "")
      args = ["commit", "-q", "--no-verify", "--allow-empty", "-m", subject]
      args += ["-m", body] unless body.empty?
      run(*args)
      head
    end

    # Files tracked at +ref+ (default HEAD).
    def tracked(ref = "HEAD") = lines("ls-tree", "-r", "--name-only", ref)
  end
end
