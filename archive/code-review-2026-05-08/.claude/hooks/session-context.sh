#!/usr/bin/env bash
# Claude Code SessionStart hook — prints a quick orientation snapshot
# (current branch + recently-changed files) into the new session context.
#
# Output shape: hookSpecificOutput.additionalContext (consistent with the
# documented PreToolUse/PostToolUse shape). v1.0/1.1 used a top-level
# additionalContext; that worked but is inconsistent with the rest of the
# hooks in this pack and undocumented for SessionStart specifically.
# v1.2.0 normalizes on the documented hookSpecificOutput shape so all hooks
# in this pack speak the same JSON.

set -euo pipefail

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
ALL_CHANGED="$(git diff --name-only --relative HEAD 2>/dev/null || true)"
TOTAL=$(printf '%s\n' "$ALL_CHANGED" | grep -cv '^$' || true)
CHANGED="$(printf '%s' "$ALL_CHANGED" | head -50)"

SUFFIX=""
if [ "${TOTAL:-0}" -gt 50 ]; then
  SUFFIX=" (+$((TOTAL - 50)) more)"
fi

# Use jq to safely escape values into the JSON payload (avoids quoting bugs
# when branch names or file paths contain special characters). jq is required
# elsewhere in this pack; if missing, fall back to a minimal static payload.
if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg branch "$BRANCH" \
    --arg files "${CHANGED//$'\n'/, }${SUFFIX}" \
    '{
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: ("Project bootstrap: current branch is " + $branch + ". Recently changed files: " + (if $files == "" then "none" else $files end) + ".")
      }
    }'
else
  cat <<FALLBACK
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Project bootstrap: current branch is '$BRANCH'."}}
FALLBACK
fi
