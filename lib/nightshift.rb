# frozen_string_literal: true

# nightshift: an orchestrator-owned, agent-agnostic loop for unattended, verified coding.
#
# Load order matters only in that every file below may use the constants defined here.
# See README.md for the design and CONVENTIONS.md for how the code is organised.

require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "time"
require "tmpdir"
require "yaml"

require "thor" # the one runtime gem (the command line); bin/ns activates it

module Nightshift
  VERSION = "0.2.0"

  # The nightshift install folder (the one holding bin/, lib/, adapters/, templates/).
  HOME = File.expand_path("..", __dir__)
  CATALOG = File.join(HOME, "adapters", "adapters.yml")
  PROMPTS = File.join(HOME, "templates", "prompts")
  WINDOWS = Gem.win_platform?

  # A problem the user must fix (bad config, missing approval, ...). Services raise it; the CLI
  # prints the message and exits 1 instead of showing a backtrace.
  class Error < StandardError; end
end

require_relative "nightshift/util"
require_relative "nightshift/exec"
require_relative "nightshift/pane"
require_relative "nightshift/git"
require_relative "nightshift/plan"
require_relative "nightshift/project"
require_relative "nightshift/adapters"
require_relative "nightshift/gates"
require_relative "nightshift/machine"
require_relative "nightshift/prompts"
require_relative "nightshift/handover"
require_relative "nightshift/briefing"
require_relative "nightshift/verifier"
require_relative "nightshift/night"
require_relative "nightshift/report"
require_relative "nightshift/ui"
require_relative "nightshift/setup"
require_relative "nightshift/planner"
require_relative "nightshift/checker"
require_relative "nightshift/approval"
require_relative "nightshift/doctor"
require_relative "nightshift/cli"
