# frozen_string_literal: true

# Shared setup for the test suite. Run everything with `rake test` (or `ruby -Ilib -Itest -e
# 'Dir["test/*_test.rb"].each { |f| require_relative f }'`).

require "minitest/autorun"
require "nightshift"

# Gate commands run through Git Bash and call `ruby`; make sure the Ruby running the tests is
# the one they find, even if it is not on the user's PATH.
ENV["PATH"] = [Nightshift::Util.norm(RbConfig::CONFIG["bindir"]), ENV.fetch("PATH", "")].join(File::PATH_SEPARATOR)

module TestHelpers
  module_function

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text, mode: "wb") # "wb": LF line endings on Windows too
  end

  def git(repo, *args)
    out, err, status = Open3.capture3("git", "-C", repo.to_s, *args)
    raise "git #{args.join(' ')}: #{err}" unless status.success?

    out.strip
  end

  # Task notes that drive adapters/fake_agent.rb.
  def fake(*lines) = lines.map { |line| "FAKE: #{line}" }.join("\n")

  # Run `ns ARGS` in-process, as the shell would, and return its exit status.
  def ns(*args)
    Nightshift::CLI.start(args.map(&:to_s))
    0
  rescue SystemExit => e
    e.status
  end

  # Run a block with $stdout sent to +path+ (the loop logs every event to stdout).
  def quietly(path)
    saved = $stdout
    File.open(path, "a") do |log|
      $stdout = log
      yield
    end
  ensure
    $stdout = saved
  end
end
