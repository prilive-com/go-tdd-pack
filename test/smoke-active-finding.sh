#!/usr/bin/env bash
# test/smoke-active-finding.sh
#
# v2.1 PR 8     — FDTDD foundation: verify the v1 marker + helper scripts.
# v2.3 slice 1  — verifies the v2 marker (.tdd/findings/active.json),
#                 the extended schema fields, and the
#                 v1 → v2 backward-compat read path. The legacy v1
#                 write path is gone (finding-start always writes v2);
#                 case 12 still covers Gate 4's exact-file protection
#                 of the legacy path for adopters mid-upgrade.
#
# Covers:
#   - scripts/tdd/finding-start.sh writes a valid v2 marker
#   - finding-id validation (R<n>-F<n>)
#   - red-proof file existence check
#   - tier validation
#   - single-active rule (second start refused — including against a
#     pre-existing legacy v1 marker)
#   - finding-finish.sh rotates v2 markers to closed/<id>.json
#   - finding-finish.sh removes legacy v1 markers (no rotation)
#   - finding-finish is idempotent
#   - lib/active-finding.sh accessors return correct values for v2
#   - v2 accessors with v1-fallback defaults (phase=red,
#     red_proof_accepted=false, empty test_files/prod_files)
#   - red-proof-hash verification accessor catches tampering
#   - hooks/protect-tdd-artifacts.sh blocks writes to both v1 and v2
#     marker paths

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

V2_PATH=".tdd/findings/active.json"
V1_PATH=".tdd/active-finding"

# ============================================================
# scripts/tdd/finding-start.sh — v2 schema
# ============================================================

info "[1] finding-start writes a valid v2 marker at .tdd/findings/active.json"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R1-F1 .tdd/findings/R1-F1/red-proof.md > /dev/null
MARKER="$SANDBOX/${V2_PATH}"
[[ -f "$MARKER" ]] || fail "case 1: v2 marker not written at $MARKER"
[[ ! -f "$SANDBOX/${V1_PATH}" ]] || fail "case 1: legacy v1 marker should NOT be written"
jq empty "$MARKER" || fail "case 1: marker is not valid JSON"
FID=$(jq -r '.finding_id' "$MARKER")
SCHEMA=$(jq -r '.schema_version' "$MARKER")
PHASE=$(jq -r '.phase' "$MARKER")
RED_OK=$(jq -r '.red_proof_accepted' "$MARKER")
TIER=$(jq -r '.tier' "$MARKER")
HASH=$(jq -r '.red_proof_hash' "$MARKER")
RP=$(jq -r '.red_proof' "$MARKER")
[[ "$FID" == "R1-F1" ]]                              || fail "case 1: finding_id wrong: $FID"
[[ "$SCHEMA" == "2" ]]                               || fail "case 1: schema_version wrong: $SCHEMA (expected 2)"
[[ "$PHASE" == "red" ]]                              || fail "case 1: phase wrong: $PHASE (expected red)"
[[ "$RED_OK" == "false" ]]                           || fail "case 1: red_proof_accepted wrong: $RED_OK"
[[ "$TIER" == "untiered" ]]                          || fail "case 1: default tier wrong: $TIER"
[[ "$HASH" =~ ^sha256:[a-f0-9]{64}$ ]]               || fail "case 1: red_proof_hash format wrong: $HASH"
[[ "$RP" == ".tdd/findings/R1-F1/red-proof.md" ]]    || fail "case 1: red_proof path wrong: $RP"
pass "finding-start: writes v2 marker (schema 2, phase=red, red_proof_accepted=false, default tier=untiered)"
PASS_COUNT=$((PASS_COUNT+1))

info "[1b] finding-start --tier tier1 writes tier:tier1"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R1-F1 .tdd/findings/R1-F1/red-proof.md --tier tier1 > /dev/null
TIER=$(jq -r '.tier' "$SANDBOX/${V2_PATH}")
[[ "$TIER" == "tier1" ]] || fail "case 1b: tier wrong: $TIER"
pass "finding-start: --tier flag sets tier field correctly"
PASS_COUNT=$((PASS_COUNT+1))

