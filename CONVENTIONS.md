# Coding conventions

These rules apply to nightshift's own code. Follow them when you change or extend it. The goal
is code that someone who knows Ruby but not this project can read, change and trust overnight.

## 1. Language and dependencies

- **Ruby 4.0+. The runtime uses the standard library plus one gem, Thor (`~> 1.5`),** for the
  command line. `lib/` otherwise uses `json`, `yaml`, `open3`, `digest`, `fileutils`, `tmpdir`
  and `net/http`. Only `cli.rb` and `ui.rb` may use Thor; the services must not, so
  they stay callable from tests and from other code. Do not add another runtime gem without
  writing down why the stdlib cannot do the job, and pin it in the Gemfile outside the
  development group.
- **`bin/ns` never loads `bundler/setup`.** It activates Thor with `gem "thor", "~> 1.5"`.
  Bundler would export `BUNDLE_GEMFILE` and `RUBYOPT` to every gate command, and break
  `bundle exec` in a target Ruby project.
- **Development tools are gems in the `Gemfile`** (`:development, :test` group): minitest,
  rake, rubocop, rubocop-minitest and rubocop-rake. Commit `Gemfile.lock`, and run tools
  through `bundle exec`.
- Every `.rb` file starts with `# frozen_string_literal: true`. When you need a mutable string,
  build it with `+""` or `String.new`.
- Use modern syntax where it reads better:
  - endless methods for one-liners (`def head = run("rev-parse", "HEAD")`);
  - `Data.define` for value objects;
  - `filter_map`, `to_h { }` and `to_set`;
  - numbered or `it` block parameters only in very short blocks.

## 2. Structure

- Everything lives in the `Nightshift` namespace, with one file per module or class in
  `lib/nightshift/`. `lib/nightshift.rb` requires the stdlib and Thor, defines the shared constants
  (`VERSION`, `HOME`, `CATALOG`, `PROMPTS`, `WINDOWS`) and `Error`, and loads the files in
  dependency order.
- `lib/ARCHITECTURE.md` maps the code: each file's job, who calls whom, the night loop and
  where state lives. Read it before the code, and update it in the same change whenever a file
  under `lib/` is added, removed, renamed or split, or the calls between them change.
  `test/docs_test.rb` fails if a `lib/` file is missing from it.
- **Modules with `module_function`** hold stateless helpers: `Util`, `Exec`, `Plan`, `Gates`,
  `Adapters`, `Prompts`, `Machine` and `UI`, and the stateless command services
  `Setup` and `Approval`.
- **Classes** hold state:
  - `Project` is the config plus the state directory.
  - `Git` wraps one repo.
  - `Night` is the loop.
  - `Verifier` and `Briefing` are helpers created by `Night`.
  - `Report` writes the morning report and the `status` and `land` text.
  - `Planner`, `Checker` and `Doctor` are command services built on a `Project`.
  - `CLI` is the Thor command line.
  - `Pane` runs agents in tmux panes for `ns run --tmux`, and hosts the night in its session.
- Keep each class to one job. When a class grows a second job, split it out as a
  collaborator, the way `Verifier` and `Briefing` were split from `Night`.
  `night.rb` (about 330 lines) is the ceiling for a class with real logic.
