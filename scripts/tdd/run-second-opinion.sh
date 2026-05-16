#!/usr/bin/env bash
# scripts/tdd/run-second-opinion.sh
#
# v1.9.0 Pack No-Discretion Second Opinion — the ONLY legitimate
# `codex exec` caller. The hooks call this script; the runner builds
# the context pack, invokes Codex, verifies output conformance via jq
# (defends against openai/codex#4181 gpt-5-family gating and #15451
# silent-ignore when MCP active), and records a review-completion
# entry on success.
#
# Usage:
#   run-second-opinion.sh <review-type> <cycle-id>
#
# Review types:
#   plan_review        Plan write at .tdd/current-plan.md / .tdd/plans/** / docs/specs/*.md
#   test_review        Test file write/create
#   production_edit    Production .go edit (per-cycle-per-base_git_sha scope)
#
# Stable typed-exception codes emitted on stderr:
#   CODEX_OUTPUT_NON_CONFORMANT  Codex output failed jq schema validation
#                                after re-prompting up to 2 times.
#   CODEX_UNREACHABLE            Codex CLI missing / auth failed.
#   MODEL_NOT_SCHEMA_COMPATIBLE  Configured model is in a family known
#                                to silently drop --output-schema (#4181).
#
# Exit codes: 0 success, 1 review rejected, 2 hard error.

set -uo pipefail

usage() {
  echo "usage: $0 <plan_review|test_review|production_edit> <cycle-id>" >&2
  exit 2
}

[[ $# -lt 2 ]] && usage
review_type="$1"
cycle_id="$2"

case "$review_type" in
  plan_review|test_review|production_edit) ;;
  *) echo "[run-second-opinion] unknown review-type: $review_type" >&2; usage ;;
esac

# Pre-flight: Codex CLI must be installed.
if ! command -v codex >/dev/null 2>&1; then
  echo "[run-second-opinion] CODEX_UNREACHABLE: codex CLI not installed. Run 'codex login' (ChatGPT auth) OR set CODEX_API_KEY." >&2
  exit 2
fi

# Pre-flight: jq required for conformance verification.
if ! command -v jq >/dev/null 2>&1; then
  echo "[run-second-opinion] BLOCKED: jq required for output conformance verification." >&2
  exit 2
fi

# Locate companion files relative to this script.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The runner ships with the pack but operates on the OPERATOR's
# project. Use CLAUDE_PROJECT_DIR (set by Claude Code), or the
# caller's CWD if it contains .tdd/, otherwise fall back to the
# starter (`script_dir/../..`).
project_root="${CLAUDE_PROJECT_DIR:-}"
if [[ -z "$project_root" ]]; then
  if [[ -d "$(pwd)/.tdd" ]]; then
    project_root="$(pwd)"
  else
    project_root="$(cd "$script_dir/../.." && pwd)"
  fi
fi
# Round-cap check (FIRST — before any file pre-flights so the cap is
# enforced even when other prerequisites are stale). Hard-stop at
# max_review_rounds_per_cycle (default 4): the empirical convergence
# point per v1.9.0's own 10-round cycle where round 10 introduced a
# regression. Operator should ship at the cap and queue remaining
# findings to next cycle.
completion_type=""
case "$review_type" in
  plan_review)       completion_type="plan_review_completion" ;;
  test_review)       completion_type="test_review_completion" ;;
  production_edit)   completion_type="production_edit_review_completion" ;;
esac
config="$project_root/.tdd/tdd-config.json"
artifact="$project_root/.tdd/exceptions/post-red-test-edits.json"
max_rounds=4
if [[ -f "$config" ]]; then
  cfg_max=$(jq -r '.second_opinion.no_discretion.max_review_rounds_per_cycle // 4' "$config" 2>/dev/null || echo 4)
  if [[ -n "$cfg_max" ]] && [[ "$cfg_max" =~ ^[0-9]+$ ]]; then
    max_rounds=$cfg_max
  fi
