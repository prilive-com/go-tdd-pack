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

  # v1.10.0: tell Codex its actual environment. The runner now invokes
  # `codex exec --sandbox danger-full-access --ask-for-approval never
  # --cd <project_root>`, which gives Codex the same environment Claude
  # Code itself runs in: real files, real OS, real network, real
  # commands. ONE rule, enforced by this prompt + Codex's cooperation:
  # do not write or modify any files. This is a code review, not an
  # implementation cycle.
  printf '\n## Your environment\n\n'
  cat <<'EOF'
You are running with FULL access to the real project at the path
given by `--cd`. You can:

- Read any file in the project (and outside it if you need to).
- Run any shell command: `cat`, `ls`, `grep`, `rg`, `find`,
  `git log`, `git show`, `git diff`, `go vet`, `go list -json`,
  `go test -count=1 -run '<pattern>'`, `gofmt -l`, `staticcheck`, etc.
- Access the network if you genuinely need it (rare for code review).
- Use any tool the OS provides.

This is the same environment Claude Code itself runs in. You are a
peer reviewer with full repo and command access, not a sandboxed
process with limited capabilities. Use that access freely to give
the best possible review:

- If a changed `_test.go` references `testdata/foo.txt` — cat it,
  evaluate the test against its real content.
- If an import resolves to `internal/helpers/util.go` — cat it to
  see what the changed code is calling.
- If you want to know whether tests pass — `go test ./...`.
- If you want to see how a function evolved — `git log -p <file>`.
- If you need the contract of a third-party dep — `cat go.sum`,
  `go list -m all`, etc.

## The one inviolable rule

**DO NOT WRITE OR MODIFY ANY FILES.** This includes:

- No `Edit` or `Write` of any kind (you are not running under a tool
  layer that gates these — the responsibility is yours).
- No `>`, `>>`, `tee`, `cp`, `mv`, `rm`, `mkdir`, `touch`, `chmod`,
  `chown`, `ln`, `truncate`, `sed -i`, `awk -i`, or any other
  command whose effect modifies the filesystem.
- No `git commit`, `git add`, `git reset`, `git checkout`, `git
  branch`, `git stash`, `git rebase`, `git merge`, or any other
  git operation that mutates repo state.
- No `go mod tidy`, `go mod download`, `go generate`, `gofmt -w`,
  `goimports -w`, or any tool invocation with a write side-effect.
- No package install, `apt`, `brew`, `pip`, `npm install`, etc.

You are a reviewer. The implementer (Claude Code) writes the code;
you give findings on it. If your review requires file mutation to
verify (e.g., "I want to run `go fix`"), express that as a
finding's `required_fix`, not by performing the mutation.

Violating this rule defeats the entire `/second-opinion` workflow.
The operator has explicitly extended trust based on you respecting
this single boundary.

## If you genuinely cannot read a file

Edge cases only — the file is outside the project root, was just
deleted, the path is on a network mount that's unreachable, etc.
In that rare case, emit a context-request finding:

- `failure_mode`: starts with literal prefix `missing context: `
  followed by the path AND a one-clause reason
  (e.g. `missing context: testdata/foo.txt — does not exist on disk`)
- `evidence`: what you tried (e.g. `cat testdata/foo.txt → ENOENT`)
- `severity`: `P1`, `category`: `other`, `test`: `(none — informational)`
- `required_fix`: tell the operator how to make the file available

When ALL findings follow this shape the runner treats the round as
a context request, does NOT count it toward
`max_review_rounds_per_cycle`, and surfaces the missing paths to
the operator. Default to reading the file yourself first — this
fallback is only for genuine read failures, not "I'd prefer the
operator paste it for me."
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
