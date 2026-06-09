#!/usr/bin/env bash
# scripts/tdd/finding-finish.sh [--reason "<text>"]
#
# v2.1 PR 8     — cleared the v1 marker (.tdd/active-finding).
# v2.3 slice 1  — handles BOTH the v1 marker (rm only) and the v2
#                 marker (set phase=closed + closed_at, then rotate
#                 to .tdd/findings/closed/<finding_id>.json).
#                 Idempotent; safe to call when no marker exists.
#
# Future Gate 1 / Gate 3 stop applying once the marker is gone.
#
# Usage:
#   scripts/tdd/finding-finish.sh
#   scripts/tdd/finding-finish.sh --reason "abandoned: spec changed"
#
# Exit codes:
#   0  marker removed / rotated (or never existed — idempotent)
#   1  usage error
#   5  filesystem error during finish

set -euo pipefail

REASON=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reason)
      [[ $# -ge 2 ]] || { echo "finding-finish: --reason needs a value" >&2; exit 1; }
      REASON="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--reason \"<text>\"]" >&2
      exit 0
      ;;
    *)
      echo "finding-finish: unknown arg '$1'" >&2
      exit 1
      ;;
  esac
done

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# shellcheck source=../../runner/lib/active-finding.sh
. "${PROJECT_DIR}/runner/lib/active-finding.sh"

KIND=$(active_finding_kind "${PROJECT_DIR}")
if [[ "${KIND}" == "absent" ]]; then
  echo "finding-finish: no active finding (marker absent — already clear)"
  exit 0
fi

# Capture details for the audit log before mutating.
FINDING_ID=$(active_finding_field finding_id "${PROJECT_DIR}" 2>/dev/null || echo "?")
TS=$(date -u +%FT%TZ)

# Append a single-line event to debates.jsonl (engine-owned, so this
# write is the legitimate one — same engine path the rest of the
# runner uses). Include the schema kind so the audit trail records
# whether this was a v1 legacy clear or a v2 rotation.
DEBATES="${PROJECT_DIR}/.tdd/reviews/debates.jsonl"
mkdir -p "$(dirname "${DEBATES}")" 2>/dev/null
jq -nc \
  --arg ts "${TS}" \
  --arg id "${FINDING_ID}" \
  --arg kind "${KIND}" \
  --arg reason "${REASON}" \
  '{ts:$ts, event:"finding_finish", finding_id:$id, schema:$kind, reason:$reason}' \
  >> "${DEBATES}" 2>/dev/null || true

case "${KIND}" in
  v1)
    # Legacy v1 marker — no closed/ rotation concept in v1, just remove.
    LEGACY=$(active_finding_legacy_path "${PROJECT_DIR}")
    rm -f "${LEGACY}" || {
      echo "finding-finish: failed to remove legacy marker ${LEGACY}" >&2
      exit 5
    }
    echo "finding-finish: cleared ${FINDING_ID} (v1 legacy marker removed)"
    ;;
  v2)
    # v2 marker — set phase=closed + closed_at, then rotate to closed/.
    ACTIVE=$(active_finding_v2_path "${PROJECT_DIR}")
    CLOSED_DIR="${PROJECT_DIR}/.tdd/findings/closed"
    mkdir -p "${CLOSED_DIR}" 2>/dev/null
    CLOSED="${CLOSED_DIR}/${FINDING_ID}.json"

    # Update phase + closed_at in place via temp file (atomic rename).
    jq --arg ts "${TS}" \
       '.phase = "closed" | .closed_at = $ts' \
       "${ACTIVE}" > "${ACTIVE}.tmp" || {
         echo "finding-finish: failed to update marker phase" >&2
         exit 5
       }

    # Rotate: rename updated marker to closed/<id>.json.
    mv "${ACTIVE}.tmp" "${CLOSED}" || {
      echo "finding-finish: failed to rotate marker to ${CLOSED}" >&2
      exit 5
    }
    rm -f "${ACTIVE}" || {
      echo "finding-finish: rotated to ${CLOSED} but failed to remove ${ACTIVE}" >&2
      exit 5
    }
    echo "finding-finish: closed ${FINDING_ID} (v2). Rotated to ${CLOSED}"
    ;;
esac

[[ -n "${REASON}" ]] && echo "  reason: ${REASON}"
exit 0
