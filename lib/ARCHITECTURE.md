# How the code fits together

This is the map of `lib/`. Read it before the code: it says what every file does, who calls
whom, where state lives and which rules the code must keep, so you can open only the files a
change touches. README.md says what nightshift does for the user; CONVENTIONS.md says how the
code is written. This file says where things are.

**Keep it current.** When you add, remove, rename or split a file under `lib/`, or change how
the pieces call each other, update this file in the same change. `test/docs_test.rb` fails when
a file under `lib/` is missing here, or when this file names a `.rb` file that no longer exists.

## The big picture

nightshift is an orchestrator: the harness owns the loop, git, the time limits and the decision
that work is done. Agents only edit files. Two phases:

```
attended (evening)      init ─► requirements.md ─► plan ─► check ─► approve ─► doctor
unattended (night)      run:  pick task ─► reset repo ─► agent ─► gates ─► commit or reset ─► repeat
attended (morning)      report / status ─► land (prints git commands; the human merges)
```

The state directory (`<state>/`, see `project.rb`) lives outside the repo the agent edits, so
the agent can never read the hidden tests or rewrite the harness's records.

## Entry points and load order

- `bin/ns` activates the `thor` gem (never `bundler/setup`, which would leak `BUNDLE_GEMFILE`
  into gate commands), requires `lib/nightshift.rb` and calls `Nightshift::CLI.start(ARGV)`.
- `nightshift.rb` requires the stdlib, defines the constants every file may use (`VERSION`,
  `HOME`, `CATALOG`, `PROMPTS`, `WINDOWS`, `Error`) and requires every file in dependency
  order: helpers first, then the domain, then the services, and the CLI last.
- `pane_runner.rb` is the one file that is not required. It is a standalone script that tmux
  runs inside a pane (see "Tmux mode" below).

## Files

Layers, bottom to top. A file only calls files in its own layer or below.

### Helpers (no domain knowledge)

