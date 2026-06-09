#!/usr/bin/env bash
# test/smoke-fdtdd-backward-compat.sh
#
# v2.3 slice 1 — verifies the v1 → v2 marker backward-compat read
# path documented in docs/FDTDD-MARKER-CONTRACT.md.
#
# Covers:
#   - A pre-existing v1 marker at .tdd/active-finding is readable
#     via active_finding_present + active_finding_field.
#   - active_finding_kind reports "v1" for legacy, "v2" for new,
#     "absent" for none.
#   - active_finding_phase returns "red" for v1 markers (conservative
#     default — v2.1-era markers had no mechanical Red proof).
#   - active_finding_red_proof_accepted returns "false" for v1.
#   - active_finding_test_files + active_finding_prod_files return
#     empty for v1.
#   - finding-finish.sh cleanly handles a v1 marker (no rotation).
#   - finding-start.sh refuses to write v2 while a v1 marker is
#     present (no silent overwrite, no migration without operator
#     intent).
#   - After v1 cleanup via finding-finish, finding-start writes a
#     fresh v2 marker.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
START="${PROJECT_ROOT}/scripts/tdd/finding-start.sh"
FINISH="${PROJECT_ROOT}/scripts/tdd/finding-finish.sh"
LIB="${PROJECT_ROOT}/runner/lib/active-finding.sh"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
PASS_COUNT=0

CLEANUP_PATHS=()
trap 'for p in "${CLEANUP_PATHS[@]}"; do [[ -n "$p" ]] && rm -rf "$p"; done' EXIT

make_sandbox() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.tdd/findings/R1-F1" "$d/.tdd/reviews" "$d/runner/lib" "$d/scripts/tdd"
  cp "${PROJECT_ROOT}/runner/lib/active-finding.sh" "$d/runner/lib/"
  cp "${START}" "$d/scripts/tdd/"
  cp "${FINISH}" "$d/scripts/tdd/"
  echo "# Red proof for finding R1-F1" > "$d/.tdd/findings/R1-F1/red-proof.md"
  echo "$d"
}

plant_v1_marker() {
  local sandbox="$1" id="$2"
  cat > "$sandbox/.tdd/active-finding" <<EOF
{
  "schema_version": 1,
  "finding_id": "$id",
  "mode": "green_fix",
  "started_at": "2026-06-08T10:00:00Z",
  "red_proof": ".tdd/findings/$id/red-proof.md",
  "red_proof_hash": "sha256:0000000000000000000000000000000000000000000000000000000000000000"
}
EOF
}

# ============================================================
# v1 marker readability
# ============================================================

info "[1] active_finding_kind reports v1/v2/absent correctly"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
(
  # shellcheck source=/dev/null
  . "$LIB"
  k=$(active_finding_kind "$SANDBOX")
  [[ "$k" == "absent" ]] || { echo "expected absent, got: $k" >&2; exit 1; }
) || fail "case 1a: absent state wrong"
plant_v1_marker "$SANDBOX" R7-F2
(
  # shellcheck source=/dev/null
  . "$LIB"
  k=$(active_finding_kind "$SANDBOX")
  [[ "$k" == "v1" ]] || { echo "expected v1, got: $k" >&2; exit 1; }
) || fail "case 1b: v1 state wrong"
rm "$SANDBOX/.tdd/active-finding"
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R8-F3 .tdd/findings/R1-F1/red-proof.md > /dev/null
(
  # shellcheck source=/dev/null
  . "$LIB"
  k=$(active_finding_kind "$SANDBOX")
  [[ "$k" == "v2" ]] || { echo "expected v2, got: $k" >&2; exit 1; }
) || fail "case 1c: v2 state wrong"
pass "active_finding_kind: returns absent/v1/v2 correctly across states"
PASS_COUNT=$((PASS_COUNT+1))

info "[2] active_finding_present + active_finding_field read v1 marker"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
plant_v1_marker "$SANDBOX" R7-F2
(
  # shellcheck source=/dev/null
  . "$LIB"
  active_finding_present "$SANDBOX" || { echo "present should be true" >&2; exit 1; }
  id=$(active_finding_field finding_id "$SANDBOX")
  ver=$(active_finding_schema_version "$SANDBOX")
  [[ "$id" == "R7-F2" ]] || { echo "id wrong: $id" >&2; exit 1; }
  [[ "$ver" == "1" ]]    || { echo "schema_version wrong: $ver" >&2; exit 1; }
) || fail "case 2: v1 marker not readable"
pass "v1 marker: present + field + schema_version readable"
PASS_COUNT=$((PASS_COUNT+1))

