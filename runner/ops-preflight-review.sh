#!/usr/bin/env bash
# runner/ops-preflight-review.sh
#
# v2.2 slice 4 — Layer 3 Codex deep ops-safety review.
#
# Invoked by the /ops-preflight skill (manual, disable-model-invocation:
# true) after Layer 2 escalated a command. NOT in the hot path of the
# PreToolUse hook — this is an on-demand deep review the operator
# explicitly asks for.
#
# Reads a JSON context object on stdin:
#   {
#     "command":     "docker compose up -d --build ainews-processor",
#     "service":     "ainews-processor",
#     "environment": "prod-like",
#     "files":       ["docker-compose.yml", ".env"],
#     "tags":        ["auth","container_uid"],
#     "status":      "running, healthy",
#     "logs":        "...recent log tail...",
#     "uid_notes":   "container expects UID 1001",
#     "rollback":    "docker compose up -d <previous_image>"
#   }
#
# All fields except `command` are optional and default to "unknown".
#
# Writes the accepted verdict to .tdd/ops-preflight/<sha256(command)>.json
# (the artifact governed mode (slice 5) will gate on for destructive
# commands). Verdict object conforms to schemas/ops-preflight-verdict.schema.json.
#
# Returns the verdict JSON on stdout. Exits 0 on success; non-zero on
# failure (missing codex CLI, ANTHROPIC_API_KEY / codex login problems,
# malformed verdict).
#
# Test injection: PRILIVE_OPS_PREFLIGHT_BIN env var overrides the codex
# call with a user-provided stub. Smokes use this to avoid burning real
# Codex tokens.

set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PROMPT_FILE="${ROOT}/prompts/codex-ops-preflight.md"
SCHEMA_FILE="${ROOT}/schemas/ops-preflight-verdict.schema.json"
ARTIFACT_DIR="${PROJECT_DIR}/.tdd/ops-preflight"

command -v jq >/dev/null 2>&1 || { echo "ops-preflight-review: jq required" >&2; exit 1; }
[[ -f "${PROMPT_FILE}" ]] || { echo "ops-preflight-review: prompt missing: ${PROMPT_FILE}" >&2; exit 1; }
[[ -f "${SCHEMA_FILE}" ]] || { echo "ops-preflight-review: schema missing: ${SCHEMA_FILE}" >&2; exit 1; }

CTX=$(cat 2>/dev/null || true)
[[ -z "${CTX}" ]] && { echo "ops-preflight-review: empty stdin (need JSON context)" >&2; exit 1; }

CMD=$(jq -r '.command // empty' <<<"${CTX}" 2>/dev/null)
[[ -z "${CMD}" ]] && { echo "ops-preflight-review: .command is required in stdin context" >&2; exit 1; }

# Pull optional context fields with sane defaults.
SERVICE=$(jq -r '.service     // "unknown"' <<<"${CTX}" 2>/dev/null)
ENVIRO=$(jq -r '.environment // "unknown"' <<<"${CTX}" 2>/dev/null)
FILES=$(jq -r '(.files       // []) | join(", ")' <<<"${CTX}" 2>/dev/null)
TAGS=$(jq -r '(.tags          // []) | join(", ")' <<<"${CTX}" 2>/dev/null)
STATUS=$(jq -r '.status       // "unknown"' <<<"${CTX}" 2>/dev/null)
LOGS=$(jq -r '.logs           // "none provided"' <<<"${CTX}" 2>/dev/null)
UID_NOTES=$(jq -r '.uid_notes // "none provided"' <<<"${CTX}" 2>/dev/null)
ROLLBACK=$(jq -r '.rollback   // "none provided"' <<<"${CTX}" 2>/dev/null)

