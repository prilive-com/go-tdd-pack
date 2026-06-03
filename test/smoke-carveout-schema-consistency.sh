#!/usr/bin/env bash
# test/smoke-carveout-schema-consistency.sh
#
# v2.1 release guard (Blocker 4). The Rail A never-demote carve-out in
# hooks/inject-findings.sh and the round-1 schema category enum drifted:
# the engine carved out categories the schema can't emit (safety,
# data_loss, blast_radius) AND the schema told Codex maintainability was
# never-demote while the engine would demote it.
#
# This test asserts the two can never disagree again:
#   1. Every token in NEVER_DEMOTE_CATEGORIES is a member of the round-1
#      schema's category enum (no phantom carve-outs).
#   2. The schema's contradicts_grounding description does NOT list
#      'maintainability' as never-set (it is demotable).

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="${PROJECT_ROOT}/hooks/inject-findings.sh"
SCHEMA="${PROJECT_ROOT}/schemas/findings-round1.schema.json"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
PASS_COUNT=0

command -v jq >/dev/null 2>&1 || fail "jq required"

# Extract the carve-out list from the engine (the value between quotes).
info "[1] every carve-out category exists in the round-1 schema enum"
CARVEOUT=$(grep -E "^NEVER_DEMOTE_CATEGORIES=" "${ENGINE}" \
  | sed -E "s/^NEVER_DEMOTE_CATEGORIES='([^']*)'.*/\1/")
[[ -n "${CARVEOUT}" ]] || fail "could not read NEVER_DEMOTE_CATEGORIES from ${ENGINE}"

# Schema category enum as a newline list.
ENUM=$(jq -r '
  .properties.findings.items.properties.category.enum[]
' "${SCHEMA}" 2>/dev/null)
[[ -n "${ENUM}" ]] || fail "could not read category enum from ${SCHEMA}"

IFS='|' read -ra CATS <<< "${CARVEOUT}"
for c in "${CATS[@]}"; do
  if ! grep -qx "${c}" <<< "${ENUM}"; then
    fail "carve-out category '${c}' is NOT in the schema enum — phantom carve-out (would be dead code now, a trap later)"
  fi
done
pass "carve-out ⊆ schema enum (${#CATS[@]} categories: ${CARVEOUT})"
PASS_COUNT=$((PASS_COUNT+1))

# The reconciled release list is exactly these four. If someone widens the
# carve-out, this forces a deliberate test update rather than silent drift.
info "[2] carve-out is exactly the reconciled semantic set"
EXPECTED="correctness|design|test_quality|security"
[[ "${CARVEOUT}" == "${EXPECTED}" ]] \
  || fail "carve-out is '${CARVEOUT}', expected '${EXPECTED}' (widening the carve-out weakens the gate — update this test only with a deliberate decision)"
pass "carve-out == reconciled semantic set"
PASS_COUNT=$((PASS_COUNT+1))

info "[3] schema does NOT tell Codex maintainability is never-demote"
DESC=$(jq -r '
  .properties.findings.items.properties.contradicts_grounding.description
' "${SCHEMA}" 2>/dev/null)
if grep -qi "maintainability (semantic)" <<< "${DESC}"; then
  fail "schema still lists 'maintainability (semantic)' as NEVER-set; engine will demote it → reviewer/engine disagreement"
fi
pass "schema contradicts_grounding description and engine carve-out agree on maintainability"
PASS_COUNT=$((PASS_COUNT+1))

echo ""
echo "================================================================"
echo "  CARVE-OUT / SCHEMA CONSISTENCY SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
exit 0