fi
approved_rounds=0
if [[ -f "$artifact" ]]; then
  approved_rounds=$(jq -r --arg cid "$cycle_id" --arg type "$completion_type" '
    [.exceptions[]?
     | select(.type == $type)
     | select(.binding.cycle_id == $cid)
     | select(.status == "approved")
    ] | length
  ' "$artifact" 2>/dev/null || echo 0)
  [[ -z "$approved_rounds" ]] && approved_rounds=0
fi
if [[ "$approved_rounds" -ge "$max_rounds" ]]; then
  echo "[run-second-opinion] BLOCKED: max_review_rounds_per_cycle reached." >&2
  echo "[run-second-opinion]   review_type=$review_type, cycle=$cycle_id" >&2
  echo "[run-second-opinion]   approved_rounds=$approved_rounds, max_rounds=$max_rounds" >&2
  echo "[run-second-opinion]" >&2
  echo "[run-second-opinion] The cycle has had $max_rounds rounds of /second-opinion." >&2
  echo "[run-second-opinion] Diminishing-returns territory. Choose one:" >&2
  echo "[run-second-opinion]   1. Ship the cycle now; document remaining concerns as next-cycle backlog." >&2
  echo "[run-second-opinion]   2. Raise second_opinion.no_discretion.max_review_rounds_per_cycle in" >&2
  echo "[run-second-opinion]      .tdd/tdd-config.json with documented operator reason in the commit." >&2
  echo "[run-second-opinion]" >&2
  echo "[run-second-opinion] (v1.9.0 itself ran 10 rounds; round 10 INTRODUCED a regression from round 9." >&2
  echo "[run-second-opinion]  The 4-round cap reflects the empirical convergence point.)" >&2
  exit 2
fi

context_builder="$script_dir/runner-context-pack.sh"
hash_scope="$script_dir/hash-review-scope.sh"
validate_completion="$script_dir/validate-review-completion.sh"
schema="$project_root/.tdd/templates/review-completion.schema.json"

for f in "$context_builder" "$hash_scope" "$validate_completion" "$schema"; do
  if [[ ! -f "$f" ]]; then
    echo "[run-second-opinion] BLOCKED: required file missing: $f" >&2
    exit 2
  fi
done

# Model compatibility check.
# --output-schema is documented to be silently dropped for codex-family
# models (openai/codex#4181). Pin to a known-compatible model unless
# the operator overrides via CODEX_MODEL. Recognized-compatible set:
# gpt-5.5, gpt-5.4 (the gpt-5 plain family, NOT gpt-5-codex variants).
codex_model="${CODEX_MODEL:-gpt-5.5}"
case "$codex_model" in
  gpt-5.5|gpt-5.4|gpt-5.3|gpt-5) ;;
  *gpt-5-codex*|*codex-spark*)
    echo "[run-second-opinion] MODEL_NOT_SCHEMA_COMPATIBLE: model '$codex_model' is in the codex-family which silently drops --output-schema (openai/codex#4181). Pin CODEX_MODEL=gpt-5.5 OR another non-codex gpt-5 variant." >&2
    exit 2
    ;;
  *)
    echo "[run-second-opinion] WARN: model '$codex_model' compatibility with --output-schema unverified; expect MODEL_NOT_SCHEMA_COMPATIBLE if output is non-conformant after re-prompt retries." >&2
    ;;
esac

# Build context pack.
review_id="$(date -u +%Y%m%dT%H%M%SZ)-${review_type}-${cycle_id}"
reviews_dir="$project_root/.tdd/second-opinion/reviews/$review_id"
mkdir -p "$reviews_dir/context"

if ! bash "$context_builder" \
  --review-type "$review_type" \
  --cycle-id "$cycle_id" \
  --output "$reviews_dir/context" 2>&1; then
  echo "[run-second-opinion] BLOCKED: context-pack builder failed." >&2
  exit 2
fi

prompt_path="$reviews_dir/context/codex-prompt.md"
if [[ ! -f "$prompt_path" ]]; then
  echo "[run-second-opinion] BLOCKED: context builder did not produce codex-prompt.md." >&2
  exit 2
fi

# Codex invocation with output conformance verification.
output_path="$reviews_dir/codex-output.json"

