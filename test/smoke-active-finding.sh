#!/usr/bin/env bash
# test/smoke-active-finding.sh
#
# v2.1 PR 8 — FDTDD foundation: verify the marker file + helper
# scripts work as documented.
#
# Covers:
#   - scripts/tdd/finding-start.sh writes a valid marker
#   - finding-id validation (R<n>-F<n>)
#   - red-proof file existence check
#   - single-active rule (second start refused)
#   - finding-finish.sh removes the marker
#   - finding-finish is idempotent
#   - lib/active-finding.sh accessors return correct values
#   - red-proof-hash verification accessor catches tampering
#   - hooks/protect-tdd-artifacts.sh blocks direct .tdd/active-finding writes

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
START="${PROJECT_ROOT}/scripts/tdd/finding-start.sh"
FINISH="${PROJECT_ROOT}/scripts/tdd/finding-finish.sh"
LIB="${PROJECT_ROOT}/runner/lib/active-finding.sh"
PROTECT_HOOK="${PROJECT_ROOT}/hooks/protect-tdd-artifacts.sh"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
PASS_COUNT=0

CLEANUP_PATHS=()
cleanup_all() {
  local p
  for p in "${CLEANUP_PATHS[@]}"; do
    [[ -n "$p" ]] && rm -rf "$p"
  done
}
trap cleanup_all EXIT

make_sandbox() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.tdd/findings/R1-F1" "$d/.tdd/reviews" "$d/runner/lib" "$d/scripts/tdd"
  cp "${PROJECT_ROOT}/runner/lib/active-finding.sh" "$d/runner/lib/"
  cp "${START}" "$d/scripts/tdd/"
  cp "${FINISH}" "$d/scripts/tdd/"
  echo "# Red proof for finding R1-F1" > "$d/.tdd/findings/R1-F1/red-proof.md"
  echo "Cited test: TestXxx; expected failure: <reason>" >> "$d/.tdd/findings/R1-F1/red-proof.md"
  echo "$d"
}

# ============================================================
# scripts/tdd/finding-start.sh
# ============================================================

info "[1] finding-start writes a valid marker"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R1-F1 .tdd/findings/R1-F1/red-proof.md > /dev/null
MARKER="$SANDBOX/.tdd/active-finding"
[[ -f "$MARKER" ]] || fail "case 1: marker not written"
jq empty "$MARKER" || fail "case 1: marker is not valid JSON"
FID=$(jq -r '.finding_id' "$MARKER")
SCHEMA=$(jq -r '.schema_version' "$MARKER")
HASH=$(jq -r '.red_proof_hash' "$MARKER")
RP=$(jq -r '.red_proof' "$MARKER")
[[ "$FID" == "R1-F1" ]]                              || fail "case 1: finding_id wrong: $FID"
[[ "$SCHEMA" == "1" ]]                               || fail "case 1: schema_version wrong: $SCHEMA"
[[ "$HASH" =~ ^sha256:[a-f0-9]{64}$ ]]               || fail "case 1: red_proof_hash format wrong: $HASH"
[[ "$RP" == ".tdd/findings/R1-F1/red-proof.md" ]]    || fail "case 1: red_proof path wrong: $RP"
pass "finding-start: writes marker with correct schema + finding_id + hash"
PASS_COUNT=$((PASS_COUNT+1))

info "[2] finding-start refuses invalid finding-id format"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
if CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" "not-a-valid-id" .tdd/findings/R1-F1/red-proof.md 2>/dev/null; then
  fail "case 2: should reject 'not-a-valid-id'"
fi
[[ ! -f "$SANDBOX/.tdd/active-finding" ]] || fail "case 2: marker should not be written on rejection"
pass "finding-start: rejects invalid finding-id with exit ≠ 0"
PASS_COUNT=$((PASS_COUNT+1))

info "[3] finding-start refuses missing red-proof file"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
if CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R2-F1 .tdd/findings/does-not-exist/red-proof.md 2>/dev/null; then
  fail "case 3: should reject missing red-proof"
fi
[[ ! -f "$SANDBOX/.tdd/active-finding" ]] || fail "case 3: marker should not be written"
pass "finding-start: rejects missing red-proof with exit ≠ 0"
PASS_COUNT=$((PASS_COUNT+1))

info "[4] finding-start refuses second-start when marker exists"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R1-F1 .tdd/findings/R1-F1/red-proof.md > /dev/null
# Now try to start again with a different finding.
mkdir -p "$SANDBOX/.tdd/findings/R2-F1"
echo "x" > "$SANDBOX/.tdd/findings/R2-F1/red-proof.md"
if CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R2-F1 .tdd/findings/R2-F1/red-proof.md 2>/dev/null; then
  fail "case 4: should refuse second-start"
fi
# Original marker should still be present and untouched.
FID=$(jq -r '.finding_id' "$SANDBOX/.tdd/active-finding")
[[ "$FID" == "R1-F1" ]] || fail "case 4: original marker overwritten; got $FID"
pass "finding-start: refuses second-start, original marker preserved"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# scripts/tdd/finding-finish.sh
# ============================================================

info "[5] finding-finish removes the marker"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R1-F1 .tdd/findings/R1-F1/red-proof.md > /dev/null
[[ -f "$SANDBOX/.tdd/active-finding" ]] || fail "case 5: setup failed"
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$FINISH" > /dev/null
[[ ! -f "$SANDBOX/.tdd/active-finding" ]] || fail "case 5: marker should be removed"
pass "finding-finish: marker removed"
PASS_COUNT=$((PASS_COUNT+1))

