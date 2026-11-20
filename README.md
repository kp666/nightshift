# nightshift

Unattended, verified coding with any agent, whenever you ask for it. You write requirements
and review a plan with a strong model while you are at the keyboard. Then you start a run
and walk away, whether that is for the night, for an afternoon, or while you do something
else. A local model works through the plan one small task at a time; by default that is
Qwen3.8-27B-pi-adapted, running through pi. A harness that does not trust the model decides
what is kept. When you come back, you read a report and review real commits on a branch.

The "night" in the name and in the code is simply one unattended run. It has **no time limit
unless you set one**: it ends when the work is done or a safety stop trips (section 4, item 7).
The diagram below shows the overnight case.

```
 evening (attended)              night (unattended)                              morning
 ───────────────────             ──────────────────────────────────────────      ───────────
 requirements.md                 ┌─► pick next task (deps, status)               REPORT.md
   │ ns plan (cloud model)       │   reset repo to last good commit              ns land
   ▼                             │   fresh agent session (adapter)  ◄─ prompt:   (git fetch +
 tasks.json + acceptance tests   │   stage the diff                    task +     review;
 + hidden holdout tests          │   gates: integrity → paths → task   last       nothing is
   │ ns check (all must fail)    │          checks → holdout →         failure    merged for
   │ ns approve (lock + commit)  │          regression → global        note       you)
   ▼                             │
 ns run  ────────────────────────┘   pass: harness commits   fail: reset, fingerprint,
                                     failure note, maybe block / escalate
```

