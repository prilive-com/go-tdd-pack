#!/usr/bin/env bash
# scripts/tdd/hash-review-scope.sh
#
# v1.9.0 Pack No-Discretion Second Opinion — deterministic scope-hash
# computation for the three review types. The hooks compute the scope
# hash to check whether a matching completion exists; the runner
# computes the same hash to bind the completion to the obligation.
# Identical inputs MUST produce identical hashes.
#
# Usage:
#   hash-review-scope.sh plan_review <cycle_id> <plan_path> <plan_content_hash>
#   hash-review-scope.sh test_review <cycle_id> <test_file_path> <package_files_hash>
#   hash-review-scope.sh production_edit <cycle_id> <base_git_sha> <tier_level>
#
# Output (stdout): lowercase hex sha256 of the canonical input string.
# Exit codes: 0 success, 2 usage error.

set -uo pipefail

usage() {
  echo "usage: $0 <review-type> <cycle_id> <arg2> <arg3>" >&2
  echo "  plan_review:     cycle_id plan_path plan_content_hash" >&2
  echo "  test_review:     cycle_id test_file_path package_files_hash" >&2
  echo "  production_edit: cycle_id base_git_sha tier_level" >&2
  exit 2
}

[[ $# -lt 4 ]] && usage

review_type="$1"
cycle_id="$2"
arg2="$3"
arg3="$4"

case "$review_type" in
  plan_review|test_review|production_edit) ;;
  *) echo "[hash-review-scope] unknown review-type: $review_type" >&2; exit 2 ;;
esac

[[ -z "$cycle_id" ]] && { echo "[hash-review-scope] cycle_id required" >&2; exit 2; }
[[ -z "$arg2" ]] && { echo "[hash-review-scope] arg2 required" >&2; exit 2; }
[[ -z "$arg3" ]] && { echo "[hash-review-scope] arg3 required" >&2; exit 2; }

# Canonical-form input: pipe-separated, ordered.
input="${review_type}|${cycle_id}|${arg2}|${arg3}"

if command -v sha256sum >/dev/null 2>&1; then
  printf '%s' "$input" | sha256sum | awk '{print $1}'
elif command -v shasum >/dev/null 2>&1; then
  printf '%s' "$input" | shasum -a 256 | awk '{print $1}'
else
  echo "[hash-review-scope] BLOCKED: neither sha256sum nor shasum available" >&2
  exit 2
fi
