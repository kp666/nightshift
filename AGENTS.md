# Instructions for coding agents working on nightshift

This file is for agents that change nightshift itself (Claude Code, pi, Codex, opencode).
`CLAUDE.md` only imports it, so every agent follows the same rules.

## Keep the docs in step with the code

**When you change code, update the affected `.md` files in the same change**, not later:

- `lib/ARCHITECTURE.md`: the map of the code. Update it when a file under `lib/` is added,
  removed, renamed or split, when a file's job changes, or when the calls between files, the
  night loop or the state files change (`test/docs_test.rb` catches a missing file, not a
  wrong description);
- `README.md`: commands and options, the quick start, configuration keys, the task format,
  the test count and list (section 10) and the file layout (section 11);
- `CONVENTIONS.md`: the class and service lists, the command table, how-to-extend and the
  Windows notes;
- `templates/prompts/*.md` and `templates/project.yml`, when what the agent or the user is told
  changes;
- `TRADEOFFS.md`, when a change alters what a trade-off costs or protects (for example what
  in-place mode refuses).

When you rename or remove something, grep the `.md` files for the old name. When you finish a
change, say which `.md` files you updated, or why none needed changes. Before a commit, check
once more that the docs match the code.

In Claude Code, a Stop hook (`.claude/hooks/doc-check.sh`) reminds you at the end of a turn
in which code changed but no `.md` file did.

## Before you change anything

Read `README.md` and `CONVENTIONS.md`. CONVENTIONS.md has the rules for the code itself.
Then read `lib/ARCHITECTURE.md` to find the files your change touches, instead of reading all of
`lib/`.

## After every change

```bash
bundle exec rake test     # all tests must pass
bundle exec rake lint     # RuboCop must report no offenses
bundle exec rake guard    # the pi guard's tests
```

- Fix lint with `bundle exec rake lint:fix`, never plain `rubocop -a`: on Windows it writes CRLF.
- Every file is LF (`git ls-files --eol` to check), except `*.cmd`.
- Ruby must be on the PATH. If Git Bash can't find it, add Ruby's `bin` folder to `PATH` first.
- Commit only when the user asks.

## Never leak personal or machine details

Nothing in this repo may name the user or describe their machine. This covers code, docs,
tests, config examples, prompts, and commit messages:

- no names, usernames, or email addresses;
- no real local paths: home folders (`C:\Users\<name>\...`, `/home/<name>/...`), install
  folders, or the names and layout of the user's other projects and sibling folders;
- no OS edition or version, hostname, or hardware details (GPU, RAM, CPU), and no "on this
  machine" statements.

Use placeholders instead: `C:\path\to\nightshift`, `C:/path/to/repo`, `<state>`, `~`. Tests
build their paths from a temp dir. Plain product facts are fine: nightshift supports Windows
and uses Git Bash, and `C:\Program Files\Git` is the default Git install path. Before every
commit, grep the changes for the user's username and for `C:\Users`.