info "[6] finding-finish is idempotent (no marker → no error)"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
# No start; just finish.
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$FINISH" > /dev/null || fail "case 6: finish should be idempotent"
pass "finding-finish: idempotent when marker absent"
PASS_COUNT=$((PASS_COUNT+1))

info "[7] finding-finish appends to debates.jsonl"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R1-F1 .tdd/findings/R1-F1/red-proof.md > /dev/null
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$FINISH" --reason "fix verified" > /dev/null
DEBATES="$SANDBOX/.tdd/reviews/debates.jsonl"
[[ -f "$DEBATES" ]] || fail "case 7: debates.jsonl not written"
LAST_LINE=$(tail -1 "$DEBATES")
EVENT=$(echo "$LAST_LINE" | jq -r '.event')
REASON=$(echo "$LAST_LINE" | jq -r '.reason')
[[ "$EVENT" == "finding_finish" ]] || fail "case 7: event field wrong: $EVENT"
[[ "$REASON" == "fix verified" ]]  || fail "case 7: reason field wrong: $REASON"
pass "finding-finish: emits finding_finish event with reason to debates.jsonl"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# runner/lib/active-finding.sh accessors
# ============================================================

info "[8] active_finding_present: true when marker exists, false otherwise"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
(
  # shellcheck source=/dev/null
  . "$LIB"
  active_finding_present "$SANDBOX" && exit 1
  exit 0
) || fail "case 8a: expected absent before start"
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R1-F1 .tdd/findings/R1-F1/red-proof.md > /dev/null
(
  # shellcheck source=/dev/null
  . "$LIB"
  active_finding_present "$SANDBOX" || exit 1
  exit 0
) || fail "case 8b: expected present after start"
pass "active_finding_present: correct in both states"
PASS_COUNT=$((PASS_COUNT+1))

info "[9] active_finding_field returns correct values"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R3-F5 .tdd/findings/R1-F1/red-proof.md > /dev/null
(
  # shellcheck source=/dev/null
  . "$LIB"
  id=$(active_finding_field finding_id "$SANDBOX")
  mode=$(active_finding_field mode "$SANDBOX")
  [[ "$id" == "R3-F5" ]] || { echo "id wrong: $id" >&2; exit 1; }
  [[ "$mode" == "green_fix" ]] || { echo "mode wrong: $mode" >&2; exit 1; }
) || fail "case 9: field accessor wrong"
pass "active_finding_field: reads finding_id + mode correctly"
PASS_COUNT=$((PASS_COUNT+1))

info "[10] active_finding_red_proof_hash_matches: detects tampering"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R1-F1 .tdd/findings/R1-F1/red-proof.md > /dev/null
# Get the recorded hash.
RECORDED=$(jq -r '.red_proof_hash' "$SANDBOX/.tdd/active-finding")
# Tamper the red-proof file.
echo "tampered content" >> "$SANDBOX/.tdd/findings/R1-F1/red-proof.md"
(
  # shellcheck source=/dev/null
  . "$LIB"
  CURRENT=$(active_finding_compute_red_proof_hash "$SANDBOX/.tdd/findings/R1-F1/red-proof.md")
  if active_finding_red_proof_hash_matches "$CURRENT" "$SANDBOX"; then
    echo "should NOT match — file was tampered after start" >&2
    exit 1
  fi
  # But the recorded hash still matches itself.
  active_finding_red_proof_hash_matches "$RECORDED" "$SANDBOX" || {
    echo "recorded-hash-against-recorded-marker should match" >&2
    exit 1
  }
) || fail "case 10: hash mismatch detection broken"
pass "active_finding_red_proof_hash_matches: detects post-start tampering"
PASS_COUNT=$((PASS_COUNT+1))

info "[11] active_finding_validate_id accepts R<n>-F<n>, rejects others"
(
  # shellcheck source=/dev/null
  . "$LIB"
  active_finding_validate_id "R1-F1"   || { echo "R1-F1 should pass" >&2; exit 1; }
  active_finding_validate_id "R10-F99" || { echo "R10-F99 should pass" >&2; exit 1; }
  active_finding_validate_id "r1-f1"   && { echo "lowercase r1-f1 should fail" >&2; exit 1; }
  active_finding_validate_id "R1F1"    && { echo "missing dash should fail" >&2; exit 1; }
  active_finding_validate_id "R1-X1"   && { echo "wrong second-letter should fail" >&2; exit 1; }
  active_finding_validate_id ""        && { echo "empty should fail" >&2; exit 1; }
  exit 0
) || fail "case 11: validation logic broken"
pass "active_finding_validate_id: enforces R<n>-F<n> format"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# hooks/protect-tdd-artifacts.sh blocks direct edits to marker
# ============================================================

info "[12] Gate 4 blocks direct Claude writes to .tdd/active-finding"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
INPUT=$(jq -nc --arg t "Write" --arg f "$SANDBOX/.tdd/active-finding" --arg c "{}" \
  '{tool_name:$t, session_id:"s", tool_input:{file_path:$f, content:$c}}')
OUT=$(CLAUDE_PROJECT_DIR="$SANDBOX" bash "$PROTECT_HOOK" <<< "$INPUT" 2>/dev/null)
DEC=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty')
REASON=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')
[[ "$DEC" == "deny" ]] || fail "case 12: expected deny, got: $DEC"
[[ "$REASON" == *"finding-start.sh"* ]] || fail "case 12: deny reason should point at finding-start.sh; got: $REASON"
pass "Gate 4: .tdd/active-finding writes blocked; deny reason cites helper scripts"
PASS_COUNT=$((PASS_COUNT+1))

# ---- summary ----

echo ""
echo "================================================================"
echo "  ACTIVE-FINDING SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
exit 0
