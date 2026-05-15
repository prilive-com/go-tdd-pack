#!/usr/bin/env bash
# .claude/hooks/session-stop-review.sh
#
# v1.9.0 — Stop hook. Blocks session-end when pending /second-opinion
# obligations exist for the current cycle, unless the operator has
# explicitly abandoned the cycle via .tdd/CYCLE_ABANDONED.txt.
#
# Loop-guard: if stop_hook_active is true (Claude is already
# continuing as a result of a prior Stop), exit 0 immediately.
# Verified semantics from code.claude.com/docs/en/hooks (May 2026):
# "The stop_hook_active field is true when Claude Code is already
# continuing as a result of a stop hook."

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "[session-stop-review] WARN: jq missing — allowing stop (cannot evaluate)." >&2
  exit 0
fi

INPUT="$(cat)"
if ! printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1; then
  # Malformed input → allow stop (Stop hooks should be conservative).
  exit 0
fi

# Loop guard.
stop_active="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')"
if [[ "$stop_active" == "true" ]]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PLAN="$PROJECT_DIR/.tdd/current-plan.md"
ARTIFACT="$PROJECT_DIR/.tdd/exceptions/post-red-test-edits.json"

# Cycle ID.
cycle_id=""
if [[ -f "$PLAN" ]]; then
  cycle_id="$( { grep -E '^Cycle ID:' "$PLAN" 2>/dev/null || true; } | head -1 | sed -E 's/^Cycle ID:[[:space:]]*//')"
fi
[[ -z "$cycle_id" ]] && exit 0

# Explicit operator abandonment. v1.9.0 round-3 F3: model CANNOT
# write this file — `.claude/settings.json` permissions.deny blocks
# Edit/Write/MultiEdit on .tdd/CYCLE_ABANDONED.txt. The operator
# writes it directly from their terminal (outside the model loop).
# Additionally, require the cycle_id to match the file content so a
# stale abandonment from a different cycle does not allow stop.
abandoned_file="$PROJECT_DIR/.tdd/CYCLE_ABANDONED.txt"
if [[ -f "$abandoned_file" ]] \
   && grep -qE 'APPROVED CYCLE ABANDONMENT' "$abandoned_file" 2>/dev/null \
   && grep -qF "$cycle_id" "$abandoned_file" 2>/dev/null; then
  # Audit-log entry could be appended here; for v1.9.0 allow stop.
  exit 0
fi

# Look for pending obligations matching this cycle.
pending=0
if [[ -f "$ARTIFACT" ]]; then
  pending=$(jq -r --arg cid "$cycle_id" '
    [.exceptions[]?
     | select(.binding.cycle_id == $cid)
     | select(.status == "pending")
    ] | length
  ' "$ARTIFACT" 2>/dev/null || echo 0)
  [[ -z "$pending" ]] && pending=0
fi

if [[ "$pending" -gt 0 ]]; then
  jq -n --arg cid "$cycle_id" --arg n "$pending" '
    {
      decision: "block",
      reason: ("Session cannot end with " + $n + " pending /second-opinion obligation(s) for cycle " + $cid + ". Either (a) complete the obligation with scripts/tdd/run-second-opinion.sh, OR (b) operator (human) abandons the cycle from a real shell prompt outside Claude Code — Claude itself cannot write this file, it is denied by .claude/settings.json (Edit/Write/MultiEdit) AND by the Bash pretrigger classifier, by design. To abandon: in your terminal, run: echo \"APPROVED CYCLE ABANDONMENT\" > .tdd/CYCLE_ABANDONED.txt — then retry /exit.")
    }'
  exit 0
fi

exit 0