info "[2] finding-start refuses invalid finding-id format"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
if CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" "not-a-valid-id" .tdd/findings/R1-F1/red-proof.md 2>/dev/null; then
  fail "case 2: should reject 'not-a-valid-id'"
fi
[[ ! -f "$SANDBOX/${V2_PATH}" ]] || fail "case 2: v2 marker should not be written on rejection"
[[ ! -f "$SANDBOX/${V1_PATH}" ]] || fail "case 2: v1 marker should not be written on rejection"
pass "finding-start: rejects invalid finding-id with exit ≠ 0"
PASS_COUNT=$((PASS_COUNT+1))

info "[3] finding-start refuses missing red-proof file"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
if CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R2-F1 .tdd/findings/does-not-exist/red-proof.md 2>/dev/null; then
  fail "case 3: should reject missing red-proof"
fi
[[ ! -f "$SANDBOX/${V2_PATH}" ]] || fail "case 3: marker should not be written"
pass "finding-start: rejects missing red-proof with exit ≠ 0"
PASS_COUNT=$((PASS_COUNT+1))

info "[3b] finding-start refuses invalid --tier value"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
if CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R2-F1 .tdd/findings/R1-F1/red-proof.md --tier bogus 2>/dev/null; then
  fail "case 3b: should reject --tier bogus"
fi
[[ ! -f "$SANDBOX/${V2_PATH}" ]] || fail "case 3b: marker should not be written"
pass "finding-start: rejects invalid --tier value (exit 6)"
PASS_COUNT=$((PASS_COUNT+1))

info "[4] finding-start refuses second-start when v2 marker exists"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R1-F1 .tdd/findings/R1-F1/red-proof.md > /dev/null
mkdir -p "$SANDBOX/.tdd/findings/R2-F1"
echo "x" > "$SANDBOX/.tdd/findings/R2-F1/red-proof.md"
if CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R2-F1 .tdd/findings/R2-F1/red-proof.md 2>/dev/null; then
  fail "case 4: should refuse second-start"
fi
FID=$(jq -r '.finding_id' "$SANDBOX/${V2_PATH}")
[[ "$FID" == "R1-F1" ]] || fail "case 4: original v2 marker overwritten; got $FID"
pass "finding-start: refuses second-start, original v2 marker preserved"
PASS_COUNT=$((PASS_COUNT+1))

info "[4b] finding-start refuses second-start when a legacy v1 marker exists"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
# Plant a v1 legacy marker as if the adopter were mid-upgrade.
cat > "$SANDBOX/${V1_PATH}" <<'EOF'
{
  "schema_version": 1,
  "finding_id": "R9-F9",
  "mode": "green_fix",
  "started_at": "2026-06-08T10:00:00Z",
  "red_proof": "old/red-proof.md",
  "red_proof_hash": "sha256:0000000000000000000000000000000000000000000000000000000000000000"
}
EOF
if CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R1-F1 .tdd/findings/R1-F1/red-proof.md 2>/dev/null; then
  fail "case 4b: should refuse second-start against legacy v1 marker"
fi
[[ -f "$SANDBOX/${V1_PATH}" ]] || fail "case 4b: legacy marker should be untouched"
[[ ! -f "$SANDBOX/${V2_PATH}" ]] || fail "case 4b: v2 marker should NOT be written"
pass "finding-start: refuses second-start against pre-existing legacy v1 marker"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# scripts/tdd/finding-finish.sh — v2 rotation + v1 legacy removal
# ============================================================

