#!/usr/bin/env bash
# runner/coalesce.sh — block until the working tree has been quiet for $WAIT_MS.
#
# Uses mtime on a touch file as the "last activity" marker. The runner touches
# this file at start; if another runner instance starts during the wait, it
# touches again, extending the window. Only the last runner survives.
#
# Single-flight via flock is handled by review-runner.sh (separate concern).
#
# Usage: coalesce.sh <project_dir> [wait_ms]

set -uo pipefail

PROJECT_DIR="$1"
WAIT_MS="${2:-5000}"
TOUCH_FILE="${PROJECT_DIR}/.tdd/.last-edit"

mkdir -p "$(dirname "${TOUCH_FILE}")"
touch "${TOUCH_FILE}"

# Convert ms to seconds for sleep.
WAIT_SECONDS=$(awk -v ms="${WAIT_MS}" 'BEGIN { printf "%.3f", ms/1000 }')

while true; do
  # GNU stat (Linux) uses -c %Y; BSD stat (macOS) uses -f %m.
  before=$(stat -f %m "${TOUCH_FILE}" 2>/dev/null || stat -c %Y "${TOUCH_FILE}")
  sleep "${WAIT_SECONDS}"
  after=$(stat -f %m "${TOUCH_FILE}" 2>/dev/null || stat -c %Y "${TOUCH_FILE}")
  if [[ "$before" == "$after" ]]; then
    break
  fi
done
