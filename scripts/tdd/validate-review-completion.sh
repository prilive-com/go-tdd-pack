#!/usr/bin/env bash
# scripts/tdd/validate-review-completion.sh
#
# v1.9.0 — Validate a review-completion entry against schema, binding,
# SHA-chain continuity. Used by the runner after Codex returns and by
# the hooks at obligation lookup time.
#
# Usage:
#   validate-review-completion.sh --type <review_type> --completion <path/to/completion.json>
#     [--scope-hash <hash>] [--audit-log <path>] [--strict]
#
# Exit codes:
#   0 valid
#   1 invalid (one or more checks failed; reasons on stderr)
#   2 hard error (missing jq, malformed input, missing files)

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "[validate-review-completion] BLOCKED: jq required." >&2
  exit 2
fi

review_type=""
completion=""
scope_hash=""
audit_log=""
strict=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) review_type="${2:-}"; shift 2 ;;
    --completion) completion="${2:-}"; shift 2 ;;
    --scope-hash) scope_hash="${2:-}"; shift 2 ;;
    --audit-log) audit_log="${2:-}"; shift 2 ;;
    --strict) strict=1; shift ;;
    *) shift ;;
  esac
done

if [[ -z "$review_type" ]] || [[ -z "$completion" ]]; then
  echo "[validate-review-completion] usage error" >&2
  exit 2
fi
if [[ ! -f "$completion" ]]; then
  echo "[validate-review-completion] completion file not found: $completion" >&2
  exit 2
fi
if ! jq -e . "$completion" >/dev/null 2>&1; then
  echo "[validate-review-completion] completion is not valid JSON" >&2
  exit 2
fi

# 1) review_type matches.
file_type=$(jq -r '.review_type // ""' "$completion")
if [[ "$file_type" != "$review_type" ]]; then
  echo "[validate-review-completion] REVIEW_TYPE_MISMATCH: expected $review_type, got $file_type" >&2
  exit 1
fi

# 2) scope_hash matches (if provided).
if [[ -n "$scope_hash" ]]; then
  file_scope=$(jq -r '.scope_hash // ""' "$completion")
  if [[ "$file_scope" != "$scope_hash" ]]; then
    echo "[validate-review-completion] REVIEW_SCOPE_MISMATCH: expected $scope_hash, got $file_scope" >&2
    exit 1
  fi
fi

# 3) Required top-level fields per schema.
for field in cycle_id verdict findings required_actions; do
  if ! jq -e --arg f "$field" 'has($f)' "$completion" >/dev/null 2>&1; then
    echo "[validate-review-completion] missing required field: $field" >&2
    exit 1
  fi
done

# 4) Verdict enum.
verdict=$(jq -r '.verdict' "$completion")
case "$verdict" in
  approve|approve_with_changes|block) ;;
  *) echo "[validate-review-completion] invalid verdict: $verdict" >&2; exit 1 ;;
esac

# 5) P0/P1 unresolved → reject (block-on-unresolved).
p0_unresolved=$(jq '[.findings[]? | select(.severity == "P0")] | length' "$completion")
p1_unresolved=$(jq '[.findings[]? | select(.severity == "P1")] | length' "$completion")
if [[ "$strict" -eq 1 ]] && [[ "$verdict" != "approve_with_changes" ]] && (( p0_unresolved > 0 || p1_unresolved > 0 )); then
  echo "[validate-review-completion] unresolved P0=$p0_unresolved P1=$p1_unresolved findings" >&2
  exit 1
fi

# 6) Audit chain continuity (if --audit-log provided).
if [[ -n "$audit_log" ]]; then
  if [[ ! -f "$audit_log" ]]; then
    echo "[validate-review-completion] audit-log not found: $audit_log" >&2
    exit 1
  fi
  prev_audit_sha=$(jq -r '.prev_audit_sha // empty' "$completion")
  if [[ -n "$prev_audit_sha" ]]; then
    last_line=$(tail -1 "$audit_log" 2>/dev/null || true)
    if [[ -n "$last_line" ]]; then
      if command -v sha256sum >/dev/null 2>&1; then
        actual_last=$(printf '%s' "$last_line" | sha256sum | awk '{print $1}')
      else
        actual_last=$(printf '%s' "$last_line" | shasum -a 256 | awk '{print $1}')
      fi
      if [[ "$prev_audit_sha" != "$actual_last" ]]; then
        echo "[validate-review-completion] audit chain mismatch: completion.prev_audit_sha=$prev_audit_sha, log tail sha=$actual_last" >&2
        exit 1
      fi
    fi
  fi
fi

exit 0
