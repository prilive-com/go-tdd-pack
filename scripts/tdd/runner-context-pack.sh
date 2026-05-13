#!/usr/bin/env bash
# scripts/tdd/runner-context-pack.sh
#
# v1.9.0 — Build the context pack for run-second-opinion.sh.
# Wraps the existing v1.6.0 build-second-opinion-context.sh (which
# generates schema-context) AND assembles the broader context:
#   - review-request.md       — what Codex must answer + finding format
#   - current-plan.md         — copy at HEAD
#   - config-snapshot.json    — copy at HEAD
#   - changed-files.txt       — file list of git diff
#   - full-diff.patch         — git diff HEAD
#   - codex-prompt.md         — assembled prompt sent to Codex on stdin
#
# Usage:
#   runner-context-pack.sh --review-type <type> --cycle-id <id> --output <dir>

set -uo pipefail

review_type=""
cycle_id=""
output_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --review-type) review_type="${2:-}"; shift 2 ;;
    --cycle-id)    cycle_id="${2:-}"; shift 2 ;;
    --output)      output_dir="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$review_type" ]] || [[ -z "$cycle_id" ]] || [[ -z "$output_dir" ]]; then
  echo "[runner-context-pack] usage error" >&2
  exit 2
fi

mkdir -p "$output_dir"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/../.." && pwd)"

# Schema-context: delegate to the existing v1.6.0 builder if present.
schema_ctx_builder="$script_dir/build-second-opinion-context.sh"
if [[ -x "$schema_ctx_builder" ]]; then
  bash "$schema_ctx_builder" --output "$output_dir/schema-context-for-reviewer.md" 2>/dev/null || true
fi

# Plan + config snapshots.
[[ -f "$project_root/.tdd/current-plan.md" ]] && \
  cp "$project_root/.tdd/current-plan.md" "$output_dir/current-plan.md"
[[ -f "$project_root/.tdd/tdd-config.json" ]] && \
  cp "$project_root/.tdd/tdd-config.json" "$output_dir/config-snapshot.json"

# Changed files + full diff (post-edit state, may be empty if the
# triggering edit hasn't landed yet — that's why we ALSO include the
# proposed_content from the pending obligation below).
( cd "$project_root" && git diff --name-only HEAD 2>/dev/null ) > "$output_dir/changed-files.txt" || true
( cd "$project_root" && git diff HEAD 2>/dev/null ) > "$output_dir/full-diff.patch" || true

# F1 (round-3): pull the PROPOSED content out of the pending
# obligation so Codex reviews what the AI is about to write, not
# the pre-edit git state.
artifact="$project_root/.tdd/exceptions/post-red-test-edits.json"
proposed_out="$output_dir/proposed-edit.txt"
> "$proposed_out"
if [[ -f "$artifact" ]] && command -v jq >/dev/null 2>&1; then
  type_filter=""
  case "$review_type" in
    plan_review)     type_filter="plan_review_completion" ;;
    test_review)     type_filter="test_review_completion" ;;
    production_edit) type_filter="production_edit_review_completion" ;;
  esac
  if [[ -n "$type_filter" ]]; then
    proposed_b64=$(jq -r --arg cid "$cycle_id" --arg t "$type_filter" '
      [.exceptions[]?
       | select(.type == $t)
       | select(.binding.cycle_id == $cid)
       | select(.status == "pending")
      ] | last // empty
      | (.scope.proposed_content_base64 // .scope.proposed_payload_base64 // "")
    ' "$artifact" 2>/dev/null)
    if [[ -n "$proposed_b64" ]] && [[ "$proposed_b64" != "null" ]]; then
      {
        printf '# Proposed edit (the AI is about to write this; review THIS, not git diff HEAD which may be empty)\n\n'
        printf '%s' "$proposed_b64" | base64 -d 2>/dev/null || printf '(failed to decode base64)\n'
        printf '\n'
      } > "$proposed_out"
    fi
  fi
fi

# Review request: per-type prompt instructions.
{
  printf '# Second-Opinion Review Request\n\n'
  printf '**Review type:** %s\n' "$review_type"
  printf '**Cycle:** %s\n\n' "$cycle_id"
  printf '## What Codex must verify\n\n'

  case "$review_type" in
    plan_review)
      cat <<'EOF'
1. Is the plan internally consistent (no contradictions in scope, ACs, invariants)?
2. Are the load-bearing invariants identified?
3. Are the test names sufficient to gate the behavior?
4. Are non-goals explicit?
5. Are risks named with mitigations?
6. Hidden hazards: race conditions, lifecycle bugs, partial-state failures, ordering invariants?
EOF
      ;;
    test_review)
      cat <<'EOF'
1. Does the test actually fail for the claimed reason (red-phase honesty)?
2. Is the test specific enough to catch the regression class?
3. Are there obvious gaps (concurrent edge cases, error paths, lifecycle states)?
4. Could the test be weakened later to pass (e.g., is the assertion granular)?
5. Are tests for new types covered?
EOF
      ;;
    production_edit)
      cat <<'EOF'