# Helper: validate Codex output against schema via jq, defending
# against --output-schema silent-ignore (#15451 MCP-active, #4181
# codex-family).
verify_conformance() {
  local file="$1"
  if [[ ! -f "$file" ]] || ! jq -e . "$file" >/dev/null 2>&1; then
    return 1
  fi
  # v1.9.0 round-6 F1: strict type checks per review-completion schema.
  # Required top-level fields with correct types.
  if ! jq -e '
    (.review_type | type) == "string"
    and (.cycle_id | type) == "string"
    and (.scope_hash | type) == "string"
    and (.verdict | type) == "string"
    and (.findings | type) == "array"
    and (.required_actions | type) == "array"
  ' "$file" >/dev/null 2>&1; then
    echo "[verify_conformance] BLOCKED: top-level field types wrong" >&2
    return 1
  fi
  # Each finding must have the required fields with correct types.
  if ! jq -e '
    .findings | all(.[];
      (.id | type) == "string"
      and (.severity | type) == "string"
      and (.failure_mode | type) == "string"
      and (.evidence | type) == "string"
      and (.required_fix | type) == "string"
      and (.test | type) == "string"
      and (.severity | IN("P0","P1","P2","P3"))
    )
  ' "$file" >/dev/null 2>&1; then
    echo "[verify_conformance] BLOCKED: a finding has missing/malformed fields" >&2
    return 1
  fi
  # Verdict enum.
  local verdict
  verdict=$(jq -r '.verdict' "$file")
  case "$verdict" in
    approve|approve_with_changes|block) ;;
    *) return 1 ;;
  esac
  # v1.9.0 round-4 F3: bind to the pending obligation we identified
  # earlier. Reject if Codex's output asserts a different review_type,
  # cycle_id, or scope_hash than what the hook recorded.
  local actual_rtype actual_cycle actual_scope
  actual_rtype=$(jq -r '.review_type' "$file")
  actual_cycle=$(jq -r '.cycle_id' "$file")
  actual_scope=$(jq -r '.scope_hash' "$file")
  if [[ "$actual_rtype" != "$review_type" ]]; then
    echo "[verify_conformance] BLOCKED: review_type mismatch: codex=$actual_rtype, expected=$review_type" >&2
    return 1
  fi
  if [[ "$actual_cycle" != "$cycle_id" ]]; then
    echo "[verify_conformance] BLOCKED: cycle_id mismatch: codex=$actual_cycle, expected=$cycle_id" >&2
    return 1
  fi
  # authoritative_scope_hash is defined later but populated before
  # the conformance check is called.
  if [[ -n "${authoritative_scope_hash:-}" ]] && [[ "$actual_scope" != "$authoritative_scope_hash" ]]; then
    echo "[verify_conformance] BLOCKED: scope_hash mismatch: codex=$actual_scope, expected=$authoritative_scope_hash" >&2
    return 1
  fi
  return 0
}

# Locate the pending obligation BEFORE invoking Codex so the
# conformance check can verify Codex's output against the
# authoritative scope_hash (v1.9.0 round-4 F3). artifact path
# already set during round-cap pre-flight; ensure parent + seed.
mkdir -p "$(dirname "$artifact")"
[[ -f "$artifact" ]] || cat > "$artifact" <<EOF
{"version":1,"cycle_id":"$cycle_id","phase":"red_confirmed","expires":"next_green_commit","exceptions":[]}
EOF

