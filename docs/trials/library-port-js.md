# Trial: porting a Python library to JavaScript

Two real nights of nightshift on the same job: port the core of a Python astronomy and calendar
library (called *the reference* below) to JavaScript (Node 22, ES modules), with results that
match the reference's for the same inputs (a date, a time, a place and a time zone).

- **Planner (attended):** Claude Code. It wrote the requirements, fixtures, skeleton, tests and
  tasks, standing in for the human with the human watching.
- **Worker (unattended):** pi with a local ~27B model (`pi-local`), one fresh session per task.
- **Oracle:** the reference itself, read-only, used only to generate golden values.

| | Trial 1 | Trial 2 (fresh rerun) |
|---|---|---|
| Tasks | 13 | 14 (T08 split in two) |
| Tasks passed | 7, all on the 1st attempt | **14, all on the 1st attempt** |
| Attempts thrown away | 5 (none by a gate) | 0 |
| Starts of `ns run` | 6: 3 by the planner (one a resume), 3 by the human | 1, no restarts |
| Agent time | 41 min for T01–T07 | 81 min for all 14 tasks (82 min wall clock) |
| Worker tool calls | n/a | 64 in total (3 to 9 per task) |
| Guard blocks / path repairs | 0 / 0 | 0 / 0 |
| Final check (outside the harness) | n/a | 803 tests: unit, acceptance and holdout, all pass; then 800 fresh cases, all match the reference |
| Run mode | headless, started from the planner's background shell | `ns run --tmux` |

In short, the plan was right both times, and the worker passed every task it was given on the first attempt.
Trial 1 failed in the plumbing around the night (process kills, a down model server, a PATH lookup bug), not in the plan.
Trial 2 fixed the plumbing and finished in one go. The big caveat is in [Was the plan correct?](#was-the-plan-correct):
the task descriptions were close to code, so the trial shows the worker can transcribe and integrate
reliably. It does not show that the worker can port a library by itself.

## The slice

| Must have | Tasks (trial 2) |
|---|---|
| Julian day from a local date and time, and back to a date; the sidereal offset | T01, T02 |
| Sidereal longitudes of the Sun, Moon, planets and lunar nodes | T02 |
| Lunar-mansion index + quarter, sign and degrees in a divisional chart | T03 |
| Body positions for a case (two divisional charts) and the ascendant | T04, T05 |
| Weekday and sunrise | T06, T07 |
| Lunar calendar at the given moment: lunar day, half lunar day, Sun+Moon index, the Moon's mansion | T08 (body speed), T09–T12 |
| Planetary period table: main + sub periods, balance at the start | T13, T14 |

Out of scope: end times found by inverse Lagrange interpolation, other period systems, other
divisional-chart methods, the UI, languages, place lookup. The one Must-not was a choice only the
human can make: *don't "fix" the reference; where its results look odd (rounding, truncation, its
own formulas), match them.*

## Steps followed

1. **Init.** Run `ns init <state> --source <new repo> --new --name port-js --branch nightshift/port`, in
   clone mode. Then edit `nightshift.yml`: `max_iterations`, `attempt_timeout_min: 90`,
   `server.start_cmd` (the script that starts the model server), and a project override
   `adapters: {pi-local: {timeout_min: 90}}`. The catalog's `timeout_min: 75` for pi-local wins
   over `budgets.attempt_timeout_min`, so the budget alone did not raise the limit.
2. **Requirements.** Fill in `requirements.md` (Goal, Must have, Must not, How to verify, Out of scope).
   In trial 2 the planner asked the human for the scope first (see the prompt changes below).
