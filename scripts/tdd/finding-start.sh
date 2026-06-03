#!/usr/bin/env bash
# scripts/tdd/finding-start.sh <finding-id> <red-proof-path>
#
# v2.1 PR 8 (foundation) — declare that you are about to apply a fix
# for a specific Codex finding, with the accepted Red proof. Writes
# .tdd/active-finding so Gate 1 (PR 8b) can verify the prod fix is
# tied to a real finding with a real Red test.
#
# Single-active rule: only one active finding at a time. If
# .tdd/active-finding already exists, the script refuses. Use
# finding-finish.sh to clear it before starting another.
#
# Usage:
#   scripts/tdd/finding-start.sh R2-F3 .tdd/findings/R2-F3/red-proof.md
#
# Exit codes:
#   0   marker written
#   2   invalid finding-id format
#   3   red-proof file missing
#   4   marker already exists (use finding-finish.sh first)
#   5   filesystem error writing marker

set -euo pipefail

usage() {
  echo "Usage: $0 <finding-id> <red-proof-path>" >&2
  echo "  finding-id    R<n>-F<n>  (e.g. R2-F3)" >&2
  echo "  red-proof     path to red-proof.md (project-relative or absolute)" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage

FINDING_ID="$1"
RED_PROOF_INPUT="$2"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# shellcheck source=../../runner/lib/active-finding.sh
. "${PROJECT_DIR}/runner/lib/active-finding.sh"

# Validate finding-id format.
if ! active_finding_validate_id "${FINDING_ID}"; then
  echo "finding-start: invalid finding-id '${FINDING_ID}' (expected R<n>-F<n>, e.g. R2-F3)" >&2
  exit 2
fi

# Resolve red-proof path. Accept either project-relative or absolute.
if [[ "${RED_PROOF_INPUT}" = /* ]]; then
  RED_PROOF_ABS="${RED_PROOF_INPUT}"
else
  RED_PROOF_ABS="${PROJECT_DIR}/${RED_PROOF_INPUT}"
fi
if [[ ! -f "${RED_PROOF_ABS}" ]]; then
  echo "finding-start: red-proof file not found: ${RED_PROOF_ABS}" >&2
  exit 3
fi

# Refuse if a finding is already active.
MARKER=$(active_finding_path "${PROJECT_DIR}")
if [[ -f "${MARKER}" ]]; then
  CURRENT_ID=$(active_finding_field finding_id "${PROJECT_DIR}" 2>/dev/null || echo "?")
  echo "finding-start: a finding is already active (${CURRENT_ID})." >&2
  echo "  Marker: ${MARKER}" >&2
  echo "  Use scripts/tdd/finding-finish.sh to clear it first." >&2
  exit 4
fi

# Compute red-proof hash.
HASH=$(active_finding_compute_red_proof_hash "${RED_PROOF_ABS}") || {
  echo "finding-start: failed to compute red-proof hash" >&2
  exit 5
}

# Normalize red_proof to project-relative for the marker.
RED_PROOF_REL="${RED_PROOF_ABS#"${PROJECT_DIR}/"}"

# Write marker atomically.
mkdir -p "$(dirname "${MARKER}")" 2>/dev/null
TS=$(date -u +%FT%TZ)
jq -n \
  --arg id "${FINDING_ID}" \
  --arg ts "${TS}" \
  --arg rp "${RED_PROOF_REL}" \
  --arg rh "${HASH}" \
  '{
    schema_version: 1,
    finding_id: $id,
    mode: "green_fix",
    started_at: $ts,
    red_proof: $rp,
    red_proof_hash: $rh
  }' \
  > "${MARKER}.tmp" || {
    echo "finding-start: failed to write marker" >&2
    exit 5
  }
mv "${MARKER}.tmp" "${MARKER}" || exit 5

echo "finding-start: ${FINDING_ID} active. Marker at ${MARKER}"
echo "  red_proof:      ${RED_PROOF_REL}"
echo "  red_proof_hash: ${HASH}"
exit 0
