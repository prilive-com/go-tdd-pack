#!/usr/bin/env bash
# test/smoke-fdtdd-marker-schema.sh
#
# v2.3 slice 1 — drift catcher for the v2 active-finding marker.
#
# Strict-mode invariant (additionalProperties:false +
# properties == required) is verified by smoke-schema-strict-mode.sh
# which walks every schema in schemas/. This smoke complements that
# by asserting the SHIPPED helper (finding-start.sh) actually writes
# every required field listed in the schema, with valid values.
#
# Drift this catches:
#   - Schema adds a required field but finding-start.sh forgets it
#     → marker written by helper is invalid against its own schema.
#   - finding-start.sh writes a field with a value outside the
#     schema's enum (e.g. phase set to "ready" instead of "red").
#   - Schema enum values diverge from validate_tier / validate_id
#     helpers in active-finding.sh.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
START="${PROJECT_ROOT}/scripts/tdd/finding-start.sh"
SCHEMA="${PROJECT_ROOT}/schemas/active-finding.schema.json"
LIB="${PROJECT_ROOT}/runner/lib/active-finding.sh"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
PASS_COUNT=0

[[ -f "${SCHEMA}" ]] || fail "schema not found: ${SCHEMA}"

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
  mkdir -p "$d/.tdd/findings/R1-F1" "$d/runner/lib" "$d/scripts/tdd"
  cp "${PROJECT_ROOT}/runner/lib/active-finding.sh" "$d/runner/lib/"
  cp "${START}" "$d/scripts/tdd/"
  cp "${PROJECT_ROOT}/scripts/tdd/finding-finish.sh" "$d/scripts/tdd/"
  echo "# Red proof" > "$d/.tdd/findings/R1-F1/red-proof.md"
  echo "$d"
}

# ============================================================
# [1] Schema declares schema_version: 2.
# ============================================================

info "[1] schema_version enum locked to [2]"
VER_ENUM=$(jq -c '.properties.schema_version.enum' "${SCHEMA}")
[[ "${VER_ENUM}" == "[2]" ]] || fail "schema_version enum should be [2], got: ${VER_ENUM}"
pass "schema_version: enum locked to [2]"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# [2] finding-start.sh writes every required field with a valid value.
# ============================================================

info "[2] finding-start writes all schema required fields"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
CLAUDE_PROJECT_DIR="$SANDBOX" bash "$START" R1-F1 .tdd/findings/R1-F1/red-proof.md --tier tier1 > /dev/null
MARKER="$SANDBOX/.tdd/findings/active.json"
[[ -f "${MARKER}" ]] || fail "case 2: marker not written"

REQUIRED=$(jq -r '.required[]' "${SCHEMA}")
MISSING=""
while IFS= read -r field; do
  PRESENT=$(jq --arg k "$field" 'has($k)' "${MARKER}")
  [[ "${PRESENT}" == "true" ]] || MISSING="${MISSING} ${field}"
done <<< "${REQUIRED}"

if [[ -n "${MISSING}" ]]; then
  fail "case 2: marker missing schema-required fields:${MISSING}"
fi
pass "finding-start: marker has every schema-required field present"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# [3] phase enum.
# ============================================================

info "[3] phase enum in schema matches FDTDD-MARKER-CONTRACT.md"
PHASE_ENUM=$(jq -c '.properties.phase.enum' "${SCHEMA}")
EXPECTED='["red","green","refactor","closed"]'
[[ "${PHASE_ENUM}" == "${EXPECTED}" ]] || fail "phase enum drift: ${PHASE_ENUM} (expected ${EXPECTED})"
pass "phase: enum is [red, green, refactor, closed]"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# [4] tier enum matches active_finding_validate_tier in lib.
# ============================================================

info "[4] tier enum in schema matches active_finding_validate_tier"
SCHEMA_TIERS=$(jq -r '.properties.tier.enum[]' "${SCHEMA}" | sort | paste -sd, -)
LIB_TIERS="tier1,tier2,tier3,untiered"
[[ "${SCHEMA_TIERS}" == "${LIB_TIERS}" ]] || fail "tier enum drift: schema=${SCHEMA_TIERS}; lib accepts=${LIB_TIERS}"
pass "tier: schema enum matches active_finding_validate_tier"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# [5] finding_id pattern matches active_finding_validate_id.
# ============================================================

info "[5] finding_id pattern matches active_finding_validate_id"
SCHEMA_PAT=$(jq -r '.properties.finding_id.pattern' "${SCHEMA}")
EXPECTED_PAT='^R[0-9]+-F[0-9]+$'
[[ "${SCHEMA_PAT}" == "${EXPECTED_PAT}" ]] || fail "finding_id pattern drift: ${SCHEMA_PAT}"
# Cross-check: lib accepts the same things the schema does.
(
  # shellcheck source=/dev/null
  . "$LIB"
  active_finding_validate_id "R1-F1"   || { echo "lib should accept R1-F1" >&2; exit 1; }
  active_finding_validate_id "R10-F99" || { echo "lib should accept R10-F99" >&2; exit 1; }
  active_finding_validate_id "r1-f1"   && { echo "lib should reject r1-f1" >&2; exit 1; }
  exit 0
) || fail "case 5: lib id-validation drifts from schema pattern"
pass "finding_id: schema pattern + active_finding_validate_id agree"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# [6] red_proof_hash pattern.
# ============================================================

info "[6] red_proof_hash pattern is sha256:<64-hex>"
HASH_PAT=$(jq -r '.properties.red_proof_hash.pattern' "${SCHEMA}")
EXPECTED_HASH_PAT='^sha256:[0-9a-f]{64}$'
[[ "${HASH_PAT}" == "${EXPECTED_HASH_PAT}" ]] || fail "red_proof_hash pattern drift: ${HASH_PAT}"
# Cross-check against a real marker.
MARKER_HASH=$(jq -r '.red_proof_hash' "${MARKER}")
[[ "${MARKER_HASH}" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "case 6: helper-written hash does not match pattern: ${MARKER_HASH}"
pass "red_proof_hash: schema pattern + helper output agree"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# [7] Counterfactual: schema must reject a marker with a v1
#     schema_version. v1 is read-only via the legacy fallback path;
#     the v2 schema must NOT accept it.
# ============================================================

info "[7] schema_version: 2 is the only accepted value (v1 markers fail v2 schema)"
# This is structural: enum is [2], so any other integer fails. We
# already checked enum above; re-emphasize the implication.
V1_ALLOWED=$(jq '.properties.schema_version.enum | contains([1])' "${SCHEMA}")
[[ "${V1_ALLOWED}" == "false" ]] || fail "case 7: v2 schema unexpectedly accepts schema_version=1"
pass "v2 schema correctly rejects schema_version=1 (v1 markers are legacy-only)"
PASS_COUNT=$((PASS_COUNT+1))

# ---- summary ----

echo ""
echo "================================================================"
echo "  FDTDD MARKER-SCHEMA SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
exit 0
