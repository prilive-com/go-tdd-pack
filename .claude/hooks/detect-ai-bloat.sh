#!/usr/bin/env bash
# PostToolUse hook: emit advisory context to Claude when the latest edit
# added new exported symbols, new dependencies, or new TODO/FIXME markers.
# Advisory only — never blocks. Uses hookSpecificOutput.additionalContext
# (visible to Claude) instead of systemMessage (visible to user only).

set -euo pipefail
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then exit 0; fi

EXPORTED="$(git diff -- '*.go' 2>/dev/null | grep -E '^\+func [A-Z]|^\+type [A-Z]|^\+var [A-Z]|^\+const [A-Z]' || true)"
GOMOD="$(git diff -- go.mod go.sum 2>/dev/null || true)"
TODOS="$(git diff 2>/dev/null | grep -E '^\+.*(TODO|FIXME|HACK)' || true)"

[[ -z "$EXPORTED$GOMOD$TODOS" ]] && exit 0

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "AI-bloat advisory: this edit added new exported symbols, go.mod requires, or TODO/FIXME markers. Before finalizing: verify each new exported symbol has >=2 callers; each new dependency is on .claude/allowed-modules.txt; each TODO/FIXME has an author + tracking reference or is removed. See .claude/rules/go-ai-bloat.md."
  }
}
JSON
exit 0
