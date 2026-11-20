# frozen_string_literal: true

# Development tasks. Run them through Bundler so the Gemfile's versions are used:
#   bundle exec rake            tests (default)
#   bundle exec rake lint       RuboCop
#   bundle exec rake lint:fix   RuboCop safe autocorrect
#   bundle exec rake guard      the pi guard extension's tests (Node 22.6+)

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/*_test.rb"]
  t.warning = true
end

desc "Lint with RuboCop"
task :lint do
  sh "rubocop"
end

namespace :lint do
  desc "Apply RuboCop's safe autocorrections, keeping LF line endings"
  task :fix do
    sh("rubocop", "-a") { |_ok, _status| nil } # non-zero while offenses remain; that is fine here
    # On Windows RuboCop rewrites corrected files with CRLF; the project is LF everywhere.
    FileList["**/*.rb", "Rakefile", "Gemfile", "bin/*"].each do |path|
      text = File.binread(path)
      File.binwrite(path, text.gsub("\r\n", "\n")) if text.include?("\r\n")
    end
  end
end

desc "Test the pi guard extension (needs Node 22.6+)"
task :guard do
  sh "node", "--experimental-strip-types", "--no-warnings", "test/guard_test.mjs"
end

task default: :test
