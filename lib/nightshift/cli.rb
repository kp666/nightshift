# frozen_string_literal: true

module Nightshift
  # ns: the nightshift command line (Thor). This class only declares the commands and their
  # options, checks option values, and calls a service. The work is in the services
  # (Setup, Planner, Checker, Approval, Night, Doctor, Report), and the printing in UI.
  #
  #   Attended (you, in the evening):  init -> write requirements.md -> plan -> check -> approve -> doctor
  #   Unattended (overnight):          run
  #   Attended (you, in the morning):  report / status -> land
  #
  # Every command except version takes the project state directory. Nothing ever prompts, so
  # every command works from scripts and from the Task Scheduler. A failed command exits 1;
  # a Nightshift::Error becomes a one-line message on stderr (see .dispatch).
  class CLI < Thor
    HH_MM = /\A([01]?\d|2[0-3]):[0-5]\d\z/

    package_name "nightshift"
    check_unknown_options!
    map %w[-v --version] => :version
    map "run" => :run_night # `run` is a reserved word in Thor

    def self.exit_on_failure? = true
    def self.basename = "ns"

    class << self
      protected

      # Every command's errors in one place: a Nightshift::Error becomes a Thor::Error, which
      # Thor prints (without a backtrace) before exiting 1.
      def dispatch(...)
        super
      rescue Error => e
        raise Thor::Error, "ns: #{e.message}"
      end
    end

    desc "version", "print the nightshift and Ruby versions"
    def version = UI.info("nightshift #{VERSION} (ruby #{RUBY_VERSION})")

    desc "init STATE_DIR", "create a state dir with a dedicated clone of your repo (or --in-place)"
    long_desc <<~TEXT
      Clones REPO into STATE_DIR/repo on a new branch and removes every remote, so the worker can
      never push. Writes nightshift.yml and a requirements.md template next to it.
      With --new, REPO may be a new or empty folder: it becomes a git repo first.
      With --in-place there is no clone: the branch is created and checked out in REPO itself, and
      the worker edits REPO. REPO must have no uncommitted or untracked files, and STATE_DIR must be
      outside it. TRADEOFFS.md explains what that gives up.
    TEXT
    method_option :source, required: true, banner: "REPO", desc: "your real git repo"
    method_option :new, type: :boolean, desc: "start a project from scratch: make REPO a new git repo first"
    method_option :in_place, type: :boolean, desc: "no clone: work on a new branch in REPO itself (big repos)"
    method_option :name, desc: "project name (default: the REPO folder name)"
    method_option :branch, desc: "the branch nightshift works on (default: nightshift/<date>)"
    method_option :ref, desc: "start from this commit or branch of REPO"
    def init(state)
      Setup.init(state, source: options[:source], new_repo: options[:new], in_place: options[:in_place],
                        name: options[:name], branch: options[:branch], ref: options[:ref])
    end

    desc "plan STATE_DIR", "turn requirements.md into tasks and acceptance tests, with a planner agent"
    method_option :headless, type: :boolean, desc: "run the planner without you (no interactive session)"
    method_option :adapter, desc: "planner adapter (default: roles.planner)"
    method_option :print_prompt, type: :boolean, desc: "only write and print the planner prompt"
    method_option :harvest, type: :boolean, desc: "only collect a plan the planner already wrote"
    def plan(state)
      planner = Planner.new(project(state))
      if options[:print_prompt]
        UI.info(planner.write_prompt)
        warn "(also saved to #{planner.prompt_file})"
      elsif options[:harvest]
        planner.harvest
      else
        planner.run(adapter: options[:adapter], headless: options[:headless])
      end
    end

    desc "check STATE_DIR", "validate the plan: every acceptance check must fail now"
    method_option :run, type: :boolean, default: true, desc: "run the commands (--no-run: static checks only)"
    method_option :allow_red_global, type: :boolean, desc: "do not fail when the global gates fail now"
    def check(state)
      ok = Checker.new(project(state)).run(commands: options[:run], allow_red_global: options[:allow_red_global])
      exit 1 unless ok
    end

    desc "approve STATE_DIR", "commit the contract and lock the protected files"
    method_option :keep_blocked, type: :boolean, desc: "do not reset blocked tasks to pending"
    def approve(state) = Approval.approve(project(state), keep_blocked: options[:keep_blocked])

    desc "run STATE_DIR", "run the unattended loop now (until the work is done, unless limited)"
    method_option :until, banner: "HH:MM", desc: "stop before this local time"
    method_option :hours, type: :numeric, desc: "stop after this many hours"
    method_option :limit, type: :boolean, default: true,
                          desc: "honour the time limit in nightshift.yml (--no-limit: run until the work is done)"
    method_option :max_iterations, type: :numeric, banner: "N", desc: "cap the number of attempts"
    method_option :fresh, type: :boolean, desc: "start a new night even if one is still active"
    def run_night(state)
      until_time = clock(:until)
      hours = options[:limit] ? positive(:hours) : 0
      prj = project(state)
      prj.cfg["budgets"].merge!("hours" => hours, "until" => "") if hours
      FileUtils.rm_f(prj.stop_file)
      code = Night.new(prj, until_time: until_time, max_iterations: positive(:max_iterations)&.to_i,
                            fresh: options[:fresh]).run
      exit code unless code.zero?
    end

    desc "stop STATE_DIR", "stop the loop gracefully after the current attempt"
    def stop(state)
      prj = project(state)
      Util.write(prj.stop_file, Util.now_iso)
      UI.step(true, "STOP written (#{prj.stop_file}); the loop stops after the current attempt")
    end

    desc "status STATE_DIR", "show the night, the tasks and the latest journal lines"
    method_option :lines, type: :numeric, default: 12, banner: "N", desc: "journal lines to show"
    def status(state) = UI.info(Report.new(project(state)).status(lines: positive(:lines).to_i))

    desc "report STATE_DIR", "write REPORT.md and print it"
    def report(state) = UI.info(Util.read(Report.write(project(state))))

    desc "doctor STATE_DIR", "preflight checks before an unattended night"
    def doctor(state)
      exit 1 unless Doctor.new(project(state)).run
    end

    desc "land STATE_DIR", "print the git commands that review and merge the night's work"
    def land(state) = UI.info(Report.new(project(state)).land)

    no_commands do
      def project(state) = Project.new(state)

      # The option as HH:MM, or nil when it was not given.
      def clock(name)
        value = options[name] or return nil
        raise Error, "--#{name} must be a time like 23:30, not #{value.inspect}" unless value.match?(HH_MM)

        value
      end

      # The option as a number above zero, or nil when it was not given.
      def positive(name)
        value = options[name] or return nil
        raise Error, "--#{name.to_s.tr('_', '-')} must be greater than 0" unless value.positive?

        value
      end
    end
  end
end
