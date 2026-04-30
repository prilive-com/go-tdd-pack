#!/usr/bin/env bash
# PostToolUse hook: emit an advisory note if the latest edit added new
# exported symbols, new dependencies, or new TODO/FIXME markers.
# Advisory only — never blocks.

set -euo pipefail
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then exit 0; fi

EXPORTED="$(git diff -- '*.go' 2>/dev/null | grep -E '^\+func [A-Z]|^\+type [A-Z]|^\+var [A-Z]|^\+const [A-Z]' || true)"
GOMOD="$(git diff -- go.mod go.sum 2>/dev/null || true)"
TODOS="$(git diff 2>/dev/null | grep -E '^\+.*(TODO|FIXME|HACK)' || true)"

[[ -z "$EXPORTED$GOMOD$TODOS" ]] && exit 0

cat <<EOF
{
  "systemMessage": "AI-bloat advisory: suspicious additions detected. Before finalizing, verify each new exported symbol has >=2 callers, each new dependency is on .claude/allowed-modules.txt, and TODO/FIXME comments resolve. See .claude/rules/go-ai-bloat.md."
}
EOF
exit 0
