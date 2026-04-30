#!/usr/bin/env bash
set -euo pipefail
if ! command -v deadcode >/dev/null 2>&1; then
  echo "deadcode not installed — skipping"
  exit 0
fi
deadcode ./... | tee /tmp/deadcode.txt
test ! -s /tmp/deadcode.txt
