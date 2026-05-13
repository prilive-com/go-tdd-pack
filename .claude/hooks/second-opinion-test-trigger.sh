#!/usr/bin/env bash
# .claude/hooks/second-opinion-test-trigger.sh
#
# v1.9.0 — PreToolUse hook. Fires on Edit/Write/MultiEdit of *_test.go.
# Skip-through threshold: pure mechanical_signature_propagation /
# import_only diffs already covered by v1.7.0 typed exceptions.
# Otherwise: deny unless matching test_review_completion exists.
#
# Stable error code: TEST_REVIEW_REQUIRED.

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "[second-opinion-test-trigger] BLOCKED: jq required." >&2
  exit 2
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CONFIG="$PROJECT_DIR/.tdd/tdd-config.json"
PLAN="$PROJECT_DIR/.tdd/current-plan.md"
ARTIFACT="$PROJECT_DIR/.tdd/exceptions/post-red-test-edits.json"
HASH_SCOPE="$(dirname -- "${BASH_SOURCE[0]}")/../../scripts/tdd/hash-review-scope.sh"

[[ ! -f "$CONFIG" ]] && exit 0
enabled="$(jq -r '.second_opinion.no_discretion.enabled // false' "$CONFIG" 2>/dev/null || echo false)"
test_required="$(jq -r '.second_opinion.no_discretion.required_for.test_writes // false' "$CONFIG" 2>/dev/null || echo false)"
[[ "$enabled" != "true" ]] && exit 0
[[ "$test_required" != "true" ]] && exit 0

PAYLOAD="$(cat)"
if ! printf '%s' "$PAYLOAD" | jq -e . >/dev/null 2>&1; then
  echo "[second-opinion-test-trigger] BLOCKED: malformed JSON input — fail closed." >&2
  exit 2
fi
tool_name="$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""')"
case "$tool_name" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

file_path="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_input.path // ""' 2>/dev/null || echo "")"
[[ -z "$file_path" ]] && exit 0

# Path filter: only *_test.go.
case "$file_path" in
  *_test.go) ;;
  *) exit 0 ;;
esac

