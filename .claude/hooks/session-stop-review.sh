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

  # v1.9.7: durably mark matching pending entries as abandoned,
  # append a SHA-chained audit-log entry, and rotate the file.
  #
  # Pre-v1.9.7 this branch only allowed Stop and exited. The
  # obligation entries stayed semantically `pending` forever in
  # `.tdd/exceptions/post-red-test-edits.json`. The audit log never
  # showed clean closure. A later cycle that happened to share the
  # cycle_id would inherit the stale abandonment file and leak the
  # signal. Real adopter session at 2026-05-15 reported having to
  # re-write the file every session — root cause was almost
  # certainly cycle_id mismatch (new plan → new id), but the
  # underlying defect (no durable closure record) was real.
  ts="$(date -u +%FT%TZ 2>/dev/null || echo unknown)"
  unix_ts="$(date -u +%s 2>/dev/null || echo 0)"

  # 1. Transition matching pending entries to status:"abandoned".
  if [[ -f "$ARTIFACT" ]]; then
    tmp="$(mktemp 2>/dev/null || echo "/tmp/sstop.$$.json")"
    if jq --arg cid "$cycle_id" --arg ts "$ts" '
          .exceptions = (.exceptions | map(
            if .binding.cycle_id == $cid and .status == "pending" then
              .status = "abandoned"
              | .abandoned_by = "operator"
              | .abandoned_at = $ts
              | .reason = "operator wrote .tdd/CYCLE_ABANDONED.txt"
            else . end
          ))' "$ARTIFACT" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$ARTIFACT" 2>/dev/null || true
    else
      rm -f "$tmp" 2>/dev/null || true
    fi
  fi

  # 2. Append SHA-chained audit-log entry (same pattern as runner).
  audit_log="$PROJECT_DIR/.tdd/audit/${cycle_id}.jsonl"
  mkdir -p "$(dirname "$audit_log")" 2>/dev/null || true
  prev_audit_sha=""
  if [[ -s "$audit_log" ]]; then
    last_line="$(tail -1 "$audit_log")"
    if command -v sha256sum >/dev/null 2>&1; then
      prev_audit_sha="$(printf '%s' "$last_line" | sha256sum | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
      prev_audit_sha="$(printf '%s' "$last_line" | shasum -a 256 | awk '{print $1}')"
    fi
  fi
  jq -c -n \
    --arg ts "$ts" \
    --arg event "cycle_abandoned" \
    --arg cycle "$cycle_id" \
    --arg prev "$prev_audit_sha" \
    '{ts:$ts, event:$event, cycle_id:$cycle, abandoned_by:"operator", prev_sha:$prev}' \
    >> "$audit_log" 2>/dev/null || true

  # 3. Rotate the abandonment file. Preserves durable record AND
  # prevents a fresh cycle that happens to share the cycle_id from
  # inheriting a stale "abandoned" signal.
  rotated_dir="$PROJECT_DIR/.tdd/abandoned"
  mkdir -p "$rotated_dir" 2>/dev/null || true
  rotated_file="$rotated_dir/${cycle_id}-${unix_ts}.txt"
  mv "$abandoned_file" "$rotated_file" 2>/dev/null || true

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

# v1.10.2: write per-cycle state.json at every clean session exit, plus
# update .tdd/active to point at the most recent cycle. SessionStart
# reads this on the next session to inject continuation context. The
# state file is best-effort — if any step fails we still exit 0.
#
# Schema (kept intentionally minimal for MVP):
#   {
#     "cycle_id":     "<id>",
#     "status":       "reviewing|approved|abandoned|...",
#     "next_actor":   "claude|codex|human|none",
#     "approved_rounds": <count>,
#     "updated_at":   "<iso-8601>",
#     "context_hint": "<human-readable summary for SessionStart injection>"
#   }
cycle_dir="$PROJECT_DIR/.tdd/cycles/${cycle_id}"
mkdir -p "$cycle_dir" 2>/dev/null || true

ts="$(date -u +%FT%TZ 2>/dev/null || echo unknown)"
approved_rounds=0
if [[ -f "$ARTIFACT" ]]; then
  approved_rounds=$(jq -r --arg cid "$cycle_id" '
    [.exceptions[]?
     | select(.binding.cycle_id == $cid)
     | select(.status == "approved")
    ] | length
  ' "$ARTIFACT" 2>/dev/null || echo 0)
  [[ -z "$approved_rounds" ]] && approved_rounds=0
fi

# Status + next_actor derivation. At Stop time, if we reached here, there
# are no pending obligations (we already returned above if pending > 0).
# So the cycle is either approved (some completion exists) or fresh
# (no work done yet).
if [[ "$approved_rounds" -gt 0 ]]; then
  status="approved"
  next_actor="claude"
  hint="Cycle $cycle_id has ${approved_rounds} approved review round(s). Next action depends on what Claude is doing — likely continue implementation OR commit if green proof captured."
else
  status="pending"
  next_actor="claude"
  hint="Cycle $cycle_id is open with no completed reviews yet. Resume work as you left it; trigger hooks will fire on the next Tier 1 edit."
fi

jq -n \
  --arg cid    "$cycle_id" \
  --arg st     "$status" \
  --arg na     "$next_actor" \
  --argjson ar "$approved_rounds" \
  --arg ts     "$ts" \
  --arg hint   "$hint" \
  '{cycle_id:$cid, status:$st, next_actor:$na, approved_rounds:$ar, updated_at:$ts, context_hint:$hint}' \
  > "$cycle_dir/state.json.tmp" 2>/dev/null && \
  mv "$cycle_dir/state.json.tmp" "$cycle_dir/state.json" 2>/dev/null || true

# Update the pointer to the cycle this session was working on.
echo "$cycle_id" > "$PROJECT_DIR/.tdd/active.tmp" 2>/dev/null && \
  mv "$PROJECT_DIR/.tdd/active.tmp" "$PROJECT_DIR/.tdd/active" 2>/dev/null || true

exit 0