| File | What it does | Main entry points |
|---|---|---|
| `util.rb` | File IO that never leaves half-written files (atomic JSON), UTF-8 safe reads, LF writes, tails of logs, timestamps, path normalising, SHA-256. | `Util.read/write/append/tail`, `read_json/write_json`, `norm`, `now_iso`, `monotonic` |
| `exec.rb` | Runs a program with a hard time limit. On timeout it runs an optional hook, then kills the whole process tree (`taskkill /T /F` on Windows, the process group elsewhere) and returns rc 124. Resolves `pi.cmd`-style shims and App Execution Aliases (Store `pwsh`) on Windows. | `Exec.run`, `run_shell`, `resolve`, `available?`, `kill_tree`; `Exec::Result` |
| `ui.rb` | Everything the commands print: steps, headings, warnings, next steps. Icons and colours in a terminal, plain words in files. | `UI.step/info/warning/heading/next_step` |
| `git.rb` | Git on the repo the agent edits: reset to a commit, stage everything since a base, staged status and patch, commit the index. | `Git#reset_to`, `stage_all_from`, `staged_status`, `staged_patch`, `commit_index`, `tracked` |
| `machine.rb` | Long-run concerns: model server health checks and restarts, and the notifier command. | `Machine.healthy?`, `notify`; `Machine::Server#ensure_up` |
| `prompts.rb` | Loads `templates/prompts/*.md` (a project's `<state>/prompts/` overrides them) and fills `{{NAME}}` placeholders. | `Prompts.build` |

### Domain

| File | What it does | Main entry points |
|---|---|---|
| `project.rb` | One state directory: its paths, its config (`DEFAULTS` deep-merged with `nightshift.yml`), the resolved adapter specs, and loading and saving tasks and state. Almost everything else takes a `Project`. | `Project.new(state_dir)`, `#cfg`, `#repo`, `#adapter(name)`, `#load_tasks`, `#load_state/save_state`, `#*_file` paths |
| `plan.rb` | The task format (`tasks.json`): field accessors and validation (missing or duplicate ids, tasks without checks, unknown dependencies, cycles). | `Plan.problems`, `checks`, `holdout_files`, `depends_on` |
| `adapters.rb` | The only code that knows how an agent is started. Adapters are data (`adapters/adapters.yml` plus `nightshift.yml` overrides); this fills `{placeholders}` and runs the agent headless (`Exec`) or on screen (`Pane`). Returns the exit code and the agent's last DONE/STUCK line. | `Adapters.run_agent`, `run_interactive`, `render`; `Adapters::Run` |
| `gates.rb` | The deterministic checks, as pure functions: integrity (protected files, deleted tests, skip markers), stray paths, running check commands, installing holdout files, the advisory hard-code scan. | `Gates.integrity`, `stray_paths`, `run_commands`, `install_holdout`, `hardcode_scan`; `Gates::Result` |
| `verifier.rb` | Runs the gates on one staged attempt in order, cheapest first: integrity, paths, setup, task checks, holdout, regression, global. It copies holdout tests into the repo only while checks run. | `Verifier#verify` → `Verdict` (result + advisories) |
| `briefing.rb` | Builds the worker prompt for one attempt from `worker.md`: the task, verified file paths (existing or new), the repo layout, the earlier attempts of this task, what earlier tasks added, recent progress. | `Briefing#worker_prompt` |
| `handover.rb` | The warm handoff, as pure functions: the definitions a diff adds (outside test files), the record of a discarded attempt (files, definitions, last answer), and the prompt text for earlier attempts and for what kept tasks added. `Night` records, `Briefing` renders. | `Handover.definitions`, `attempt_record`, `previous_attempts`, `built` |
| `night.rb` | The loop (see "One night" below). Owns `state.json`, `journal.jsonl` and `progress.txt` while it runs. | `Night#run`, `Night.deadline`, `Night.fingerprint` |
| `pane.rb` | Tmux mode: launches `ns run` in a tmux session, opens one pane per attempt, waits for the agent's exit code, kills it on timeout, closes the last pane at the end. | `Pane.open_night`, `host_night`, `Pane#run`, `#close` |
| `pane_runner.rb` | Standalone script run inside a pane: starts the agent from a JSON spec, writes its pid and exit code to files, then lingers so the last screen stays readable. | `ruby pane_runner.rb SPEC.json` |
| `report.rb` | The morning report (`REPORT.md`), `ns status` and `ns land`, built only from what the harness recorded, never from what agents said. | `Report.write`, `#status`, `#land` |

### Services (one per command) and the CLI

| File | Command | What it does |
|---|---|---|
| `setup.rb` | `ns init` | Creates the state dir: a clone of the user's repo with every remote removed (or, `--in-place`, a new branch in the user's repo), `nightshift.yml` and `requirements.md` from `templates/`. `--new` first makes an empty folder a git repo. |
| `planner.rb` | `ns plan` | Writes `planner-prompt.md` (`planner.md`, or `planner-new.md` for an empty repo), runs the planner agent (interactive by default, `--headless` through `Adapters`), then harvests `.nightshift-plan/`: `tasks.json` into the state dir, `holdout/` out of the repo. |
| `checker.rb` | `ns check` | Proves the plan is workable: valid tasks, holdout files exist, every acceptance check fails now (and can run), the global gates pass now. |
| `approval.rb` | `ns approve` | Freezes the contract: commits tasks and tests in the repo, writes `contract.lock` (hashes of protected files), resets blocked tasks. |
| `night.rb` | `ns run` | (see above) |
| `doctor.rb` | `ns doctor` | Preflight before leaving a night alone: repo and branch (never main/master), isolation (no remotes, or the right clean branch in place), contract approved, tasks valid, gate shell and adapter commands found, pi guard present, model server up, and `server.start_cmd`'s program found on PATH. |
| `report.rb` | `ns report/status/land` | (see above) |
| `cli.rb` | all | Thor. Declares commands and options, validates option values, calls one service, turns `Nightshift::Error` into a one-line message and exit 1. No logic beyond that. |

## Who calls whom

```
CLI ──► Setup | Planner | Checker | Approval | Doctor | Report | Night (| Pane for --tmux)
                 │          │                    │                  │
                 ▼          ▼                    ▼                  ▼
              Adapters   Gates               Machine        Briefing, Handover, Adapters, Verifier, Git, Report
                 │                                                     │           │
                 ▼                                                     ▼           ▼
             Exec | Pane ──► (tmux) ──► pane_runner.rb ──► agent     Gates       Exec
everything ──► Project, Plan, Util, UI, Prompts
```

## One night (`Night#run`)

1. **Preflight.** Validate `tasks.json`; require `contract.lock`; bring the repo back to the
   last good commit (`state["head"]`) if an earlier run crashed mid-attempt; check that every
   protected file still matches its hash. In place, refuse to reset anything nightshift did not
   make (`check_in_place`).
2. **Start or resume** the night record (`state["night"]`): id, deadline, counters.
3. **Loop** (`work_until_stopped`) until one of: the `STOP` file, the deadline, the iteration
   cap, the circuit breaker (`max_consecutive_failures`), an in-place repo changed from
   outside, no eligible task, the model server down.
