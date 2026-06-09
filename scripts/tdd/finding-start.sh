#!/usr/bin/env bash
# scripts/tdd/finding-start.sh <finding-id> <red-proof-path> [--tier <tier>]
#
# v2.1 PR 8 — declared an active finding with a Red proof (v1 schema
#             at .tdd/active-finding).
# v2.3 slice 1 — writes the v2 marker at .tdd/findings/active.json
#                with the extended schema. Silent migration: if a v1
#                marker exists, the script refuses with a clear pointer
#                to finding-finish.sh; once the v1 marker is gone, the
#                next finding-start writes to the v2 path.
#
# Single-active rule: only one active finding at a time. If a v1 OR
# v2 marker is present, the script refuses. Use finding-finish.sh to
# clear it before starting another.
#
# Usage:
#   scripts/tdd/finding-start.sh R2-F3 .tdd/findings/R2-F3/red-proof.md
#   scripts/tdd/finding-start.sh R2-F3 .tdd/findings/R2-F3/red-proof.md --tier tier1
#
# Exit codes:
#   0   v2 marker written
#   1   usage error
#   2   invalid finding-id format
#   3   red-proof file missing
#   4   marker already exists (use finding-finish.sh first)
#   5   filesystem error writing marker
#   6   invalid --tier value

set -euo pipefail

usage() {
  echo "Usage: $0 <finding-id> <red-proof-path> [--tier <tier1|tier2|tier3|untiered>]" >&2
  echo "  finding-id    R<n>-F<n>  (e.g. R2-F3)" >&2
  echo "  red-proof     path to red-proof.md (project-relative or absolute)" >&2
  echo "  --tier        FDTDD tier classification (default: untiered)" >&2
  exit 1
}

[[ $# -ge 2 ]] || usage

FINDING_ID="$1"
RED_PROOF_INPUT="$2"
shift 2

TIER="untiered"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier)
      [[ $# -ge 2 ]] || { echo "finding-start: --tier needs a value" >&2; exit 1; }
      TIER="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "finding-start: unknown arg '$1'" >&2
      usage
      ;;
  esac
done

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# shellcheck source=../../runner/lib/active-finding.sh
. "${PROJECT_DIR}/runner/lib/active-finding.sh"

# Validate finding-id format.
if ! active_finding_validate_id "${FINDING_ID}"; then
  echo "finding-start: invalid finding-id '${FINDING_ID}' (expected R<n>-F<n>, e.g. R2-F3)" >&2
  exit 2
fi

# Validate tier.
if ! active_finding_validate_tier "${TIER}"; then
  echo "finding-start: invalid --tier '${TIER}' (expected tier1|tier2|tier3|untiered)" >&2
  exit 6
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

# Refuse if any marker (v1 or v2) is already active.
KIND=$(active_finding_kind "${PROJECT_DIR}")
if [[ "${KIND}" != "absent" ]]; then
  CURRENT_PATH=$(active_finding_path "${PROJECT_DIR}")
  CURRENT_ID=$(active_finding_field finding_id "${PROJECT_DIR}" 2>/dev/null || echo "?")
  echo "finding-start: a finding is already active (${CURRENT_ID}, ${KIND} schema)." >&2
  echo "  Marker: ${CURRENT_PATH}" >&2
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

# Write the v2 marker atomically.
MARKER=$(active_finding_v2_path "${PROJECT_DIR}")
mkdir -p "$(dirname "${MARKER}")" 2>/dev/null
TS=$(date -u +%FT%TZ)
jq -n \
  --arg id "${FINDING_ID}" \
  --arg ts "${TS}" \
  --arg tier "${TIER}" \
  --arg rp "${RED_PROOF_REL}" \
  --arg rh "${HASH}" \
  '{
    schema_version:     2,
    finding_id:         $id,
    started_at:         $ts,
    tier:               $tier,
    phase:              "red",
    red_proof:          $rp,
    red_proof_hash:     $rh,
    red_proof_accepted: false,
    red_proof_record:   null,
    test_files:         [],
    prod_files:         [],
    red_accepted_at:    null,
    green_started_at:   null,
    closed_at:          null,
    amendments:         []
  }' \
  > "${MARKER}.tmp" || {
    echo "finding-start: failed to write marker" >&2
    exit 5
  }
mv "${MARKER}.tmp" "${MARKER}" || exit 5

echo "finding-start: ${FINDING_ID} active (v2 schema). Marker at ${MARKER}"
echo "  tier:           ${TIER}"
echo "  phase:          red"
echo "  red_proof:      ${RED_PROOF_REL}"
echo "  red_proof_hash: ${HASH}"
exit 0