# Now locate the pending obligation (after cap check passed).
pending_entry=$(jq -c --arg cid "$cycle_id" --arg type "$completion_type" '
  [.exceptions[]?
   | select(.type == $type)
   | select(.binding.cycle_id == $cid)
   | select(.status == "pending")
  ] | last // empty
' "$artifact" 2>/dev/null || echo "")

if [[ -z "$pending_entry" ]] || [[ "$pending_entry" == "null" ]]; then
  echo "[run-second-opinion] BLOCKED: no pending $completion_type obligation found for cycle '$cycle_id'. The trigger hook must create the pending entry first (i.e., the AI must attempt the gated tool call before running this script)." >&2
  exit 2
fi

pending_id=$(printf '%s' "$pending_entry" | jq -r '.id')
authoritative_scope_hash=$(printf '%s' "$pending_entry" | jq -r '.binding.scope_hash')
pending_scope=$(printf '%s' "$pending_entry" | jq -c '.scope // {}')

# Re-prompt up to 2 times on non-conformance.
attempt=0
max_attempts=3
codex_succeeded=0
while [[ $attempt -lt $max_attempts ]]; do
  attempt=$((attempt + 1))
  echo "[run-second-opinion] Codex attempt $attempt of $max_attempts (model: $codex_model)..." >&2
  if ! codex exec \
      --sandbox read-only \
      --ephemeral \
      --json \
      --output-schema "$schema" \
      --output-last-message "$output_path" \
      -m "$codex_model" \
      --cd "$project_root" \
      - < "$prompt_path" 2>>"$project_root/.tdd/second-opinion-debug.log"; then
    echo "[run-second-opinion] CODEX_UNREACHABLE: codex exec exited non-zero on attempt $attempt." >&2
    if [[ $attempt -ge $max_attempts ]]; then
      exit 2
    fi
    continue
  fi
  if verify_conformance "$output_path"; then
    codex_succeeded=1
    break
  fi
  echo "[run-second-opinion] WARN: Codex output failed conformance check on attempt $attempt (jq verification). Re-prompting." >&2
done

if [[ "$codex_succeeded" -ne 1 ]]; then
  echo "[run-second-opinion] CODEX_OUTPUT_NON_CONFORMANT: Codex output failed schema validation after $max_attempts attempts. See $output_path and $project_root/.tdd/second-opinion-debug.log." >&2
  exit 1
fi

# P0/P1 gating: refuse to write completion if any unresolved P0/P1.
p0_count=$(jq '[.findings[]? | select(.severity == "P0")] | length' "$output_path")
p1_count=$(jq '[.findings[]? | select(.severity == "P1")] | length' "$output_path")
verdict=$(jq -r '.verdict' "$output_path")
# v1.9.0 round-7 F3: Codex CANNOT self-clear P1 findings. The
# `accepted_with_evidence` field in Codex output is IGNORED. Only
# an operator can mark a finding as accepted via a separate
# disposition step (out of scope for v1.9.0 — defer to v1.10).
# All P0 + P1 findings block until addressed in code OR a clean
# subsequent review returns zero unresolved P0/P1.
if [[ "$verdict" == "block" ]] || (( p0_count > 0 )) || (( p1_count > 0 )); then

  # v1.9.9: detect "context request" responses. v1.9.10 loosens to
  # match on `failure_mode` prefix alone — the `id` prefix check was
  # over-restrictive. Real Codex output complied with the
  # `failure_mode: "missing context: ..."` convention but kept the
  # standard `id: "F1"` naming because that's what the rest of the
  # schema expects. Adopter session at 2026-05-16 (HEAD 8cbddfb) hit
  # this: 2 findings tagged "missing context: testdata/..." went
  # unrecognized because their ids were F1/F2 not MC-1/MC-2. The
  # `failure_mode` prefix is the semantic signal; the `id` prefix
  # was decorative. Drop it.
  total_blocking=$(( p0_count + p1_count ))
  mc_count=0
  if (( total_blocking > 0 )); then
    mc_count=$(jq '[.findings[]?
                    | select(.severity == "P0" or .severity == "P1")
                    | select(.failure_mode | startswith("missing context:"))
                   ] | length' "$output_path")
  fi
  if (( total_blocking > 0 )) && (( mc_count == total_blocking )); then
    echo "[run-second-opinion] CONTEXT REQUEST: Codex needs unchanged supporting files to complete the review." >&2
    echo "[run-second-opinion] This round does NOT count toward max_review_rounds_per_cycle (pending entry stays pending)." >&2
    echo "[run-second-opinion]" >&2
    echo "[run-second-opinion] Files Codex requested:" >&2
    jq -r '.findings[]
           | select(.failure_mode | startswith("missing context:"))
           | "  - " + (.failure_mode | sub("^missing context:[[:space:]]*"; ""))' \
       "$output_path" >&2 2>/dev/null || true
    echo "[run-second-opinion]" >&2
    echo "[run-second-opinion] Operator action: add each file to .tdd/current-plan.md under" >&2
    echo "[run-second-opinion]   ## Additional context" >&2
    echo "[run-second-opinion]     ### <file path>" >&2
    echo "[run-second-opinion]     \`\`\`" >&2
    echo "[run-second-opinion]     <paste file content>" >&2
    echo "[run-second-opinion]     \`\`\`" >&2
    echo "[run-second-opinion] then re-run: scripts/tdd/run-second-opinion.sh $review_type $cycle_id" >&2
    echo "[run-second-opinion] Review artifacts: $reviews_dir" >&2
    exit 1
  fi

  echo "[run-second-opinion] Review verdict=$verdict, P0=$p0_count, P1=$p1_count. Completion NOT written until ALL P0/P1 findings addressed in code AND a subsequent clean review returns zero P0/P1. Codex self-clear via accepted_with_evidence is NOT honored in v1.9.0." >&2
  echo "[run-second-opinion] Review artifacts: $reviews_dir" >&2
  exit 1
fi

# Compute prev_audit_sha for SHA-chain linkage.
audit_log="$project_root/.tdd/audit/${cycle_id}.jsonl"
mkdir -p "$(dirname "$audit_log")"
prev_audit_sha=""
if [[ -s "$audit_log" ]]; then
  last_line=$(tail -1 "$audit_log")
  if command -v sha256sum >/dev/null 2>&1; then
    prev_audit_sha=$(printf '%s' "$last_line" | sha256sum | awk '{print $1}')
  else
    prev_audit_sha=$(printf '%s' "$last_line" | shasum -a 256 | awk '{print $1}')
  fi
fi

# Pull review fields from Codex output.
verdict=$(jq -r '.verdict' "$output_path")
findings_p0=$(jq '[.findings[]? | select(.severity=="P0")] | length' "$output_path")
findings_p1=$(jq '[.findings[]? | select(.severity=="P1")] | length' "$output_path")
findings_p2=$(jq '[.findings[]? | select(.severity=="P2")] | length' "$output_path")
findings_p3=$(jq '[.findings[]? | select(.severity=="P3")] | length' "$output_path")
ts=$(date -u +%FT%TZ)

# v1.9.0 round-2 F2: populate production scope with the file list
# observed during this cycle's production edits. For now, carry the
# pending's first_seen_file into allowed_file_globs as a single entry.
# (Future enhancement: walk git diff to record all edited files.)
completion_scope="$pending_scope"
if [[ "$review_type" == "production_edit" ]]; then
  first_file=$(printf '%s' "$pending_entry" | jq -r '.scope.first_seen_file // ""')
  if [[ -n "$first_file" ]]; then
    completion_scope=$(jq -c -n --arg f "$first_file" '{allowed_file_globs: [$f], first_seen_file: $f}')
  fi
fi

# v1.9.0 round-2 F1+F5: TRANSITION the pending entry to approved
# (atomic status change + binding extension), preserving the
# trigger-computed scope_hash. Do NOT append a new entry.
jq --arg id "$pending_id" \
   --arg verdict "$verdict" \
   --arg ts "$ts" \
   --arg codex_model "$codex_model" \
   --arg output_path "$output_path" \
   --arg prev "$prev_audit_sha" \
   --argjson p0 "$findings_p0" \
   --argjson p1 "$findings_p1" \
   --argjson p2 "$findings_p2" \
   --argjson p3 "$findings_p3" \
   --argjson newscope "$completion_scope" \
   '
   .exceptions = (.exceptions | map(
     if .id == $id then
       .status = "approved"
       | .approved_by = "operator"
       | .approved_at = $ts
       | .scope = $newscope
       | .reason = "v1.9.0 second-opinion completion"
       | .binding.completion_at = $ts
       | .binding.codex_model = $codex_model
       | .binding.codex_output_path = $output_path
       | .binding.verdict = $verdict
       | .binding.findings_counts = {"p0": $p0, "p1": $p1, "p2": $p2, "p3": $p3}
       | .binding.prev_audit_sha = $prev
     else . end
   ))' "$artifact" > "$artifact.tmp" && mv "$artifact.tmp" "$artifact"

# Use authoritative scope_hash going forward.
new_id="$pending_id"
scope_hash="$authoritative_scope_hash"

# Append audit-log entry.
audit_entry=$(jq -c -n \
  --arg ts "$ts" \
  --arg event "obligation_completed" \
  --arg id "$new_id" \
  --arg cycle "$cycle_id" \
  --arg rtype "$review_type" \
  --arg verdict "$verdict" \
  --arg scope "$scope_hash" \
  --arg prev "$prev_audit_sha" \
  '{ts:$ts, event:$event, exception_id:$id, cycle_id:$cycle, review_type:$rtype, verdict:$verdict, scope_hash:$scope, prev_sha:$prev}')
printf '%s\n' "$audit_entry" >> "$audit_log"

echo "[run-second-opinion] Completion $new_id recorded. Type: $completion_type. Verdict: $verdict. P0:$findings_p0 P1:$findings_p1 P2:$findings_p2 P3:$findings_p3" >&2
echo "[run-second-opinion] Review artifacts: $reviews_dir" >&2
echo "[run-second-opinion] Retry the tool call now; the matching trigger hook will allow it." >&2
exit 0
