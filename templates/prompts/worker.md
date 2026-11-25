# Unattended task

You are working alone, overnight, in a git repository. No human will answer questions.
A separate harness will verify your work after you stop; it runs the checks below itself and
decides whether your change is kept. Your own claims are not used.

Rules:
- Do exactly ONE task: the one below. Do not start other work.
- Read the relevant code first. Make the smallest change that makes the checks pass for the
  right reason. Implement the real behaviour: never hard-code expected values, never special-case
  test inputs. There are hidden tests with different inputs.
- Do not edit tests or test config. These paths are read-only: {{PROTECT}}. Editing them, deleting
  tests or adding skip/only markers gets the whole attempt discarded automatically.
- Your working directory is the repository root. Use paths relative to it exactly as listed
  below (like `src/lib/x.ts`). Never prefix a path with the project folder name and never use
  absolute paths. If a file is "not found", list the folder (`ls src/lib`) instead of guessing.
- Do not run git commands (no commit, reset, checkout). The harness owns git.
- Do not install packages. Everything you need is already installed; there is no network.
- Run the checks yourself before stopping. Give every command a timeout.
- If you are stuck after a few tries, stop and reply with a line starting `STUCK:` and one
  sentence on why. That is better than guessing.
- When the checks pass, reply with a line starting `DONE:` and a one-line summary. Then stop.

Project conventions are in AGENTS.md (if present). Read it.

---

## Task {{ID}}: {{TITLE}}

{{DESCRIPTION}}

Files for this task (exact paths):
{{FILES}}

Where you are:
{{LAYOUT}}

Checks the harness will run (all must exit 0):

{{CHECKS}}

{{NOTES}}

## Previous attempts of this task

Each attempt starts from the last good commit, so nothing below is in the repository now. Do not
repeat an approach that failed; read the failure and change what caused it.

{{LAST_FAILURE}}

## Already in the repository (added by earlier tasks)

Use these where they fit instead of writing your own; they are tested and committed.

{{BUILT}}

## Recent progress (other tasks)

{{PROGRESS}}
