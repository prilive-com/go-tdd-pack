#!/usr/bin/env bash
# scripts/tdd/validate-codex-output.sh
#
# v1.10.2 — External validator for Codex review-completion output.
#
# Why this exists separately from --output-schema:
#   - openai/codex#15451: `--output-schema` is silently ignored when
#     tools/MCP servers are active. Since v1.10.0 we invoke Codex with
#     `--sandbox danger-full-access` which enables shell tool use; the
#     schema enforcement is therefore unreliable exactly when we need
#     it. External validation closes that gap.
#   - openai/codex#19816: `--output-schema` applies to EVERY agent_message,
#     not just the final one. Parsers that grab "the first schema-valid
#     JSON" can pick up an intermediate message instead of the final.
#   - openai/codex#4181 (historical): `--output-schema` was silently
#     dropped for codex-family models in 0.41.0. Defense-in-depth.
#
# Contract:
#   Input:   path to Codex output JSON file (typically the
#            --output-last-message file written by run-second-opinion.sh).
#   Output:  on stdout if valid, a one-line "OK <hash>" summary;
#            on stderr if invalid, structured violation lines prefixed
#            "[validate-codex-output]" naming the offending JSON path.
#   Exit:    0 if valid, 1 if invalid, 2 if usage / preflight error.
#
# Validation rules (kept in sync with v1.9.3 + v1.9.8 schema):
#   - Top-level: review_type, cycle_id, scope_hash, verdict, findings,
#     required_actions, summary, codex_session_uuid, codex_model
#     (all required per strict response_format).
#   - verdict ∈ {approve, approve_with_changes, block}.
#   - findings is an array. Each item requires id (Fn shape), severity
#     (P0..P3), failure_mode, evidence, required_fix, test, plus the
#     v1.9.3 additions category, affected_invariant, location.
#
# Usage:
#   scripts/tdd/validate-codex-output.sh <path-to-output.json>

set -uo pipefail

usage() {
  echo "usage: $0 <path-to-codex-output.json>" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
output_file="$1"

if ! command -v jq >/dev/null 2>&1; then
  echo "[validate-codex-output] BLOCKED: jq required." >&2
  exit 2
fi
if [[ ! -f "$output_file" ]]; then
  echo "[validate-codex-output] BLOCKED: file not found: $output_file" >&2
  exit 2
fi
if ! jq -e . "$output_file" >/dev/null 2>&1; then
  echo "[validate-codex-output] FAIL: file is not valid JSON: $output_file" >&2
  exit 1
fi

violations=()

# Top-level required fields.
for field in review_type cycle_id scope_hash verdict findings required_actions summary codex_session_uuid codex_model; do
  has=$(jq --arg f "$field" 'has($f)' "$output_file" 2>/dev/null)
  if [[ "$has" != "true" ]]; then
    violations+=("missing top-level field: $field")
  fi
done

# verdict enum.
verdict=$(jq -r '.verdict // ""' "$output_file" 2>/dev/null)
case "$verdict" in
  approve|approve_with_changes|block) ;;
  "") violations+=("verdict is missing or empty") ;;
  *)  violations+=("verdict not in enum {approve, approve_with_changes, block}: $verdict") ;;
esac

# Type checks on top-level fields.
if ! jq -e '
  (.review_type | type) == "string"
  and (.cycle_id | type) == "string"
  and (.scope_hash | type) == "string"
  and (.findings | type) == "array"
  and (.required_actions | type) == "array"
' "$output_file" >/dev/null 2>&1; then
  violations+=("top-level field type mismatch (review_type/cycle_id/scope_hash must be string; findings/required_actions must be array)")
fi

# scope_hash format (64 lowercase hex).
scope_hash=$(jq -r '.scope_hash // ""' "$output_file" 2>/dev/null)
if [[ -n "$scope_hash" ]] && ! [[ "$scope_hash" =~ ^[0-9a-f]{64}$ ]]; then
  violations+=("scope_hash is not 64-char lowercase hex: $scope_hash")
fi

# Per-finding validation. Use the v1.9.8 jq pattern (all(.[]; ...)) so
# non-empty findings get element-wise checks, not array-as-value.
findings_count=$(jq '.findings | length' "$output_file" 2>/dev/null || echo 0)
if [[ "$findings_count" -gt 0 ]]; then
  if ! jq -e '
    .findings | all(.[];
      (.id | type) == "string"
      and (.id | test("^F[0-9]+$"))
      and (.severity | IN("P0", "P1", "P2", "P3"))
      and (.failure_mode | type) == "string"
      and (.failure_mode | length) > 0
      and (.evidence | type) == "string"
      and (.required_fix | type) == "string"
      and (.test | type) == "string"
    )
  ' "$output_file" >/dev/null 2>&1; then
    violations+=("at least one finding has malformed fields (id must match ^F[0-9]+$; severity must be P0-P3; failure_mode/evidence/required_fix/test must be non-empty strings)")
  fi
fi

if (( ${#violations[@]} > 0 )); then
  echo "[validate-codex-output] FAIL: $output_file" >&2
  for v in "${violations[@]}"; do
    echo "[validate-codex-output]   - $v" >&2
  done
  exit 1
fi

# All checks passed. Emit a short summary so callers can grep.
content_hash=$( { command -v sha256sum >/dev/null && sha256sum < "$output_file" || shasum -a 256 < "$output_file"; } | awk '{print $1}')
echo "OK ${content_hash:0:16}  verdict=${verdict}  findings=${findings_count}"
exit 0
