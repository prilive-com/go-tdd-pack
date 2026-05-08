#!/usr/bin/env bash
# Run deadcode. Advisory by default — set DEADCODE_ALLOW_FAILURE=false to hard-fail.
set -euo pipefail
if ! command -v deadcode >/dev/null 2>&1; then
  echo "deadcode not installed — skipping"
  exit 0
fi
deadcode ./... | tee /tmp/deadcode.txt
if [ -s /tmp/deadcode.txt ]; then
  if [ "${DEADCODE_ALLOW_FAILURE:-true}" = "true" ]; then
    echo "deadcode: findings present (advisory; set DEADCODE_ALLOW_FAILURE=false to hard-fail)"
    exit 0
  fi
  echo "deadcode: findings present and DEADCODE_ALLOW_FAILURE=false; failing."
  exit 1
fi