3. **Planner prompt.** Run `ns plan <state> --print-prompt`, which writes `planner-prompt.md` with the
   from-scratch section, and the planner follows it in the repo:
   - **Oracle and fixtures.** A Python generator under `tools/oracle/` calls the reference for random
     cases (1900–2099, latitude −45..60, 15 time zones including −3.5, +5.75 and +9.5) and writes
     `tests/fixtures/cases.json`, 30 cases, one case per line. The holdout uses another seed
     and 12 cases.
   - **Skeleton.** `package.json` with `type: module` and `sweph` pinned to the same Swiss Ephemeris
     version the reference uses, plus the lockfile, `ephe/` (two ephemeris files) and `src/swe.js` (the
     ephemeris path, the sidereal mode, the reference's calculation flags). It also has five empty
     feature modules, `src/index.js`, and a unit test that passes.
   - **Acceptance tests.** One shared `tests/acceptance/cases.js` (one function per task) and a
     `tNN.test.js` per task; the holdout `tNN.test.js` files reuse `cases.js` on the hidden cases.
   - **Proof.** A throwaway reference implementation in a scratch copy, never in the repo. With
     it, every visible and holdout check passes; with the empty skeleton, every check fails.
   - **Tasks.** Write `tasks.json` with exact formulas, library calls and argument orders, and
     the reference's integer and rounding behaviour.
   - **Config last.** Set `project.bootstrap: npm ci`,
     `gates.global: node --test "tests/unit/*.test.js"`, and `gates.protect` for the tests,
     fixtures, `ephe/`, `tools/`, `src/swe.js`, the manifest and the lockfile. Run each
     command first and see it pass.
4. **Harvest and check.** Run `ns plan <state> --harvest`, which moves the holdout out of the repo. Then
   `ns check <state>`: every check exits 1 on the skeleton (28 in trial 2, in 11 s) and the global gate passes.
5. **Approve.** Run `ns approve <state>`, which commits the contract and locks 24 protected files in
   trial 2, then `ns doctor <state>`.
6. **Night.** Run `ns run <state> --tmux`. Started from a script, it starts the tmux session
   `ns-port-js`, prints `tmux attach -t ns-port-js` and returns. Pane 0 shows the harness and
   pane 1 the pi session of the current attempt.
7. **Morning.** Read `ns status`, `REPORT.md` and `git log -p`. Then run every test with the
   holdout copied in, in a separate clone.

## Trial 1: what happened

| Time | Event |
|---|---|
| 05:08 | Night 1 started, as a background shell of the planner's Claude Code session. |
| ~05:50 | Claude Code killed that shell because the machine was low on memory. The model server survived. T01's correct edit was left uncommitted, and the next `ns run` discarded it as interrupted (as designed). |
| 06:56 | Resumed. T01 was interrupted again the same way. |
| 08:44 | Night 2. T01–T07 passed, each on the 1st attempt (5.0, 6.4, 7.8, 6.4, 5.8, 3.5, 6.0 min). |
| 09:25 | T08 "bodySpeed and lunar day" (two functions in two files) started. By 09:37, after 3 turns, the worker had printed `DONE … all t08 and unit tests pass`, but no exit code and no gate output were ever written: the harness stopped between pi's answer and the gates. The cause was not captured, and the machine was low on memory at the time. |
| 10:11:00 | The human started a night: model server down (connection refused). |
| 10:11:12 | The human started again; interrupted. |
| 10:15:17 | The human started again. The harness found the server down and ran `server.start_cmd`, then crashed: `executable not found on PATH: pwsh`. |

Trial 1 never restarted pi because pi failed. Each attempt is a fresh pi session by design, and pi
exited normally every time it got to finish. What had to be restarted was the harness: twice because the shell
that owned it was killed, once for an unexplained stop after pi answered, and three times on the
human's side (a down server, an interrupt, the `pwsh` crash).

## Trial 2: what happened

Trial 2 started fresh: a new state dir, a new repo and new fixture seeds, with the trial-1 fixes and prompt changes in place.

| Task | Minutes | Tool calls | Note |
|---|---|---|---|
| T01 julianDay, jdToGregorian | 4.4 | 3 | |
| T02 sidereal offset and longitude | 5.2 | 3 | |
| T03 lunar mansion + quarter, divisional degrees | 6.1 | 5 | |
| T04 body positions | 5.1 | 5 | |
| T05 ascendant | 5.1 | 4 | |
| T06 weekday | 3.1 | 3 | |
| T07 sunrise | 10.4 | 9 | It read the test, grepped the fixtures, and edited and ran the check twice. |
| T08 body speed | 4.2 | 3 | The first half of trial 1's T08. |
| T09 lunar day | 8.2 | 5 | It wrote a shared `phaseAt` helper on its own. |
| T10 half lunar day | 4.0 | 3 | |
| T11 Sun+Moon index | 3.1 | 3 | It reused `phaseAt` without being told. |
| T12 Moon's mansion | 8.0 | 6 | |
| T13 main + sub periods | 9.6 | 7 | |
| T14 balance at the start | 4.8 | 5 | |

Every attempt went through all the gates: integrity, the task's checks, the global gate, the
hidden holdout, and the regression checks of every earlier task. None failed, so the worker never saw a
failure note. The model server stayed healthy all night, nothing was killed, and the night ended
with "no eligible task left". The result is 188 lines in five files.

### Checking the result after the night

The tests pass on 42 cases at loose tolerances (1 minute, 1 day), so the port was also
compared with the reference on cases that neither the planner nor the worker had seen:

- **500 new random cases** (a new seed) and **300 edge cases** the fixture generator never
  makes: days 29–31, 00:00:00 and 23:59:59, the years 1900 and 2099, latitudes out to ±66°,
  and zones from −12 to +14 including +12.75. All 15,202 acceptance checks pass.
- **The actual differences**, over all 842 cases:
  - Every integer result (sign, mansion, quarter, lunar day, half lunar day, Sun+Moon index,
    weekday, period lords, period balance) is identical.
  - Julian day, sidereal offset, longitudes, the ascendant and sunrise are bit-identical.
  - Divisional-chart degrees differ by at most 6e-14° and phase start/end times by at most 6e-9 s.
  - All 68,202 period start strings are identical, character for character.
- **Corners the data does not reach:**
  - A period start that rounds to "24:00:00" is formatted the same way as the reference's
    degrees-minutes-seconds formatter.
  - Where the Sun does not rise (above the polar circles), the reference returns a meaningless
    sunrise (about −58.8 million hours), and the port returns the same value. That is the
    requirement ("match the reference's quirks"), but anything built on `sunrise` must handle it.

So the code is correct in the sense the requirements set: it reproduces the reference. It is no
more astronomically correct than the reference is.


## What worked

- **The contract.** Acceptance tests from a real oracle, a hidden holdout on other cases, and
  regression on every attempt. "Passed" meant the same as "matches the reference on 42 cases".
- **Proving the plan before the night.** The planner ran a throwaway reference in a scratch copy, so every check
  was known to be passable and every formula correct before the worker started. That is why
  no task needed a second attempt.
- **Small tasks for a small model.** One function and one or two files per task meant 3–9 tool calls and
  3–10 minutes each. The worker's 32k context never filled.
- **Greppable fixtures.** One case per line, so the worker could `grep` one case instead of reading
  100 KB.
- **Namespace imports** (`import * as api`) in the shared test cases, so a missing later function
  fails only its own task.
- **Crash recovery.** Every interrupted attempt in trial 1 was detected on the next start, the
  repo was reset to the last good commit, and the night resumed with no manual repair.
- **`--tmux`.** The night runs in its own tmux session, owned by nobody's shell, and anyone can
  attach and watch pi work. This removed trial 1's main failure.

## What didn't work, and what changed

| Problem | Trial | Fix | Status |
|---|---|---|---|
| A non-`--in-place` `init` wrote `in_place:` empty. | 1 | Fixed, with a test. | done |
| The catalog's `timeout_min` overrides `budgets.attempt_timeout_min`, which is surprising. | 1, 2 | Override it per project (step 1). | open |
| `node --test tests/unit/` fails on Node 22; the gate needs a quoted glob. The planner had written the gate before the skeleton existed. | 1 | Prompt: run every gate as written, and write the gates last. | prompt changed |
| Pretty-printed fixtures were 209 KB with one value per line. | 1 | One record per line (102 KB). Prompt: data must be greppable. | prompt changed |
| The night died with the planner's shell under memory pressure. | 1 | `ns run --tmux`: the night lives in its own tmux session. | done |
| No way to watch pi work. | 1 | `--tmux` shows pi in a pane. | done |
| `pwsh` from the Microsoft Store is an App Execution Alias; `File.file?` is false for it, so `server.start_cmd` crashed the night. | 1 | `Exec.resolve` accepts aliases, with a test. | done |
| `ns doctor` did not check `server.start_cmd`, so that crash showed up only mid-night. | 1 | `doctor` checks that the program is on PATH, with a test. | done |
| The planner chose the scope itself from a one-line request. | 1 | Prompt: the scope is the human's call; propose it and wait for agreement. | prompt changed |
| The requirements' Must-not restated harness rules ("no new dependencies"). | 1 | Template hint: only choices that change the plan. | template changed |
| `src/swe.js` and `tools/` were not protected; the worker could have changed the ephemeris setup. It didn't. | 1 | Prompt: protect skeleton files in `gates.protect`. | prompt changed |
| `ns plan --print-prompt` ran on a still-empty `requirements.md` (the planner's write had failed) and produced a prompt from the template. | 2 | Proposal: `ns plan` should warn when requirements.md is unchanged from the template. | open |

## Was the plan correct?

**Yes, and it was accurate down to the formulas.** In trial 1, every task that got to run passed first
time, and the one that never finished (T08) had already printed DONE. In trial 2, all 14 passed first time, and
all 803 tests pass outside the harness. The 30 + 12 cases cover both hemispheres, years 1900–2099
and half-hour zones.

**Splitting T08 wasn't needed after all.** During trial 1 it looked as if T08 (two functions in two
files) had stalled, so trial 2 split it. The run files show the worker had finished it in 12
minutes; the harness stopped afterwards. The split is still in line with the sizing rule (one
function per task) and cost nothing, but trial 1 is not evidence that the task was too big.

**Three caveats:**

1. **The descriptions were close to code.** For example, T14's description gives the date
   arithmetic line by line, and the worker's code follows it almost exactly. To find the reference's
   quirks (integer truncation, `ceil(jd + 1) % 7` for the weekday, calendar-date day counts for the
   period balance) the planner had to port each function itself in the scratch reference. So the
   planner did the porting, and the worker transcribed and integrated it into the module. That is a
   legitimate way to use a weak worker, but it is not a test of whether the worker can port.
2. **The planner was not independent in trial 2.** The same model planned both trials, so trial 2's
   planning carried everything learned in trial 1. Trial 2 shows that the changed prompts don't get in the way of a good plan.
   It does not show that they produce one on their own.
3. **The scope was chosen before it was asked.** In trial 1 the planner picked the slice; in trial 2
   the human confirmed the same slice so the runs compare. The slice is well specified on purpose,
   so it leaves out the hard parts of the reference (end times found by interpolation, other
   period systems).

## Prompt changes

**Applied before trial 2** (in `templates/prompts/planner.md`, `planner-new.md`,
`templates/requirements.md`):

- Scope is the human's decision. When the requirements are thin, the planner proposes what is in,
  what is out and roughly how many tasks, and writes `requirements.md` only after the human agrees.
  Don't repeat rules the harness already enforces.
  *Effect:* in trial 2 the planner asked before planning.
- Run every check and gate command from the repo root, exactly as written, and quote globs.
  *Effect:* the global gate was right first time.
- A check fails only because of its own task (namespace imports in ES modules).
- Data the worker reads must be greppable, one record per line.
- From scratch: write `project.bootstrap`, `gates.global` and `gates.protect` last, giving only
  commands seen passing on the skeleton, and protect the skeleton files the tasks must not change.
- The requirements template's Must-not hint asks only for choices that change the plan. Its Out-of-scope
  hint says the planner will propose a scope if you leave it empty.

**Still to change** (proposals, not applied yet):

- **Prove each check can pass.** The prompt asks only that checks fail now. Trial 2's
  first-attempt record came from the planner running a throwaway implementation against every
  visible and holdout check, outside the repo. Make it a step, and reword "Do not implement the
  features yourself" to "do not put an implementation in the repo".
- **Say how much to give the worker.** The prompt says only that descriptions must be
  "self-contained", and the planner filled that with pseudocode. The prompt should say what to give: the
  behaviour, signatures, library calls and the quirks the checks depend on, but not the code.
  The next trial should measure the worker on behaviour-level descriptions, with the same tests.
- **Warn on an empty plan input.** `ns plan` should warn when `requirements.md` is still the
  template (this is a code change, not a prompt change).
- **One timeout setting.** Make `budgets.attempt_timeout_min` win over the catalog's `timeout_min`, or
  have `ns doctor` print the timeout that will apply.

## Run it yourself

The trial needs a Python reference library and its ephemeris binding for the oracle (Python,
planning only), Node 22, and a local model behind `pi-local`. The steps above are the whole
procedure. Start the night with `--tmux`, or from a terminal or a scheduled task, never from an
agent's background shell: the agent's host may kill that shell when memory is short.
