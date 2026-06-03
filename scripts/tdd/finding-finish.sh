#!/usr/bin/env bash
# scripts/tdd/finding-finish.sh
#
# v2.1 PR 8 (foundation) — clear the active-finding marker. Call after
# Claude's Green-phase fix is in and verified. Future Gate 1 / Gate 3
# stop applying once the marker is gone.
#
# Usage:
#   scripts/tdd/finding-finish.sh
#
# Optional: pass --reason "<text>" to record why the finding was
# finished (useful for audit when the fix was abandoned vs completed).
#
# Exit codes:
#   0  marker removed (or never existed — idempotent)
#   1  usage error
#   5  filesystem error removing marker

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

MARKER=$(active_finding_path "${PROJECT_DIR}")

if [[ ! -f "${MARKER}" ]]; then
  echo "finding-finish: no active finding (marker absent — already clear)"
  exit 0
fi

# Capture details for the audit log before removing.
FINDING_ID=$(active_finding_field finding_id "${PROJECT_DIR}" 2>/dev/null || echo "?")

# Append a single-line event to debates.jsonl (engine-owned, so this
# write is the legitimate one — same engine path the rest of the
# runner uses).
DEBATES="${PROJECT_DIR}/.tdd/reviews/debates.jsonl"
mkdir -p "$(dirname "${DEBATES}")" 2>/dev/null
TS=$(date -u +%FT%TZ)
jq -nc \
  --arg ts "${TS}" \
  --arg id "${FINDING_ID}" \
  --arg reason "${REASON}" \
  '{ts:$ts, event:"finding_finish", finding_id:$id, reason:$reason}' \
  >> "${DEBATES}" 2>/dev/null || true

rm -f "${MARKER}" || {
  echo "finding-finish: failed to remove marker ${MARKER}" >&2
  exit 5
}

echo "finding-finish: cleared ${FINDING_ID}"
[[ -n "${REASON}" ]] && echo "  reason: ${REASON}"
exit 0