# Proposed content hash (v1.9.0 round-2 F3: include in scope binding
# so the same test file's later/different content doesn't reuse a
# stale completion).
proposed_content="$(printf '%s' "$PAYLOAD" | jq -r '
  if .tool_input.content then .tool_input.content
  elif .tool_input.new_string then (.tool_input.old_string // "") + "\n---REPLACED_BY---\n" + (.tool_input.new_string // "")
  elif (.tool_input.edits // []) | length > 0 then
    [.tool_input.edits[] | (.old_string // "") + "\n---REPLACED_BY---\n" + (.new_string // "")] | join("\n---NEXT_EDIT---\n")
  else "" end
' 2>/dev/null || echo "")"
if command -v sha256sum >/dev/null 2>&1; then
  proposed_content_hash="$(printf '%s' "$proposed_content" | sha256sum | awk '{print $1}')"
else
  proposed_content_hash="$(printf '%s' "$proposed_content" | shasum -a 256 | awk '{print $1}')"
fi

# Cycle ID.
cycle_id="$( { grep -E '^Cycle ID:' "$PLAN" 2>/dev/null || true; } | head -1 | sed -E 's/^Cycle ID:[[:space:]]*//')"
[[ -z "$cycle_id" ]] && cycle_id="unknown-cycle"

# Package files hash: all *.go files in the same package dir.
pkg_dir="$(dirname -- "$PROJECT_DIR/$file_path")"
if [[ -d "$pkg_dir" ]]; then
  pkg_hash="$(find "$pkg_dir" -maxdepth 1 -name '*.go' -type f 2>/dev/null | sort | xargs -r cat 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}')"
else
  pkg_hash="(no-pkg-dir)"
fi
[[ -z "$pkg_hash" ]] && pkg_hash="(empty)"

# scope_hash = sha256(test_review|cycle_id|file_path|pkg_hash+content_hash).
# v1.9.0 round-2 F3: composite of pkg+proposed_content ensures
# different proposed test content produces a different scope_hash.
composite_arg="${pkg_hash}|${proposed_content_hash}"
if [[ -x "$HASH_SCOPE" ]]; then
  scope_hash="$(bash "$HASH_SCOPE" test_review "$cycle_id" "$file_path" "$composite_arg" 2>/dev/null || echo "")"
else
  scope_hash="$(printf 'test_review|%s|%s|%s' "$cycle_id" "$file_path" "$composite_arg" | sha256sum | awk '{print $1}')"
fi

# F4 fix: AUDIT_LOG must be defined BEFORE the mechanical skip-through
# uses it (under `set -u` an unset var would abort the script).
AUDIT_LOG="$PROJECT_DIR/.tdd/audit/${cycle_id}.jsonl"

# v1.9.0 round-6 F3: REMOVED mechanical skip-through. Building a
# proper unified diff from old/new strings is non-trivial and the
# previous skip-through could be fooled. The v1.7.0 typed-exception
# system continues to gate test edits at the COMMIT level via
# require-tdd-state.sh + gate-tier1-commit.sh; v1.9.0's test trigger
# requires its own test_review_completion at EDIT time. Both layers
# protect different points in the flow.

# F2: audit-chain validation helper. AUDIT_LOG already defined above
# (early so the mechanical skip-through can use it).
chain_has() {
  local target="$1"
  [[ -z "$target" ]] && return 1
  [[ ! -s "$AUDIT_LOG" ]] && return 1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local line_sha
    if command -v sha256sum >/dev/null 2>&1; then
      line_sha=$(printf '%s' "$line" | sha256sum | awk '{print $1}')
    else
      line_sha=$(printf '%s' "$line" | shasum -a 256 | awk '{print $1}')
    fi
    [[ "$line_sha" == "$target" ]] && return 0
  done < "$AUDIT_LOG"
  return 1
}

# Lookup matching test_review_completion with audit-chain validation.
matched=false
if [[ -f "$ARTIFACT" ]]; then
  candidates=$(jq -c --arg cid "$cycle_id" --arg sh "$scope_hash" '
    [.exceptions[]?
     | select(.type == "test_review_completion")
     | select(.binding.cycle_id == $cid)
     | select(.binding.scope_hash == $sh)
     | select(.status == "approved")
    ]
  ' "$ARTIFACT" 2>/dev/null || echo "[]")
  n=$(printf '%s' "$candidates" | jq 'length' 2>/dev/null || echo 0)
  if [[ "$n" -gt 0 ]]; then
    # F4: require runner-written audit event referencing the
    # candidate's id; forged direct edits without audit entry fail.
    for i in $(seq 0 $((n - 1))); do
      candidate_id=$(printf '%s' "$candidates" | jq -r --argjson i "$i" '.[$i].id // ""')
      stored_prev=$(printf '%s' "$candidates" | jq -r --argjson i "$i" '.[$i].binding.prev_audit_sha // ""')
      [[ ! -s "$AUDIT_LOG" ]] && continue
      grep -qF "\"exception_id\":\"$candidate_id\"" "$AUDIT_LOG" || continue
      if [[ -n "$stored_prev" ]] && ! chain_has "$stored_prev"; then
        continue
      fi
      matched=true; break
    done
  fi
fi

if [[ "$matched" == "true" ]]; then
  jq -n '{}'
  exit 0
fi

# F1+F5: record pending obligation before denying.
mkdir -p "$(dirname "$ARTIFACT")" "$(dirname "$AUDIT_LOG")"
[[ -f "$ARTIFACT" ]] || printf '%s\n' "{\"version\":1,\"cycle_id\":\"$cycle_id\",\"phase\":\"red_confirmed\",\"expires\":\"next_green_commit\",\"exceptions\":[]}" > "$ARTIFACT"
already_pending=$(jq -r --arg cid "$cycle_id" --arg sh "$scope_hash" '
  [.exceptions[]?
   | select(.type == "test_review_completion")
   | select(.binding.cycle_id == $cid)
   | select(.binding.scope_hash == $sh)
   | select(.status == "pending")] | length > 0
' "$ARTIFACT" 2>/dev/null || echo false)
if [[ "$already_pending" != "true" ]]; then
  next_n=$(jq -r '[.exceptions[]?.id // empty | capture("R-(?<n>[0-9]+)").n | tonumber] + [0] | max + 1' "$ARTIFACT")
  new_id=$(printf 'R-%03d' "$next_n")
  ts=$(date -u +%FT%TZ)
  # F1 (round-3): persist proposed test content for the runner.
  proposed_b64="$(printf '%s' "$proposed_content" | base64 -w0 2>/dev/null || printf '%s' "$proposed_content" | base64 | tr -d '\n')"
  jq --arg id "$new_id" --arg cycle "$cycle_id" --arg path "$file_path" \
     --arg ph "$pkg_hash" --arg sh "$scope_hash" --arg ts "$ts" \
     --arg ch "$proposed_content_hash" --arg b64 "$proposed_b64" \
     '.exceptions += [{
       "id": $id, "type": "test_review_completion", "status": "pending",
       "created_by": "hook", "created_at": $ts,
       "scope": {"test_file_path": $path, "package_files_hash": $ph, "proposed_content_hash": $ch, "proposed_content_base64": $b64},
       "binding": {"cycle_id": $cycle, "test_file_path": $path, "package_files_hash": $ph, "proposed_content_hash": $ch, "scope_hash": $sh}
     }]' "$ARTIFACT" > "$ARTIFACT.tmp" && mv "$ARTIFACT.tmp" "$ARTIFACT"
fi

jq -n --arg path "$file_path" --arg cid "$cycle_id" --arg sh "$scope_hash" '
  {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("TEST_REVIEW_REQUIRED. Test write at " + $path + " requires /second-opinion review. Run: scripts/tdd/run-second-opinion.sh test_review " + $cid + ". Expected scope_hash: " + $sh + ". Tier 2 test additions, new tests for concurrency, and tests for new features are all in scope. The AI may not decide that a test addition is mechanical enough to skip review.")
    }
  }'
exit 0
