#!/usr/bin/env bash
# List Go files changed vs base branch. Useful for narrow lint runs.
set -euo pipefail

base="${1:-main}"

git diff --name-only "$base"...HEAD -- '*.go' \
  | grep -v '^vendor/' \
  || true