info "[5] finding-finish rotates v2 marker to closed/<id>.json"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R1-F1 .tdd/findings/R1-F1/red-proof.md > /dev/null
[[ -f "$SANDBOX/${V2_PATH}" ]] || fail "case 5: setup failed (no v2 marker)"
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$FINISH" > /dev/null
[[ ! -f "$SANDBOX/${V2_PATH}" ]] || fail "case 5: active marker should be removed"
CLOSED="$SANDBOX/.tdd/findings/closed/R1-F1.json"
[[ -f "$CLOSED" ]] || fail "case 5: rotated marker should exist at $CLOSED"
CLOSED_PHASE=$(jq -r '.phase' "$CLOSED")
CLOSED_AT=$(jq -r '.closed_at' "$CLOSED")
[[ "$CLOSED_PHASE" == "closed" ]] || fail "case 5: closed phase wrong: $CLOSED_PHASE"
[[ "$CLOSED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || fail "case 5: closed_at format wrong: $CLOSED_AT"
pass "finding-finish: rotates v2 marker to closed/, sets phase=closed + closed_at"
PASS_COUNT=$((PASS_COUNT+1))

info "[5b] finding-finish removes legacy v1 marker (no rotation, no closed/)"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
cat > "$SANDBOX/${V1_PATH}" <<'EOF'
{
  "schema_version": 1,
  "finding_id": "R7-F2",
  "mode": "green_fix",
  "started_at": "2026-06-08T10:00:00Z",
  "red_proof": "x.md",
  "red_proof_hash": "sha256:0000000000000000000000000000000000000000000000000000000000000000"
}
EOF
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$FINISH" > /dev/null
[[ ! -f "$SANDBOX/${V1_PATH}" ]] || fail "case 5b: legacy marker should be removed"
[[ ! -d "$SANDBOX/.tdd/findings/closed" ]] || fail "case 5b: closed/ should not be created for v1 finish"
pass "finding-finish: removes legacy v1 marker without creating closed/"
PASS_COUNT=$((PASS_COUNT+1))

info "[6] finding-finish is idempotent (no marker → no error)"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$FINISH" > /dev/null || fail "case 6: finish should be idempotent"
pass "finding-finish: idempotent when marker absent"
PASS_COUNT=$((PASS_COUNT+1))

info "[7] finding-finish appends finding_finish event with schema kind to debates.jsonl"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R1-F1 .tdd/findings/R1-F1/red-proof.md > /dev/null
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$FINISH" --reason "fix verified" > /dev/null
DEBATES="$SANDBOX/.tdd/reviews/debates.jsonl"
[[ -f "$DEBATES" ]] || fail "case 7: debates.jsonl not written"
LAST_LINE=$(tail -1 "$DEBATES")
EVENT=$(echo "$LAST_LINE" | jq -r '.event')
REASON=$(echo "$LAST_LINE" | jq -r '.reason')
SCHEMA=$(echo "$LAST_LINE" | jq -r '.schema')
[[ "$EVENT" == "finding_finish" ]] || fail "case 7: event field wrong: $EVENT"
[[ "$REASON" == "fix verified" ]]  || fail "case 7: reason field wrong: $REASON"
[[ "$SCHEMA" == "v2" ]]            || fail "case 7: schema field wrong: $SCHEMA"
pass "finding-finish: emits finding_finish event with reason + schema=v2 to debates.jsonl"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# runner/lib/active-finding.sh accessors — v2 + v1 fallback
# ============================================================

info "[8] active_finding_present: true when v2 marker exists, false otherwise"
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

info "[9] active_finding_field reads v2 fields correctly"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R3-F5 .tdd/findings/R1-F1/red-proof.md --tier tier1 > /dev/null
(
  # shellcheck source=/dev/null
  . "$LIB"
  id=$(active_finding_field finding_id "$SANDBOX")
  tier=$(active_finding_field tier "$SANDBOX")
  phase=$(active_finding_field phase "$SANDBOX")
  ver=$(active_finding_schema_version "$SANDBOX")
  [[ "$id" == "R3-F5" ]]   || { echo "id wrong: $id" >&2; exit 1; }
  [[ "$tier" == "tier1" ]] || { echo "tier wrong: $tier" >&2; exit 1; }
  [[ "$phase" == "red" ]]  || { echo "phase wrong: $phase" >&2; exit 1; }
  [[ "$ver" == "2" ]]      || { echo "version wrong: $ver" >&2; exit 1; }
) || fail "case 9: v2 field accessor wrong"
pass "active_finding_field + active_finding_schema_version: read v2 fields correctly"
PASS_COUNT=$((PASS_COUNT+1))

info "[10] active_finding_red_proof_hash_matches: detects tampering on v2 marker"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R1-F1 .tdd/findings/R1-F1/red-proof.md > /dev/null
RECORDED=$(jq -r '.red_proof_hash' "$SANDBOX/${V2_PATH}")
echo "tampered content" >> "$SANDBOX/.tdd/findings/R1-F1/red-proof.md"
(
  # shellcheck source=/dev/null
  . "$LIB"
  CURRENT=$(active_finding_compute_red_proof_hash "$SANDBOX/.tdd/findings/R1-F1/red-proof.md")
  if active_finding_red_proof_hash_matches "$CURRENT" "$SANDBOX"; then
    echo "should NOT match — file was tampered after start" >&2
    exit 1
  fi
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

info "[11b] active_finding_validate_tier accepts tier1/2/3/untiered, rejects others"
(
  # shellcheck source=/dev/null
  . "$LIB"
  active_finding_validate_tier "tier1"    || { echo "tier1 should pass" >&2; exit 1; }
  active_finding_validate_tier "tier2"    || { echo "tier2 should pass" >&2; exit 1; }
  active_finding_validate_tier "tier3"    || { echo "tier3 should pass" >&2; exit 1; }
  active_finding_validate_tier "untiered" || { echo "untiered should pass" >&2; exit 1; }
  active_finding_validate_tier "tier4"    && { echo "tier4 should fail" >&2; exit 1; }
  active_finding_validate_tier ""         && { echo "empty should fail" >&2; exit 1; }
  exit 0
) || fail "case 11b: tier validation broken"
pass "active_finding_validate_tier: enforces v2 tier enum"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# hooks/protect-tdd-artifacts.sh — Gate 4 still covers BOTH paths
# ============================================================

info "[12] Gate 4 blocks direct Claude writes to legacy .tdd/active-finding"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
INPUT=$(jq -nc --arg t "Write" --arg f "$SANDBOX/.tdd/active-finding" --arg c "{}" \
  '{tool_name:$t, session_id:"s", tool_input:{file_path:$f, content:$c}}')
OUT=$(CLAUDE_PROJECT_DIR="$SANDBOX" bash "$PROTECT_HOOK" <<< "$INPUT" 2>/dev/null)
DEC=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty')
REASON=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')
[[ "$DEC" == "deny" ]] || fail "case 12: expected deny on legacy path, got: $DEC"
[[ "$REASON" == *"finding-start.sh"* ]] || fail "case 12: deny reason should point at finding-start.sh; got: $REASON"
pass "Gate 4: legacy .tdd/active-finding writes blocked"
PASS_COUNT=$((PASS_COUNT+1))

info "[12b] Gate 4 blocks direct Claude writes to v2 .tdd/findings/active.json"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
INPUT=$(jq -nc --arg t "Write" --arg f "$SANDBOX/.tdd/findings/active.json" --arg c "{}" \
  '{tool_name:$t, session_id:"s", tool_input:{file_path:$f, content:$c}}')
OUT=$(CLAUDE_PROJECT_DIR="$SANDBOX" bash "$PROTECT_HOOK" <<< "$INPUT" 2>/dev/null)
DEC=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty')
[[ "$DEC" == "deny" ]] || fail "case 12b: expected deny on v2 path, got: $DEC"
pass "Gate 4: v2 .tdd/findings/active.json writes blocked via PROTECTED_PREFIXES"
PASS_COUNT=$((PASS_COUNT+1))

# ---- summary ----

echo ""
echo "================================================================"
echo "  ACTIVE-FINDING SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
exit 0
