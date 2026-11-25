#!/usr/bin/env bash
# Claude Code hook: reminds the agent to update the .md docs (see AGENTS.md).
#
#   doc-check.sh init   (SessionStart) records the current state of the working tree;
#   doc-check.sh        (Stop) if code changed since the last record but no .md file did,
#                       blocks the stop once and asks the agent to check the docs.
#
# The record is two fingerprints (code and docs) in .git/claude-doc-check, so it is never
# committed. A fingerprint covers the diff against HEAD plus the untracked files.

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
input=$(cat)
git_dir=$(git rev-parse --git-dir 2>/dev/null) || exit 0
state="$git_dir/claude-doc-check"

# Prints one hash for the changes under the given pathspecs.
fingerprint() {
  {
    git diff HEAD -- "$@"
    git ls-files -z --others --exclude-standard -- "$@" |
      while IFS= read -r -d '' f; do echo "$f $(git hash-object -- "$f")"; done
  } | git hash-object --stdin
}

code=$(fingerprint . ':(exclude)*.md')
docs=$(fingerprint '*.md')
old_code=""
old_docs=""
[ -f "$state" ] && read -r old_code old_docs < "$state"
echo "$code $docs" > "$state"

[ "$1" = "init" ] && exit 0
[ -z "$old_code" ] && exit 0
# The agent is already answering this reminder: let it stop.
case "$input" in *'"stop_hook_active":true'* | *'"stop_hook_active": true'*) exit 0 ;; esac

if [ "$code" != "$old_code" ] && [ "$docs" = "$old_docs" ]; then
  cat <<'JSON'
{"decision": "block", "reason": "Code changed in this turn but no .md file did. Per AGENTS.md, update the affected docs now (lib/ARCHITECTURE.md, README.md, CONVENTIONS.md, templates/prompts/*.md, templates/project.yml), or say in one line why none need changes."}
JSON
fi
exit 0
