# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 4.0"

# The one runtime gem: the `ns` command line. Thor is pure Ruby (nothing to compile).
# bin/ns activates it with `gem "thor"` rather than `bundler/setup`; see README "Dependencies".
gem "thor", "~> 1.5"

# Development only: the tests, the rake tasks and the linter.
group :development, :test do
  gem "minitest", "~> 6.0"
  gem "rake", "~> 13.3"
  gem "rubocop", require: false
  gem "rubocop-minitest", require: false
  gem "rubocop-rake", require: false
end
