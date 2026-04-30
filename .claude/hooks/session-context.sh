#!/usr/bin/env bash
# Claude Code SessionStart hook — prints a quick orientation snapshot
# (current branch + recently-changed files) into the new session context.

set -euo pipefail

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
CHANGED="$(git diff --name-only --relative HEAD 2>/dev/null | head -20 || true)"

cat <<EOF
{
  "additionalContext": "Project bootstrap: current branch is '$BRANCH'. Recently changed files: ${CHANGED//$'\n'/, }"
}
EOF
