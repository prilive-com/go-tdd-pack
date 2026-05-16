#!/usr/bin/env bash
# runner/extract-verdict.sh <round-text-file>
#
# Parses Codex's free-form round-N output for a VERDICT: line.
# Outputs one of: approve | request_changes | unclear
# Exit 0 always — caller decides what to do with "unclear".

set -uo pipefail

FILE="$1"

if [[ ! -f "${FILE}" ]]; then
  echo "unclear"
  exit 0
fi

# Look for VERDICT: ... in the last 30 lines, case-insensitive.
# Codex may add markdown formatting (e.g., **VERDICT:** or ```VERDICT...).
# Be tolerant.
VERDICT_LINE=$(
  tail -30 "${FILE}" \
    | grep -iE '(^|[[:space:]\*`>])VERDICT[[:space:]]*:' \
    | tail -1 || true
)

if [[ -z "${VERDICT_LINE}" ]]; then
  echo "unclear"
  exit 0
fi

# Normalize and classify.
if echo "${VERDICT_LINE}" | grep -iqE '\bAPPROVE\b'; then
  echo "approve"
elif echo "${VERDICT_LINE}" | grep -iqE 'REQUEST.?CHANGES|REVISE|REJECT|CHANGES.REQUESTED'; then
  echo "request_changes"
else
  echo "unclear"
fi

exit 0