# Build the prompt from the template. Use awk so command/context strings
# with `&` or `\` are safe (sed would mis-interpret them).
PROMPT=$(awk \
  -v cmd="${CMD}" -v svc="${SERVICE}" -v env="${ENVIRO}" -v files="${FILES}" \
  -v tags="${TAGS}" -v status="${STATUS}" -v logs="${LOGS}" \
  -v uid="${UID_NOTES}" -v rb="${ROLLBACK}" '
{
  gsub(/<<<COMMAND>>>/,    cmd)
  gsub(/<<<SERVICE>>>/,    svc)
  gsub(/<<<ENVIRONMENT>>>/,env)
  gsub(/<<<FILES>>>/,      files)
  gsub(/<<<TAGS>>>/,       tags)
  gsub(/<<<STATUS>>>/,     status)
  gsub(/<<<LOGS>>>/,       logs)
  gsub(/<<<UID_NOTES>>>/,  uid)
  gsub(/<<<ROLLBACK>>>/,   rb)
  print
}' "${PROMPT_FILE}")

# --- run the reviewer -----------------------------------------------------
OUT=""
if [[ -n "${PRILIVE_OPS_PREFLIGHT_BIN:-}" \
   && -x "${PRILIVE_OPS_PREFLIGHT_BIN}" ]]; then
  # Test injection — stub returns canned verdict from the prompt.
  OUT=$(printf '%s' "${PROMPT}" | "${PRILIVE_OPS_PREFLIGHT_BIN}" 2>/dev/null)
else
  command -v codex >/dev/null 2>&1 \
    || { echo "ops-preflight-review: codex CLI not on PATH" >&2; exit 1; }
  # --ignore-user-config detaches MCP servers so --output-schema is not
  # silently dropped (openai/codex#15451). Validate the output anyway —
  # v2.1.0 Bug 1 lesson.
  OUT=$(printf '%s' "${PROMPT}" | timeout 60 codex exec \
          --ignore-user-config \
          --output-schema "${SCHEMA_FILE}" \
          -o /dev/stdout 2>/dev/null) || exit 1
fi

# Strip accidental code fences if any.
OUT=$(sed -E 's/^```[a-z]*//; s/```$//' <<<"${OUT}" | tr -d '\r')

# Validate verdict shape. Required keys must be present and non-null.
# Each jq expression uses explicit parens around the type/length checks
# because the `|` (pipe) binds tighter than `and` in jq — without parens,
# `(.findings // []) | type == "array"` applies to the boolean result of
# the preceding `and` chain, not to .findings.
jq -e '
  (.verdict   != null)
  and (.risk  != null)
  and ((.findings // []) | type == "array")
' <<<"${OUT}" >/dev/null 2>&1 \
  || { echo "ops-preflight-review: malformed verdict from reviewer" >&2; exit 1; }
jq -e '((.required_prechecks  // []) | type == "array")' <<<"${OUT}" >/dev/null 2>&1 \
  || { echo "ops-preflight-review: required_prechecks must be array" >&2; exit 1; }
jq -e '((.required_postchecks // []) | type == "array")' <<<"${OUT}" >/dev/null 2>&1 \
  || { echo "ops-preflight-review: required_postchecks must be array" >&2; exit 1; }
jq -e '((.rollback            // []) | type == "array")' <<<"${OUT}" >/dev/null 2>&1 \
  || { echo "ops-preflight-review: rollback must be array" >&2; exit 1; }
jq -e '
  (.human_summary != null)
  and ((.human_summary | length) > 0)
' <<<"${OUT}" >/dev/null 2>&1 \
  || { echo "ops-preflight-review: human_summary is required" >&2; exit 1; }

# --- write the artifact (the gate slice 5 will check) --------------------
mkdir -p "${ARTIFACT_DIR}" 2>/dev/null
HASH=$(printf '%s' "${CMD}" | sha256sum | cut -d' ' -f1)
ARTIFACT="${ARTIFACT_DIR}/${HASH}.json"

# Stamp the artifact with the proposing command + a timestamp + the
# raw verdict. Governed mode (slice 5) reads this and only honors
# verdicts of approve / approve_with_checks.
jq -nc \
   --arg cmd "${CMD}" \
   --arg hash "sha256:${HASH}" \
   --arg ts "$(date -u +%FT%TZ)" \
   --argjson verdict "${OUT}" \
   '{command:$cmd, command_hash:$hash, decided_at:$ts, verdict:$verdict}' \
   > "${ARTIFACT}" 2>/dev/null \
  || { echo "ops-preflight-review: failed to write artifact ${ARTIFACT}" >&2; exit 1; }

# Echo the verdict on stdout for the caller (the skill / operator).
printf '%s\n' "${OUT}"