- **The command line is thin.** `CLI` (a `Thor` subclass) only declares each command's
  `desc` and `method_option`s, checks option values (`clock` for HH:MM, `positive` for
  numbers), and calls one service:

  | Command | Service |
  |---|---|
  | `init` | `Setup.init` |
  | `plan` | `Planner` |
  | `check` | `Checker` |
  | `approve` | `Approval.approve` |
  | `run` | `Night` |
  | `doctor` | `Doctor` |
  | `status`, `land`, `report` | `Report` |

  Services take plain Ruby arguments (never Thor's `options`), raise `Error` for anything the
  user must fix, and return a value (`true`/`false`, a path, the tasks) rather than an exit
  code. The CLI turns `false` into `exit 1`.
- **All command output goes through `UI`**: `UI.step(ok, msg)` for one checked step (✔/✘ in a
  terminal, `ok`/`FAIL` in a log file), `UI.heading`, `UI.info`, `UI.warning` and
  `UI.next_step` for the command to run next. Do not `puts` from a service. `Night#log` is
  the exception: it writes the night's event log, not UI.
- **Nothing prompts.** Every command must work unattended (scripts, the Task Scheduler,
  tests), so there is no interactive input anywhere. The one interactive step, `ns plan`
  without `--headless`, hands the terminal to the planner agent itself. The other exception is
  the end of `ns run --tmux`: inside its own tmux session, with a terminal, it waits for Enter so
  the summary can be read before the session closes.
- Name things after what they mean in the domain: gate, attempt, task, night, holdout,
  advisory. Do not name them after how they are implemented.
- The process module is called `Exec`. Do not name anything `Process` or `Proc`, because
  those would shadow Ruby core classes. Never define a method named `fail`, `format`, `puts`,
  `exit` or `system` either. For example, the gate failure helper is `Gates.failed`.

## 3. Data

- **Hashes use string keys** everywhere (tasks, state, config, journal records), so they
  round-trip through JSON and YAML unchanged. The one exception is `**fields` in `Night#log`,
  whose keys are converted to strings before they are written.
- **Value objects use `Data.define`**: `Exec::Result`, `Adapters::Run`, `Gates::Result` and
  `Verifier::Verdict`. Give fields defaults with an `initialize`
  override that takes keyword arguments and calls `super`. Add predicate methods (`ok?`,
  `timed_out?`) rather than reading boolean fields directly.
- **Persistent files are written atomically.** `Util.write_json` writes a temp file and then
  renames it over the target. The journal is append-only. Never rewrite `journal.jsonl`.
- Configuration defaults live in exactly one place, `Project::DEFAULTS`. Code reads
  `cfg["gates"]["protect"]` and never re-states a default inline, except through
  `fetch(key, default)` for optional per-task fields.

## 4. Errors

- **`Nightshift::Error`** means a problem the user must fix: bad config, a missing approval,
  or a protected file that changed. `CLI.dispatch` turns it into a `Thor::Error`, so Thor
  prints `ns: <message>` on stderr and exits 1, without a backtrace. Write the message as an
  instruction ("No contract.lock. Review the plan and run `ns approve` first.").
- Subclasses exist where callers need to tell errors apart: `Exec::NotFound` and `Git::Failed`.
- Anything else is a bug and should crash with a backtrace. `Night#run` records the crash as
  the night's stop reason and re-raises it. Do not `rescue StandardError` except around
  best-effort work (health checks, notifications, cleanup hooks), and say so in a comment.
- A failing gate is not an exception. It is a `Gates::Result` with `ok: false`, a `gate`
  name, and a `detail` that the next attempt is shown.

## 5. Processes and the shell

- **Never use a shell to start a program.** Use `Exec.run(argv, ...)`, which passes
  `[exe, exe]` to `Process.spawn` so that no shell is involved, even for one-element argv.
- The only commands that go through a shell are gate commands written by the user. They run
  through `Exec.run_shell(cmd, project.shell)`, where the shell is Git Bash on Windows.
- Every external run has a timeout. When it expires, the whole process tree is killed
  (`taskkill /T /F` on Windows, the process group elsewhere) and the exit code is 124.
- Output goes to files under the attempt's run directory, never to memory. An overnight
  transcript can be megabytes.
- In tmux mode (`Pane`), the agent runs in a pane through `lib/nightshift/pane_runner.rb`, still
  without a shell: `tmux split-window -- ruby pane_runner.rb <spec.json>`, and every value
  (argv, env, cwd) travels in the JSON spec, never on a command line. The runner writes the
  agent's pid and exit code to files, because a pane's exit status is not reliable (psmux), and
  the timeout kill uses that pid. The agent's own screen replaces the stdout file, so the adapter
  must write its final answer to `{out}` (pi saves a session file too).
- `Exec.resolve` finds `.cmd` and `.exe` shims through `PATHEXT`, and App Execution Aliases
  (Store-installed `pwsh`, `winget`), which `File.file?` does not count as files. Always resolve
  before spawning, because `Process.spawn` does not do this on Windows.
- Git goes through the `Git` class (`Open3.capture3("git", "-C", repo, ...)`).

## 6. Trust boundaries (do not weaken these)

- The harness decides. Nothing an agent prints changes control flow. `Adapters.last_claim` is
  for the log only.
- Holdout content never reaches a prompt. The failure note for a holdout failure is the fixed
  `Night::HIDDEN_FAIL_NOTE`.
- Protected files are checked three times: by the pi guard during the session, by
  `Gates.integrity` on the staged diff, and by `contract.lock` hashes in `Night#preflight`.
- The worker's clone has no remotes, and nightshift never pushes or merges. `ns land` only
  prints commands.
- In place (`project.in_place`), the repo is the user's: never reset, clean or commit unless
  it is on `project.branch` with nothing nightshift did not make (`Night#outside_change`). The
  only exception is the leftovers of nightshift's own interrupted attempt. TRADEOFFS.md says
  why the clone stays the default.
- Never mount `~/.ssh`, the Docker socket or the real `~/.pi/agent` into containers.

## 7. Style

- **RuboCop is the style authority.** `bundle exec rake lint` must report no offenses before
  you commit. Its settings are in `.rubocop.yml`, and each setting that differs from the
  default has a comment saying why. Autocorrect with `bundle exec rake lint:fix`, not with
  `rubocop -a` directly: on Windows, RuboCop writes the files it corrects with CRLF.
- Inline `# rubocop:disable` is allowed only with a comment saying why the rule is wrong for
  that line.
- Size limits: methods up to 20 lines and ABC size 25, complexity 10, classes 300 lines. The
  files listed in `.rubocop_todo.yml` already break these limits. That list may only shrink:
  when you touch a long method there, split it, and when a file is clean, regenerate the list
  with `bundle exec rubocop --auto-gen-config --auto-gen-only-exclude --no-auto-gen-timestamp`.
- Two-space indentation, double-quoted strings, lines of at most 120 characters, LF line
  endings (`.gitattributes` enforces LF).
- Every class and module gets a comment saying what it is for and how it fits the loop. Public
  methods get a one-line comment when the name alone does not say what they return.
- Comments explain *why*, not *what*: for example, "Unquoted 07:00 is read by YAML as seconds
  after midnight", not "convert integer to string".
- Use explicit block parameter names (`tasks.each { |task| ... }`) except in trivial one-liners.
- Use keyword arguments when a call has more than two parameters, or when the meaning of a
  value isn't clear from its position (`timeout_s:`, `cwd:`).
- Units go in names: `timeout_s`, `timeout_min`, `down_grace_min`.
- Return early instead of nesting. A guard clause is followed by one blank line.
- Paths that are stored, logged or compared use forward slashes (`Util.norm`). Only
  `File.join` and `File.expand_path` build real paths.

## 8. Testing

- Tests are in `test/` and use minitest. Run them with `bundle exec rake test`, and run
  `bundle exec rake guard` for the pi extension (Node). Plain `rake test` also works, because
  minitest and rake ship with Ruby.
- RuboCop's minitest rules apply to tests too. Put one blank line before the first assertion.
  A test may make at most 6 assertions: if it needs more, it is checking two things, so split it.
- `test/gates_test.rb` holds unit tests for the pure functions, which are fast and have no IO.
  Add a test there for every new gate rule or parser.
- `test/night_test.rb` is the end-to-end self-test. It runs one real night on a toy Ruby repo
  with the fake agent (`adapters/fake_agent.rb`). The night runs once in a memoized fixture,
  and each test asserts one outcome, so the tests do not depend on their order.
- `test/scratch_test.rb` covers the from-scratch path end to end (`init --new`, the planner prompt
  for an empty repo, the missing-tool check, and a run).
- `test/in_place_test.rb` covers `init --in-place` end to end: a night in the user's repo, and
  every refusal that protects the user's files.
- `test/pane_test.rb` covers tmux mode: the pane runner, `pane_cmd` selection, and (when tmux
  is installed, unless `NS_SKIP_TMUX=1`) real panes: exit codes, timeout kill, closed panes.
- `test/exec_test.rb` covers finding programs on PATH, including App Execution Aliases.
- `test/docs_test.rb` checks that `lib/ARCHITECTURE.md` names every file under `lib/` and no
  file that no longer exists.
- `test/cli_test.rb` covers the command line: dispatch, option checks, exit codes, and the
  commands `land` prints. Assert on exit codes, files and the commands a
  plan contains, not on the exact wording or layout of the output.
- Run a command in-process with `TestHelpers.ns("check", state, ...)`. It returns the exit
  status, as the shell would see it.
- **Every new failure mode the harness handles gets a scenario.** Add a task to
  `NightFixture::TASKS` whose `FAKE:` notes reproduce the agent behaviour, then add a test that
  checks the outcome. If the fake agent cannot express the behaviour, add an op to
  `fake_agent.rb` and document it in that file's header.
- Run with warnings on (the Rakefile sets `t.warning = true`), and fix any warning.
- Set `NS_KEEP=1` to keep the self-test's temp folder, which holds the state dir and
  `night.log`, so you can inspect it.

## 9. How to extend

| You want to | Do this |
|---|---|
| Support a new agent CLI, model or LoRA | Add an entry to `adapters/adapters.yml`; no code is needed. Try it on a small plan with `ns run <state> --max-iterations 1`. |
| Let an agent run on screen with `ns run --tmux` | Give its adapter a `pane_cmd` (its interactive command) and, if needed, `pane_env`. The agent must exit by itself when done and write its final answer to `{out}`. Try it with `ns run <state> --tmux --max-iterations 1`. |
| Add a placeholder for adapters | Add it to `Adapters.base_vars`, or to the `extra_vars` passed by `Night#attempt`, and list it in the comment at the top of `adapters.rb` and `adapters.yml`. |
| Add a gate | Write the check in `Gates`, returning a `Gates::Result`, and call it from `Verifier#verify` in cost order: cheap static checks before running commands. Add its config key to `Project::DEFAULTS["gates"]`, and add a unit test plus, if it involves the agent, a night scenario. |
| Add a config setting | Add it to `Project::DEFAULTS` with a comment, document it in `templates/project.yml`, and read it from `cfg`. |
| Change what the worker is told | Edit `templates/prompts/worker.md`, plus `Briefing` if you need a new `{{PLACEHOLDER}}`. A project can override any prompt in `<state>/prompts/`. |
| Add a command | Put the work in a service (a new file in `lib/nightshift/`, required from `lib/nightshift.rb`) that prints through `UI` and raises `Error`. In `CLI`, add `desc "name STATE_DIR", "..."`, a `method_option` for each option (with `type:`, `default:` and `desc:`), and a method of the same name that checks the option values and calls the service. Add a test to `test/cli_test.rb`, an example to README section 2, and the file to `lib/ARCHITECTURE.md`. |
| Change the task format | Update `Plan` (accessors and `problems`), the planner prompt, and the task format in README section 7. |

Whatever you change, update the affected `.md` files in the same change (see `AGENTS.md`).

## 10. Windows notes

- Gate commands use Git Bash (`C:\Program Files\Git\bin\bash.exe`), so `&&`, quoting and
  forward-slash paths behave the same on every OS. A project can choose another shell with
  `gates.shell`.
- Spawned processes get `new_pgroup: true` so that the timeout kill takes their children
  with them.
- Write test files with `mode: "wb"` so they keep LF line endings. Templates and prompts are LF too.
- nightshift does not keep the PC awake. Set the power plan to never sleep for a long run.
- YAML: quote times (`"07:00"`) and the words `"off"`, `"no"` and `"yes"` when you mean strings.