It is written in Ruby 4.0. Running it needs one gem, [Thor](https://github.com/rails/thor), for
the command line; developing it uses a few more (see [Dependencies](#dependencies)).
It was built for Windows first and also runs on Linux and macOS. How the code is organised and
the style it follows are described in [CONVENTIONS.md](CONVENTIONS.md). The choices that cost
something, such as why the worker gets its own clone of your repo and when to let it work in
your repo instead (`--in-place`), are explained in [TRADEOFFS.md](TRADEOFFS.md).

---

## 1. Install

nightshift needs Ruby 4.0 or newer, git and Git Bash. Node 22.6+ is needed only for the pi
guard's own test.

On Windows, install Ruby with RubyInstaller and let it add Ruby's `bin` folder to your PATH.
Open a **new** terminal so the PATH change takes effect, then check:

```powershell
ruby --version            # ruby 4.0.x ...
```

Install the one gem nightshift needs to run:

```powershell
gem install thor -v "~> 1.5"
```

Put nightshift on your PATH so that `ns` works from any folder. `ns.cmd` runs `bin/ns` with
whichever `ruby` is on the PATH. Replace `C:\path\to\nightshift` with the folder you cloned it to:

```powershell
# for this terminal only:
$env:PATH += ";C:\path\to\nightshift"
# permanently (new terminals):
[Environment]::SetEnvironmentVariable("PATH", $env:PATH + ";C:\path\to\nightshift", "User")

ns --version              # nightshift 0.2.0 (ruby 4.0.x)
```

Without changing the PATH, run `ruby C:\path\to\nightshift\bin\ns ...`.

Check the install by running the self-test from the nightshift folder. It takes about a minute.

```powershell
rake test                 # 38 tests: gate unit tests, the CLI, a simulated night, a project from scratch
rake guard                # 13 checks of the pi guard extension (Node)
```

### Dependencies

**Running nightshift needs one gem: Thor (`~> 1.5`), for the `ns` command line.** Everything
else is Ruby's standard library (`json`, `yaml`, `open3`, `net/http`, ...). A harness
that runs unattended overnight should have as few moving parts as possible, so:

- Thor is pure Ruby, so running nightshift needs no compiler, and Thor has no dependencies of
  its own;
- the version is pinned to `~> 1.5`, so a gem update cannot change the command line between
  one night and the next;
- `bin/ns` activates Thor with `gem "thor"` and does **not** load `bundler/setup`. Bundler would
  export `BUNDLE_GEMFILE` and `RUBYOPT` to every gate command, which breaks `bundle exec` in a
  Ruby project that nightshift works on;
- a script or scheduled task just runs `ruby bin/ns run ...`. If Thor is missing, `ns` says how to
  install it.

**Developing nightshift uses the [Gemfile](Gemfile).** Besides Thor, its gems are minitest,
rake, and RuboCop with its minitest and rake plugins, all in the `:development, :test` group,
and `Gemfile.lock` pins their versions.

`bundle install` needs a C compiler, because RuboCop depends on `json`, and Bundler 4 replaces
Ruby's built-in `json` with the gem from rubygems.org, which is compiled on install. On Windows
that compiler is RubyInstaller's MSYS2 devkit. Without it, `bundle install` stops with "An
error occurred while installing json". Install the devkit once:

```powershell
ridk install 1 3          # MSYS2 base + the MINGW gcc toolchain
bundle install            # once
```

```powershell
bundle exec rake          # tests (the default task)
bundle exec rake lint     # RuboCop; must report no offenses
bundle exec rake lint:fix # RuboCop's safe autocorrect, keeping LF line endings
bundle exec rake guard    # the pi guard's tests
```

`.rubocop.yml` holds the style rules and explains each one that differs from RuboCop's
defaults. `.rubocop_todo.yml` lists the files that still have methods over the size limits.
That list is known debt, so shrink it rather than add to it (see
[CONVENTIONS.md](CONVENTIONS.md#7-style)).

## 2. Quick start

```powershell
# The project must be committed: nightshift works on a clone of committed state.
ns init C:\nightshift\myproj --source C:\path\to\repo
#   huge repo? add --in-place to work on a new branch in the repo itself, with no clone
#   (read TRADEOFFS.md first: you must leave that folder alone while a run is going)
notepad C:\nightshift\myproj\nightshift.yml         # checks, protected paths, roles
notepad C:\nightshift\myproj\requirements.md

ns plan    C:\nightshift\myproj      # an interactive Claude Code session writes tasks + tests with you
ns check   C:\nightshift\myproj      # validates the plan; every acceptance check must FAIL now
ns approve C:\nightshift\myproj      # commits the contract, hashes protected files
ns doctor  C:\nightshift\myproj      # preflight: config, adapters, model server, git, contract

# start it now and walk away; it stops when the work is done (or a safety stop trips)
ns run C:\nightshift\myproj
#   with a limit:  ns run C:\nightshift\myproj --hours 3      (or --until 18:00)
#   overnight:     ns run C:\nightshift\myproj --until 07:00
#   (nightshift does not keep the PC awake: set Windows to never sleep while plugged in,
#    e.g. `powercfg /change standby-timeout-ac 0`, or start ns run from Task Scheduler yourself)

# when you are back
ns report C:\nightshift\myproj
ns land   C:\nightshift\myproj       # prints the git fetch / log / diff / merge commands
```

Other commands:
- `ns stop <state>` stops the run after the current attempt. You can also press Ctrl+C in its
  window; the next `ns run` recovers cleanly.
- `ns status <state>` shows progress at any time.
- `ns help` lists the commands, and `ns help <command>` (or `ns <command> --help`) lists a
  command's options. Boolean options also have a `--no-` form, e.g. `ns check <state> --no-run`
  for the static checks only, and `ns run <state> --no-limit` to ignore any time limit in
  `nightshift.yml`.
- Each step prints one line marked ✔ or ✘ in a terminal, and `ok` or `FAIL` when the output goes
  to a file (such as `night.log`), so logs stay greppable. `NO_COLOR=1` turns colours off.
  Errors are one line on stderr starting with `ns:`, and a failed command exits 1.
- No command ever prompts, so every command works from scripts and the Task Scheduler.

To use a different planner, run `ns plan <state> --print-prompt`. It prints the planner prompt,
which you can give to any chat or agent working in the clone (or in your repo, in place).
Afterwards, collect the result with `ns plan <state> --harvest`.

### Starting a project from scratch

```powershell
ns init C:\nightshift\myapp --source C:\code\myapp --new   # creates C:\code\myapp as a new git repo
notepad C:\nightshift\myapp\requirements.md                # what you want built, in plain words
ns plan C:\nightshift\myapp                                # see below
ns check / ns approve / ns run                             # as usual
```

The worker can't install packages or reach the network, and a 27B model does far better filling
in a structure than inventing one. So when the repo is empty, `ns plan` tells the planner
(Claude Code, working with you) to build the **skeleton** first:
- agree on the stack;
- install every dependency the plan will need;
- set up the test runner with one passing test;
- create the folder layout and `AGENTS.md`;
- tell you which `project.bootstrap` and `gates.global` lines to add to `nightshift.yml`.

Only after that does it plan the features as small tasks on top of the skeleton. `ns check`
rejects any check whose tool is not installed ("command not found"), so a missing test runner
is caught at the keyboard, not after a wasted night. `ns approve` commits the skeleton together
with the contract.

What to expect: a small model does well on many small, well-specified tasks on top of a good
skeleton. Architecture, the choice of libraries and UI design should stay with you and the
planner. If tasks keep getting blocked, they are too big; split them and run again.

For the astro project, start from `examples/astro/nightshift.yml` and `examples/astro/requirements.md`.
The comments at the top of the YAML file list what to commit before running `ns init`.

## 3. Research synthesis

The aim was to keep what works in each approach and avoid its known failures.

### Karpathy's autoresearch ([repo](https://github.com/karpathy/autoresearch), [program.md](https://raw.githubusercontent.com/karpathy/autoresearch/master/program.md))

How it works:
- There are three files. `prepare.py` is locked. `train.py` is the only file the agent may edit. `program.md` holds the instructions the human writes ("you are programming the research org, not the code").
- Each experiment has a fixed 5-minute budget, and there is one scalar metric.
- The loop commits, runs, keeps the change if it improved, and otherwise runs `git reset`.
- The instructions say "NEVER STOP".
- People report around 100 experiments a night, for example 89 runs in 7.5 h with 15 kept ([paddo.dev](https://paddo.dev/blog/autoresearch-overnight-lab/), [hackernoon](https://hackernoon.com/i-let-karpathys-autoresearch-agent-run-overnight)).

Adopted from it:
- a locked evaluator;
- a small surface the agent may edit;
- a fixed time budget per attempt;
- git keep/reset;
- a human-written program, which here is `requirements.md` plus the approved plan.

Avoided:
- **The agent owning the loop.** Agents ignore "NEVER STOP", miscount iterations, and prompt-only guardrails go unenforced ([comparison](https://suzuke.github.io/blog/posts/autoresearch-tools-compared/)). Here the Ruby orchestrator owns the loop, the timers, git and the keep/discard decision.

Karpathy's "keep the AI on a leash" and his autonomy slider ([field guide](https://www.youonai.ai/fieldguide/med/autonomy_slider.html)) shaped where the slider sits. You decide the scope and the checks, and the night only executes them.

### The Ralph loop ([ghuntley](https://ghuntley.com/ralph/), [snarktank/ralph](https://github.com/snarktank/ralph))

Each iteration is a fresh session with one task, and state lives in files rather than in the context window.
- **Adopted:** each attempt is a new agent process (`pi -p --no-session`). The prompt prefix stays stable, which keeps the llama.cpp prompt cache useful ([why](https://www.vincentschmalbach.com/why-llamacpp-reprocesses-the-whole-prompt-after-every-tool-call-and-how-to-keep-the-kv-cache-warm/)). Memory between attempts is a short failure note plus `progress.txt`, both written by the harness.
- **Avoided:** letting the agent decide it is done. Its `DONE` line is only logged.

### harnex ([repo](https://github.com/jikkuatwork/harnex))

harnex has per-agent adapters and builds a receipt from the git state it observes, never from the worker's claims.
- **Adopted:** adapters, and proof built from what the harness observed. Exit code 124 means a timeout.
- **Not adopted:** driving agents through tmux/PTY, which has no Windows support. Here, adapters are data rather than code.

### pi-durable ([post](https://earendil.com/posts/pi-durable/))

pi-durable makes tasks durable, so they resume after a crash.
- **Adopted, at small scale:**
  - `state.json` is written atomically;
  - `journal.jsonl` is append-only;
  - an `inflight` marker records the running attempt;
  - after a crash or reboot, `ns run` resets the repo to the last good commit and continues the same night.

### dev-loops ([package](https://pi.dev/packages/dev-loops))

Its principle is "deterministic gates and a judge decide".
- **Adopted:** deterministic gates.
- **Not adopted:** the LLM judge (the gates and hidden holdouts decide, and you review the diffs), and the dependency on GitHub. nightshift runs locally and never pushes.

### TokenEconomizer ([repo](https://github.com/microsoft/TokenEconomizer))

It has a loop-guard and stuck detection.
- **Adopted:** failure fingerprints, plus the pi guard's check for streaks of identical tool calls. AGENTS.md holds durable facts about the repo.

### Anthropic's harness posts ([long-running apps](https://www.anthropic.com/engineering/harness-design-long-running-apps), [effective harnesses](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents))

They split the work into a planner, a generator and a skeptical separate evaluator, with context resets.
- **Adopted:** the roles `planner`, `worker` and `escalate`, each of which can be a different adapter and model; the evaluator is the harness's own gates. The context is reset on every attempt.

### Reward hacking ([ImpossibleBench](https://www.lesswrong.com/posts/qJYMbrabcQqCZ7iqm/impossiblebench-measuring-reward-hacking-in-llm-coding-1), [answer-key article](https://dev.to/syncsoftai/your-coding-agent-isnt-solving-the-bug-its-finding-the-answer-key-22if), [case study](https://github.com/seahop/ai-threat-atlas/blob/main/docs/case_studies/claude-37-reward-hacking-coding.md))

Agents edit tests, delete them, skip them, or special-case the expected outputs. Each tactic has a defence:

| Tactic | Defence |
|---|---|
| Editing tests or config | Two layers block it: the pi guard during the session, and the integrity gate on the diff afterwards. `contract.lock` hashes are checked before each night. |
| Deleting tests, adding `skip`, `.only`, `xit` or `xfail` | The integrity gate |
| Hard-coding expected values | Hidden holdout tests with different inputs. They are kept outside the repo and copied in only during verification, and their content never reaches the prompt. An advisory literal scan also runs. |
| "Done, all tests pass" when they don't | Claims are ignored, because the harness runs the checks itself |
| Committing, pushing, resetting | The worker's commits are folded back into the harness's diff. The clone has no remotes, and the guard blocks git. In place your remotes stay (see [TRADEOFFS.md](TRADEOFFS.md)). |
| Hanging or looping | A hard timeout kills the whole process tree (exit 124). The guard also enforces turn and time budgets and identical-call limits. |

### Other orchestrators

Write-ups on verification layers ([Opslane](https://dev.to/0xgosu/agents-that-run-while-you-sleep-the-verification-layer-autonomous-coding-needed-543d)) agree that the overnight bottleneck is verification, not generation. "Don't build multi-agents" ([Cognition](https://cognition.com/blog/dont-build-multi-agents)) is the reason there is one worker at a time. And because local models are not Opus ([Alex Ellis](https://blog.alexellis.io/local-ai-is-not-opus/)), tasks are sized for a 27B model, and the harness escalates instead of retrying forever.

## 4. Design decisions

1. **The orchestrator owns everything that matters:** the loop, time, git, verification, the keep/discard decision and stopping. The model only edits files.
2. **The contract is made while you are awake.** A strong planner turns requirements into tasks plus acceptance tests, and you review them. `ns check` proves that every check currently fails. `ns approve` freezes the contract.
3. **Small tasks for a small model.** Aim for about 8 agent turns, 1–2 files, and a check that runs in under 2 minutes.
4. **One fresh session per attempt.** The repo is reset to the last good commit first. The next attempt sees a distilled failure note, not the previous transcript.
5. **Fail fast and move on.** A task is blocked after `max_attempts`, or after the same failure appears twice with the same diff. The other tasks continue, and tasks that depend on the blocked one wait.
6. **Escalate instead of looping.** If `roles.escalate` is set, a task's last attempt uses that adapter, up to `max_escalations` per night.
7. **The harness decides when to stop, not the agent.** A run ends when any of these happens:
   - every task is done, or none is eligible;
   - the time limit passes, if you set one (`--until`, `--hours`, or `budgets.until`/`hours`);
   - the iteration cap is reached (`max_iterations`, default 60 attempts; `--max-iterations N` per run);
   - the circuit breaker trips;
   - the model server is down and can't be revived;
   - a STOP file appears.
8. **Durable.** State is written atomically, the journal is append-only, and the harness recovers from crashes. The model server is health-checked before each attempt and restarted through `server.start_cmd`.
9. **Agnostic by data.** Agents are YAML entries in `adapters/adapters.yml`, and roles map to adapters per project. Prompts are templates that a project can override. Gates are shell commands in any language.
10. **Nothing reaches your real repo automatically.** The worker edits `<state>/repo`, a clone with its remotes removed, on its own branch. `ns land` prints the merge commands, and you run them yourself. With `ns init --in-place` the worker edits your repo on its own branch instead, and nightshift refuses to start, or stops, rather than discard anything it did not make. [TRADEOFFS.md](TRADEOFFS.md) explains why the clone is the default.

## 5. Configuration (`nightshift.yml`)

`ns init` writes a commented `nightshift.yml` from `templates/project.yml`. Anything you leave
out takes the default from `Project::DEFAULTS` in `lib/nightshift/project.rb`. The defaults
file is the full list of settings.

| Section | Key settings |
|---|---|
| `project` | `source`, `repo` (where the worker edits: `repo`, the clone, by default), `in_place` (set by `ns init --in-place`), `branch`, `bootstrap` (run by `ns check`), `acceptance_dir`, `holdout_dir` |
| `roles` | `worker`, `escalate`, `planner` (each is an adapter name; `""` turns that role off) |
| `budgets` | `until` (`"HH:MM"`) or `hours` (both empty/0 by default = no time limit), `max_iterations`, `attempt_timeout_min`, `max_attempts`, `max_consecutive_failures`, `max_escalations` |
| `gates` | `setup`, `global` (commands), `protect` (folders ending in `/`, or globs), `test_paths`, `allow_new_dirs`, `shell` |
| `server` | `health_url`, `start_cmd`, `down_grace_min` |
| `notify` | `cmd`, with `{title}` and `{body}` placeholders |
| `adapters` | per-project overrides of catalog entries, for example `pi-local: {timeout_min: 60}` |

**Quote times:** write `until: "07:00"`. Unquoted, YAML reads `07:00` as a number of seconds.
nightshift converts that number back to a time, but quoting avoids the surprise. Likewise,
quote `"off"`, `"no"` and `"yes"` wherever you mean the string, because YAML reads them as
booleans.

Gate commands run in the repo through Git Bash on Windows, so they look the same on every OS.

## 6. Adapters (making it work with future agents)

An adapter tells nightshift how to start an agent headlessly. This is the default worker:

```yaml
adapters:
  pi-local:
    cmd: [pi, -p, --no-session, --offline, --model, llama-cpp/qwen3.8-pi, --thinking, "off",
          --tools, "read,bash,edit,write", --no-extensions, -e, "{home}/adapters/pi/unattended-guard.ts",
          --no-skills, --no-prompt-templates, --no-mcp, --no-approve, "@{prompt_file}", "{message}"]
    prompt_via: file           # or stdin, or arg with {prompt}
    requires_server: true
    timeout_min: 75
    env:
      PI_GUARD: "1"
      PI_GUARD_ROOT: "{repo}"
      PI_GUARD_PROTECT: "{protect_csv}"
      # ...
```

Placeholders:

| Placeholder | Value |
|---|---|
| `{repo}`, `{run_dir}`, `{state}`, `{home}` | Paths: the repo the worker edits (the clone, or yours in place), the attempt's run folder, the state dir, the nightshift folder |
| `{prompt_file}`, `{prompt}`, `{message}` | The prompt file path, its text, and a one-line instruction |
| `{ruby}` | The Ruby that runs nightshift |
| `{container}` | A unique name for Docker |
| `{protect_csv}`, `{guard_minutes}`, `{max_turns}` | Limits for the pi guard |

Catalog:

| Adapter | Use |
|---|---|
| `pi-local` | Default worker |
| `pi-local-docker` | Same worker with no internet (see below) |
| `pi-openrouter` | A cloud model through pi |
| `claude-code` | Planner or escalation |
| `opencode-local` | Worker through opencode |
| `codex` | Unverified |
| `fake` | Deterministic agent for tests and dry runs (`adapters/fake_agent.rb`) |

**New LoRA or model:** copy `pi-local` under a new name, change `--model`, and set `roles.worker` to the new name.

**New agent CLI:** add an entry with its headless command. It only has to accept a prompt, edit
files in its working directory and exit. Then try it on a small plan with `ns run <state> --max-iterations 1`.

### The pi guard (`adapters/pi/unattended-guard.ts`)

The guard is loaded with `-e`, because pi ignores project-local extensions in headless mode.
It is active only when `PI_GUARD=1`. It enforces:
- a turn budget and a wall-clock budget;
- a stop after 3 identical tool calls in a row;
- a forced timeout on bash commands;
- blocks on network, git, install, recursive-delete and kill commands;
- write protection outside the repo and on protected paths.

It complements the gates rather than replacing them.

### Wrong paths (a known weakness of local models)

Qwen through pi sometimes garbles paths. For example, it may glue a mangled project folder on
the front (`k Kerala-astro-…/src/lib/x.ts`), use an absolute path into another checkout, get
the case wrong, add a stray space, or drop a leading folder. Recovery happens in four layers:

| Layer | When | What it does |
|---|---|---|
| Prompt | before the session | Says the working directory is the repo root. Lists each task file as `(exists)` or `(new file)`, and corrects planner mistakes, e.g. `` `src/calc.rb` (exists; the plan said `calc.rb`) ``. Shows the top-level layout and the files beside the task files. |
| Guard repair | during the session | Rewrites `read`/`edit`/`write` paths to the file that exists. It tries the longest existing suffix, then a case-insensitive match, then a unique basename. It tells the model what it changed, and suggests names for misses it can't fix. The session ends early after 8 misses. Repaired paths are still checked against the protected paths. |
| `paths` gate | after the session | Rejects files created under a top-level folder that didn't exist before, for example `toy/src/tri.rb`, with "did you mean 'src/tri.rb'?". To allow a new folder, list it in `gates.allow_new_dirs`; to turn the gate off, set `gates.stray_paths: false`. |
| Next attempt | retry | The failure note lists the path mistakes from `guard.jsonl`, e.g. "you used X; the correct path is Y". The counts are recorded as `path_fixed` and `path_missed`. |

To use only the path repair in interactive pi:
`$env:PI_PATHFIX = "1"; pi -e C:\path\to\nightshift\adapters\pi\unattended-guard.ts`.
Start pi in the project folder, not its parent.

### Isolation levels

- **Native (`pi-local`):** the guard, a dedicated clone (or your repo with `--in-place`), and the gates.
- **Docker (`pi-local-docker`):** no internet. The container is on an `--internal` network whose only way out is a socat forwarder to llama-server. Only the repo is mounted. Never mount `~/.ssh`, the Docker socket, or your real `~/.pi/agent`, which holds API keys. The adapter expects the `pi-sandbox:1.5.2` image, the `pi-net` network and the forwarder to exist already; setting them up is not part of this repo.

## 7. Task format (`tasks.json`)

```json
{"tasks": [
  {"id": "T01", "title": "...", "description": "self-contained spec",
   "files": ["src/lib/x.ts"], "checks": ["npx vitest run spec/test/acceptance/t01.test.ts"],
   "holdout": {"files": ["spec/test/holdout/t01.test.ts"], "checks": ["npx vitest run spec/test/holdout/t01.test.ts"]},
   "dependsOn": [], "notes": "hints", "maxAttempts": 3, "maxTurns": 50}
]}
```

- Every task needs at least one check command.
- Hidden holdout files live in `<state>/holdout/<same relative path>`.

## 8. The state directory

```
<state>/nightshift.yml    config               <state>/journal.jsonl   every event
<state>/requirements.md   your intent          <state>/progress.txt    one line per attempt (fed to prompts)
<state>/tasks.json        the plan             <state>/runs/<tag>/     prompt, transcript, diff, gate logs, guard log
<state>/holdout/          hidden tests         <state>/REPORT.md       morning report
<state>/contract.lock     protected hashes     <state>/STOP            create to stop
<state>/state.json        progress (harness)   <state>/repo/           the clone the worker edits (none in place)
<state>/prompts/          optional prompt overrides (same file names as templates/prompts/)
```

The state directory is outside the repo, so the worker never sees the tasks, the holdouts or
the journal.

## 9. Morning workflow

1. Run `ns report <state>`. Read "Review these first" before anything else: it lists possible hard-coding.
2. Read the diffs (`ns land` prints the commands). Each commit is one task, so you can cherry-pick.
3. Each blocked task in the report comes with its last failure note. Usually the fix is one of these:
   - rewrite an ambiguous description;
   - split a task that is too big;
   - fix a wrong test.

   Then run `ns approve` again. This re-locks the contract and puts blocked tasks back to pending.
4. Start another run.

## 10. What has been tested

**Tested (Ruby 4.0.9):**
- `rake test` runs 46 tests and they all pass, and `rake lint` reports no offenses.
  - The gate unit tests cover path matching, integrity, stray paths, the hard-code scan, plan validation, fingerprints, deadlines, YAML times and placeholders.
  - A full simulated night with the fake agent covers these scenarios:
    1. an honest pass;
    2. a pass on the 2nd attempt, with the failure note in the prompt;
    3. a tampered protected test is rejected;
    4. hard-coding is caught only by the hidden holdout, and the holdout's content does not leak;
    5. a hang is killed at the timeout;
    6. the agent's own commit is folded in and its false DONE is ignored;
    7. a regression blocks the task and earlier work stays intact;
    8. a skip marker is rejected;
    9. a task that depends on a blocked one waits;
    10. a wrong path is rejected and the retry passes with the corrected path in its prompt;
    11. crash recovery and the STOP file work.
  - A project from scratch: `init --new` creates the repo, the planner prompt asks for a skeleton, `ns check` rejects a check whose tool is missing, and then a run builds three dependent features on an empty repo (one commit per task).
  - In place (`init --in-place`), on a repo with a remote and an ignored `.env`: the branch is created in the repo itself, a night commits there and leaves `main` alone, the `.env` survives the reset after a failed attempt, `ns run` refuses to start when the repo has a file it did not make (and the file is kept) or is on another branch, `ns init` refuses a dirty repo or a state dir inside the repo, `doctor` passes with the remote present, and `land` prints no fetch.
  - The command line: `--version` and `help`, unknown options and missing arguments fail with exit 1, errors are one line on stderr, bad `--until`/`--hours` values are rejected before any work, `init` refuses an existing state dir, `land` prints the right commands, and `stop` writes the STOP file.
- `rake guard` runs 13 checks of the pi guard's path repair, and they all pass.
- `init`, `plan --print-prompt`, `check --no-run`, `doctor`, `status` and `land` were run by hand.

**Not tested yet:**
- a real night with the local model (start with `ns run <state> --max-iterations 1` and llama-server up);
- escalation to a real cloud adapter;
- the Docker adapter, `codex` and `opencode-local`;
- the in-place stop between attempts when the repo changes mid-run (it uses the same check as `ns run`'s refusal, which is tested).

## 11. Layout

```
nightshift/
  bin/ns, ns.cmd                   entry points (ns.cmd is for cmd/PowerShell on Windows)
  lib/nightshift.rb                loads everything; VERSION, HOME, Error
  lib/nightshift/
    cli.rb        the ns commands (Thor)     ui.rb         what the commands print (✔/✘, ok/FAIL)
    setup.rb      ns init                    planner.rb    ns plan: prompt, planner run, harvest
    checker.rb    ns check                   approval.rb   ns approve: commit + contract.lock
    doctor.rb     ns doctor                  night.rb      the night loop (one attempt at a time)
    verifier.rb   runs the gates on a diff   briefing.rb   builds the worker prompt
    report.rb     REPORT.md, ns status, ns land
    gates.rb      the gates themselves       util.rb       files, JSON, hashes
    plan.rb       tasks.json validation      project.rb    config, defaults, state files
    adapters.rb   launching agents           exec.rb       processes, timeouts, tree kill
    git.rb        git                        machine.rb    model server watchdog, notify
    prompts.rb    prompt templates
  adapters/adapters.yml            agent catalog (data)
  adapters/pi/unattended-guard.ts  pi extension
  adapters/fake_agent.rb           deterministic agent for tests
  templates/                       project.yml, requirements.md, prompts/{worker,planner,planner-new}.md
  examples/astro/                  config + requirements for kerala-astro v3
  test/                            minitest suites + the guard test (Node)
  Rakefile                         rake test, rake lint, rake guard
  Gemfile, Gemfile.lock            thor (runtime); minitest, rake, rubocop (development)
  .rubocop.yml, .rubocop_todo.yml  lint rules; known size debt
  TRADEOFFS.md                     design trade-offs: clone vs. in place, and why the clone is the default
  AGENTS.md, CLAUDE.md             rules for coding agents that change nightshift (CLAUDE.md imports AGENTS.md)
  .claude/                         Claude Code hook: reminds the agent to update the docs with the code
```