4. **One attempt** (`attempt`), for the first pending task whose dependencies passed:
   - reset the repo to `state["head"]`; make `runs/<tag>/`; write `prompt.md` (`Briefing`);
   - pick the adapter: `roles.worker`, or `roles.escalate` for a task's last attempt
     (`pick_role`, limited by `max_escalations`);
   - mark the attempt in flight (`state["inflight"]`, so a crash is recovered next time);
   - `Adapters.run_agent` with the attempt's time limit (the adapter's `timeout_min` or the
     budget, never past the deadline);
   - stage everything the agent did (`Git#stage_all_from`, which folds the agent's own commits
     back into the index), save `diff.patch`, run `Verifier#verify`;
   - **keep**: commit with the harness's message, move `state["head"]`, mark the task passed,
     record the definitions it added (`ts["added"]`, shown to later tasks);
   - **discard**: reset the repo, record what the attempt did (`ts["tried"]`), write
     `last-failure-<id>.txt` for the next attempt, and block
     the task after `max_attempts` or when the same failure (fingerprinted) repeats with the
     same diff.
5. **Finish**: log the reason, write `REPORT.md`, run the notifier. Exit 0 only if every task
   passed.

## Tmux mode (`ns run --tmux`)

- Outside tmux, `CLI#run_night` calls `Pane.open_night`: it starts the same `ns run ... --tmux`
  command in a new session `ns-<project>` and attaches if there is a terminal.
- Inside that session, `CLI#night` wraps the loop in `Pane.host_night`, which hands a `Pane` to
  `Night` and, at the end, waits for Enter (only with a terminal) and closes the last pane.
- `Adapters.run_agent` uses the pane only if the adapter has `pane_cmd`. `Pane#run` writes
  `<label>.pane.json`, splits a pane running `pane_runner.rb`, and polls for `<label>.rc`. On
  timeout it kills the process tree from `<label>.pid`. A pane closed by hand gives rc 1.
- The agent must exit by itself and write its final answer to `{out}` (`worker.out`), because
  its screen is not captured. For pi the guard does both (`PI_GUARD_FINAL`,
  `PI_GUARD_EXIT_ON_SETTLE`).

## Where state lives

| File (in `<state>/`) | Written by | Read by |
|---|---|---|
| `nightshift.yml`, `requirements.md` | `Setup`, then the human | `Project`, `Planner` |
| `tasks.json`, `holdout/` | `Planner` (harvest), the human | `Plan`, `Checker`, `Night`, `Verifier` |
| `contract.lock` | `Approval` | `Night` preflight (protected file hashes), `Doctor`, `Report` (the base commit) |
| `state.json` (incl. the handoff records `tasks.<id>.tried` and `.added`) | `Night`, `Approval` | `Night`, `Report`, `Briefing` |
| `journal.jsonl`, `progress.txt` | `Night` | `Report`, `Briefing` |
| `last-failure-<id>.txt` | `Night#on_failure` | `Briefing` |
| `runs/<tag>/` | `Night`, `Adapters`, `Pane`, `Gates` | the human, `Night.path_events` (the pi guard's path log) |
| `REPORT.md` | `Report` | the human |
| `STOP` | the human (`ns stop`) | `Night` |
| `repo/` | `Setup`, the agent, `Git` | everything |

## Rules the code relies on

- Nothing an agent says is trusted. DONE/STUCK lines are logged; only the gates decide.
- The harness owns git. It never pushes. A clone has no remotes; in place, nightshift only
  works on its own branch and never discards work it did not make.
- Every external program goes through `Exec` (or `Pane`) with a time limit and a tree kill,
  as an argv array, never a shell string. Only gate commands run through the configured shell.
- Every state file is written atomically (`Util.write_json`); a crash at any point is
  recoverable by the next `ns run`.
- No command prompts, except `ns plan` handing the terminal to the planner and the Enter wait
  at the end of a tmux night.
- Errors the user must fix are `Nightshift::Error`; the CLI prints them without a backtrace.

## Outside `lib/`

- `adapters/adapters.yml` is the adapter catalog; `adapters/pi/unattended-guard.ts` is the pi
  extension that bounds a session (turns, time, paths) and, in tmux mode, saves the final
  answer and quits; `adapters/fake_agent.rb` is a scripted agent for tests.
- `templates/project.yml` and `templates/requirements.md` are copied by `ns init`;
  `templates/prompts/` holds the planner and worker prompts.
- `test/`: `gates_test.rb` (pure gate functions), `night_test.rb` (simulated nights with
  `fake_agent.rb`), `scratch_test.rb` (a project from an empty folder), `in_place_test.rb`,
  `pane_test.rb` (tmux mode), `cli_test.rb` (commands and options), `exec_test.rb` (finding programs), `docs_test.rb` (this file
  covers `lib/`), `guard_test.mjs` (the pi guard, run by `rake guard`).
