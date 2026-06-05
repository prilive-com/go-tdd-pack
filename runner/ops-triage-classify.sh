#!/usr/bin/env bash
# runner/ops-triage-classify.sh
#
# v2.2 slice 2 — Layer 2 fast model classifier for ops-risk-triage.
#
# Reads minimal STRUCTURED context (JSON) on stdin, returns a strict-JSON
# risk verdict on stdout. Fast, single-turn, no conversation context,
# temperature 0. Caching is the hook's responsibility (so the script
# stays a pure classifier; the hook decides what to cache and when).
#
# Verdict shape (must conform to schemas/ops-triage-verdict.schema.json):
#   {
#     "risk":              "<safe_readonly|local_read|external_read|
#                           local_mutation|code_mutation|infra_mutation|
#                           destructive|unknown>",
#     "confidence":        <1-5>,
#     "escalate_to_codex": <true|false>,
#     "reason":            "<one short factual sentence>"
#   }
#
# Exit 0 + strict JSON on success.
# Exit non-zero + empty stdout on failure (the hook then logs the failure
# and falls back to either fail-closed escalate (ask/governed mode) or
# slice-1 "would_classify" log (observe mode).
#
# Backends:
#   haiku  — Anthropic Messages API, claude-haiku-4-5, temperature 0.
#            Default. Requires ANTHROPIC_API_KEY env var.
#   codex  — codex exec --output-schema (slower; use only if you want a
#            single Codex workflow). NOT recommended in the hot path.
#
# Test injection: if PRILIVE_OPS_TRIAGE_CLASSIFIER_BIN is set and
# executable, it is invoked instead of the real backends. Smokes use this
# to provide canned verdicts without burning API tokens.

set -uo pipefail

CLASSIFIER="${1:-haiku}"
ROOT="${CLAUDE_PLUGIN_ROOT:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
PROMPT_FILE="${ROOT}/prompts/ops-risk-classifier.md"
SCHEMA_FILE="${ROOT}/schemas/ops-triage-verdict.schema.json"

CTX=$(cat 2>/dev/null || true)
[[ -z "${CTX}" ]] && exit 1

# Test injection — short-circuit to a user-provided classifier binary.
# The stub receives the same stdin (CTX JSON) and must emit the same
# verdict shape on stdout. Used by smokes to avoid real API calls.
if [[ -n "${PRILIVE_OPS_TRIAGE_CLASSIFIER_BIN:-}" \
   && -x "${PRILIVE_OPS_TRIAGE_CLASSIFIER_BIN}" ]]; then
  printf '%s' "${CTX}" | "${PRILIVE_OPS_TRIAGE_CLASSIFIER_BIN}"
  exit $?
fi

command -v jq >/dev/null 2>&1 || exit 1
CMD=$(jq -r '.command // empty' <<<"${CTX}" 2>/dev/null)
[[ -z "${CMD}" ]] && exit 1
[[ -f "${PROMPT_FILE}" ]] || exit 1

# Build the prompt: template with command + minimal context substituted in.
# Use awk for substitution so command content with `&` or `\` is safe.
PROMPT=$(awk -v cmd="${CMD}" -v ctx="${CTX}" '
  { gsub(/<<<COMMAND>>>/, cmd); gsub(/<<<MINIMAL_CONTEXT>>>/, ctx); print }
' "${PROMPT_FILE}")

case "${CLASSIFIER}" in
  haiku)
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] || { echo "ops-triage-classify: ANTHROPIC_API_KEY required for haiku" >&2; exit 1; }
    REQUEST=$(jq -nc --arg m "claude-haiku-4-5" --arg p "${PROMPT}" \
                '{model:$m,max_tokens:256,temperature:0,
                  messages:[{role:"user",content:$p}]}')
    RESP=$(curl -sS --max-time 10 https://api.anthropic.com/v1/messages \
            -H "x-api-key: ${ANTHROPIC_API_KEY}" \
            -H "anthropic-version: 2023-06-01" \
            -H "content-type: application/json" \
            -d "${REQUEST}" 2>/dev/null) || exit 1
    OUT=$(jq -r '.content[0].text // empty' <<<"${RESP}" 2>/dev/null)
    ;;
  codex)
    # Slower path. --ignore-user-config detaches MCP so --output-schema
    # is not silently dropped (openai/codex#15451). Validate before
    # trusting the output anyway (v2.1.0 Bug 1 lesson).
    OUT=$(printf '%s' "${PROMPT}" | timeout 60 codex exec \
            --ignore-user-config \
            --output-schema "${SCHEMA_FILE}" -o /dev/stdout 2>/dev/null) || exit 1
    ;;
  *)
    echo "ops-triage-classify: unknown classifier '${CLASSIFIER}'" >&2
    exit 1
    ;;
esac

# Strip any accidental code fences, emit the JSON object only.
OUT=$(sed -E 's/^```[a-z]*//; s/```$//' <<<"${OUT}" | tr -d '\r')

# Validate the verdict shape — must have risk, confidence,
# escalate_to_codex, reason. The strict-mode schema (validated upstream
# by codex --output-schema, and validated downstream by the hook before
# logging) catches malformed responses.
CLEAN=$(jq -c '{risk, confidence, escalate_to_codex, reason}' <<<"${OUT}" 2>/dev/null) || exit 1
[[ -z "${CLEAN}" || "${CLEAN}" == "null" ]] && exit 1

# Sanity check: required fields must be non-null.
jq -e '.risk != null and .confidence != null and .escalate_to_codex != null and .reason != null' \
   <<<"${CLEAN}" >/dev/null 2>&1 || exit 1

printf '%s\n' "${CLEAN}"
