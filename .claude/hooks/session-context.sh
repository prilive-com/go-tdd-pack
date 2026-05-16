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

# v1.10.2: cycle resumption context. If .tdd/active points at a cycle
# with a state.json, inject a one-paragraph continuation hint so the
# operator can pick up where they left off without re-typing context.
# Best-effort: any error along the path collapses to the base bootstrap
# message. Known limitation: anthropics/claude-code#10373 — SessionStart
# context injection is unreliable for brand-new conversations (works on
# /clear, /compact, and URL resume). If injection silently drops, the
# operator can run /continue (slash command) which has the same effect.
CYCLE_HINT=""
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
ACTIVE_POINTER="$PROJECT_DIR/.tdd/active"
if [[ -f "$ACTIVE_POINTER" ]]; then
  active_cycle="$(head -1 "$ACTIVE_POINTER" 2>/dev/null | tr -d '[:space:]' || echo "")"
  if [[ -n "$active_cycle" ]]; then
    state_file="$PROJECT_DIR/.tdd/cycles/${active_cycle}/state.json"
    if [[ -f "$state_file" ]] && command -v jq >/dev/null 2>&1; then
      CYCLE_HINT=$(jq -r '
        "Active TDD cycle: " + .cycle_id +
        " | status=" + .status +
        " | next_actor=" + .next_actor +
        " | approved_rounds=" + (.approved_rounds | tostring) +
        " | hint: " + .context_hint
      ' "$state_file" 2>/dev/null || echo "")
    fi
  fi
fi

# Use jq to safely escape values into the JSON payload (avoids quoting bugs
# when branch names or file paths contain special characters). jq is required
# elsewhere in this pack; if missing, fall back to a minimal static payload.
if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg branch "$BRANCH" \
    --arg files "${CHANGED//$'\n'/, }${SUFFIX}" \
    --arg cycle "$CYCLE_HINT" \
    '{
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: ("Project bootstrap: current branch is " + $branch + ". Recently changed files: " + (if $files == "" then "none" else $files end) + "." + (if $cycle == "" then "" else "\n\n" + $cycle end))
      }
    }'
else
  cat <<FALLBACK
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Project bootstrap: current branch is '$BRANCH'."}}
FALLBACK
fi