info "[3] v1 marker reads as phase=red (conservative default per contract)"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
plant_v1_marker "$SANDBOX" R7-F2
(
  # shellcheck source=/dev/null
  . "$LIB"
  phase=$(active_finding_phase "$SANDBOX")
  accepted=$(active_finding_red_proof_accepted "$SANDBOX")
  [[ "$phase" == "red" ]]      || { echo "phase wrong: $phase" >&2; exit 1; }
  [[ "$accepted" == "false" ]] || { echo "red_proof_accepted wrong: $accepted" >&2; exit 1; }
) || fail "case 3: v1 fallback defaults broken"
pass "v1 marker: phase=red, red_proof_accepted=false (conservative defaults)"
PASS_COUNT=$((PASS_COUNT+1))

info "[4] v1 marker reads as empty test_files + prod_files"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
plant_v1_marker "$SANDBOX" R7-F2
(
  # shellcheck source=/dev/null
  . "$LIB"
  tf=$(active_finding_test_files "$SANDBOX")
  pf=$(active_finding_prod_files "$SANDBOX")
  [[ -z "$tf" ]] || { echo "test_files should be empty for v1, got: $tf" >&2; exit 1; }
  [[ -z "$pf" ]] || { echo "prod_files should be empty for v1, got: $pf" >&2; exit 1; }
) || fail "case 4: v1 file-list defaults broken"
pass "v1 marker: test_files + prod_files empty (per contract)"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# finding-finish handles v1 marker
# ============================================================

info "[5] finding-finish removes v1 marker without creating closed/"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
plant_v1_marker "$SANDBOX" R7-F2
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$FINISH" --reason "upgraded to v2.3" > /dev/null
[[ ! -f "$SANDBOX/.tdd/active-finding" ]] || fail "case 5: v1 marker should be removed"
[[ ! -d "$SANDBOX/.tdd/findings/closed" ]] || fail "case 5: closed/ should NOT exist after v1 finish"
DEBATES="$SANDBOX/.tdd/reviews/debates.jsonl"
[[ -f "$DEBATES" ]] || fail "case 5: debates.jsonl not written"
SCHEMA_LOGGED=$(jq -r '.schema' < "$DEBATES")
[[ "$SCHEMA_LOGGED" == "v1" ]] || fail "case 5: audit should record schema=v1; got $SCHEMA_LOGGED"
pass "finding-finish: v1 marker removed; audit records schema=v1; no closed/ created"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# finding-start refuses to overwrite a v1 marker
# ============================================================

info "[6] finding-start with v1 marker present refuses (exit 4); no silent migration"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
plant_v1_marker "$SANDBOX" R7-F2
set +e
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R1-F1 .tdd/findings/R1-F1/red-proof.md 2>/dev/null
RC=$?
set -e
[[ $RC -eq 4 ]] || fail "case 6: expected exit 4, got: $RC"
# Both paths preserved in their original state.
[[ -f "$SANDBOX/.tdd/active-finding" ]] || fail "case 6: v1 marker should be untouched"
[[ ! -f "$SANDBOX/.tdd/findings/active.json" ]] || fail "case 6: v2 marker should NOT be written"
ORIG_ID=$(jq -r '.finding_id' "$SANDBOX/.tdd/active-finding")
[[ "$ORIG_ID" == "R7-F2" ]] || fail "case 6: v1 marker mutated; got id $ORIG_ID"
pass "finding-start: refuses with exit 4 against v1 marker; no silent migration"
PASS_COUNT=$((PASS_COUNT+1))

info "[7] After finding-finish on v1, finding-start writes v2 cleanly"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
plant_v1_marker "$SANDBOX" R7-F2
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$FINISH" > /dev/null
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R1-F1 .tdd/findings/R1-F1/red-proof.md > /dev/null
[[ -f "$SANDBOX/.tdd/findings/active.json" ]] || fail "case 7: v2 marker not written"
[[ ! -f "$SANDBOX/.tdd/active-finding" ]] || fail "case 7: legacy path should remain absent"
NEW_VER=$(jq -r '.schema_version' "$SANDBOX/.tdd/findings/active.json")
[[ "$NEW_VER" == "2" ]] || fail "case 7: new marker should be v2; got $NEW_VER"
pass "Full v1→v2 path: finish v1 → start writes fresh v2 marker"
PASS_COUNT=$((PASS_COUNT+1))

# ---- summary ----

echo ""
echo "================================================================"
echo "  FDTDD BACKWARD-COMPAT SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
exit 0