1. Does the diff match the approved plan?
2. Are there hidden race / ordering / lifecycle bugs?
3. Are accepted prior concerns ignored?
4. Are P0/P1 blockers present that the implementer missed?
5. Are tests sufficient to detect regression?
EOF
      ;;
  esac

  printf '\n## Finding format\n\n'
  cat <<'EOF'
For each P0/P1 finding produce:
- `id` (F1..Fn)
- `severity` (P0|P1|P2|P3)
- `failure_mode` (concrete)
- `evidence` (file:line or excerpt)
- `affected_invariant` (if any)
- `required_fix`
- `test` (the test that would catch it)
EOF
} > "$output_dir/review-request.md"

# Assemble the Codex prompt.
{
  printf 'You are an external technical reviewer.\n'
  printf 'Read the project context and the change under review.\n'
  printf 'Emit a single JSON object conforming to the review-completion schema.\n'
  printf 'No prose outside the JSON.\n\n'

  printf 'CALIBRATION:\n'
  printf -- '- Be skeptical. Find what the implementer missed.\n'
  printf -- '- Severity: P0 = security/data-loss/governance bypass; P1 = real bug\n'
  printf -- '  needing rework; P2 = quality; P3 = nit/docs.\n'
  printf -- '- Downgrade if uncertain.\n\n'

  printf 'REVIEW TYPE: %s\nCYCLE: %s\n' "$review_type" "$cycle_id"

  # F1 (round-5): tell Codex the EXACT scope_hash to use in its
  # output. Without this, Codex hallucinates a hash and the runner's
  # conformance check rejects it, causing legitimate reviews to
  # deadlock.
  if [[ -f "$artifact" ]] && command -v jq >/dev/null 2>&1; then
    expected_scope_hash=$(jq -r --arg cid "$cycle_id" --arg t "$type_filter" '
      [.exceptions[]?
       | select(.type == $t)
       | select(.binding.cycle_id == $cid)
       | select(.status == "pending")
      ] | last // empty
      | (.binding.scope_hash // "")
    ' "$artifact" 2>/dev/null)
    if [[ -n "$expected_scope_hash" ]] && [[ "$expected_scope_hash" != "null" ]]; then
      printf 'EXPECTED SCOPE_HASH (use this verbatim in your output .scope_hash field): %s\n' "$expected_scope_hash"
    fi
  fi
  printf '\n'

  printf 'REVIEW REQUEST:\n'
  cat "$output_dir/review-request.md"
  printf '\n\n'

  printf 'PROJECT CONTEXT (CLAUDE.md, first 200 lines):\n'
  head -n 200 "$project_root/CLAUDE.md" 2>/dev/null || printf '(CLAUDE.md not found)\n'
  printf '\n'

  printf 'PLAN:\n'
  cat "$output_dir/current-plan.md" 2>/dev/null || printf '(no current-plan.md)\n'
  printf '\n'

  if [[ -f "$output_dir/schema-context-for-reviewer.md" ]]; then
    printf 'SCHEMA CONTEXT:\n'
    cat "$output_dir/schema-context-for-reviewer.md"
    printf '\n'
  fi

  printf 'CHANGED FILES:\n'
  cat "$output_dir/changed-files.txt" 2>/dev/null
  printf '\n'

  printf 'FULL DIFF (git diff HEAD, may be empty if the gated edit has not landed yet):\n'
  cat "$output_dir/full-diff.patch" 2>/dev/null
  printf '\n'

  if [[ -s "$output_dir/proposed-edit.txt" ]]; then
    printf 'PROPOSED EDIT (the AI is about to write this — review this content):\n'
    cat "$output_dir/proposed-edit.txt"
    printf '\n'
  fi

  printf 'OUTPUT — emit a single JSON object only, conforming to the schema at\n'
  printf '.tdd/templates/review-completion.schema.json. Required fields:\n'
  printf 'review_type, cycle_id, scope_hash, verdict, findings, required_actions.\n'
} > "$output_dir/codex-prompt.md"

exit 0
