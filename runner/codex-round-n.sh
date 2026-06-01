#!/usr/bin/env bash
# runner/codex-round-n.sh <cycle_id> <project_dir> <round_num>
#
# v2.0 Phase 2: rounds 2+ via `codex exec resume`.
#
# Per openai/codex#14343 and #12538, `codex exec resume` does NOT
# support `--output-schema` or `-o`. So we capture free-form stdout
# and rely on a VERDICT: APPROVE | REQUEST_CHANGES sentinel for the
# decision. extract-verdict.sh parses it.
#
# Same access profile as round 1: --dangerously-bypass-approvals-and-sandbox.
# The no-write rule lives in the system prompt (sticky across resume).

set -uo pipefail

CYCLE_ID="$1"
PROJECT_DIR="$2"
ROUND="$3"

CYCLE_DIR="${PROJECT_DIR}/.tdd/reviews/${CYCLE_ID}"
SESSION_FILE="${CYCLE_DIR}/codex-session-id"
USER_TPL="${PROJECT_DIR}/prompts/codex-round-n-user.md"
ROUND1_JSON="${CYCLE_DIR}/round-1.json"
RESPONSE_FILE="${CYCLE_DIR}/claude-response-${ROUND}.txt"
CONFIG="${PROJECT_DIR}/tdd-pack.toml"

# --- preflight ---
[[ -f "${SESSION_FILE}" ]] || { echo "[codex-round-n] missing session id" >&2; echo "failed:no_session" > "${CYCLE_DIR}/.status"; exit 1; }
[[ -f "${ROUND1_JSON}" ]]  || { echo "[codex-round-n] missing round-1.json" >&2; echo "failed:no_round1" > "${CYCLE_DIR}/.status"; exit 1; }
[[ -f "${RESPONSE_FILE}" ]] || { echo "[codex-round-n] missing ${RESPONSE_FILE}" >&2; echo "failed:no_response" > "${CYCLE_DIR}/.status"; exit 1; }

SESSION_ID=$(cat "${SESSION_FILE}")

# --- read config via shared parser ---
# shellcheck source=lib/config.sh
. "$(dirname "$0")/lib/config.sh"
MODEL=$(cfg_get "${CONFIG}" "codex.model" "")
WEB_SEARCH=$(cfg_get "${CONFIG}" "codex.web_search" "live")
MAX_ROUNDS=$(cfg_get "${CONFIG}" "review.max_rounds" "4")

# --- build prompt with jq --rawfile (avoids ARG_MAX on large diffs) ---

# OPEN_FINDINGS: blocker + major from round 1.
OPEN_FINDINGS_FILE=$(mktemp)
jq -r '
  [.findings[]? | select(.severity == "blocker" or .severity == "major")]
  | if length == 0 then "(no blocker/major findings remaining)"
    else map("- [\(.severity)/\(.category)] \(.title): \(.body)") | join("\n")
    end
' "${ROUND1_JSON}" > "${OPEN_FINDINGS_FILE}"

DIFF_FILE=$(mktemp)
git -C "${PROJECT_DIR}" diff HEAD > "${DIFF_FILE}" 2>/dev/null

PROMPT=$(
  jq -rn \
    --rawfile findings "${OPEN_FINDINGS_FILE}" \
    --rawfile response "${RESPONSE_FILE}" \
    --rawfile diff "${DIFF_FILE}" \
    --rawfile tpl "${USER_TPL}" \
    --arg round "${ROUND}" \
    --arg max "${MAX_ROUNDS}" \
    '$tpl
     | gsub("\\{\\{ROUND\\}\\}"; $round)
     | gsub("\\{\\{MAX_ROUNDS\\}\\}"; $max)
     | gsub("\\{\\{OPEN_FINDINGS\\}\\}"; $findings)
     | gsub("\\{\\{CLAUDE_RESPONSE\\}\\}"; $response)
     | gsub("\\{\\{CURRENT_DIFF\\}\\}"; $diff)'
)
rm -f "${OPEN_FINDINGS_FILE}" "${DIFF_FILE}"

# --- detect Codex CLI capabilities ---
# Task #103: prefer --output-last-message (-o) + --json (events to stdout)
# over stdout-as-text. On 0.129.0 both are supported on `codex exec resume`.
# On older CLI we fall back to current stdout-capture behavior.
# Note: --output-schema is still NOT supported on `codex exec resume` in
# 0.129.0 (openai/codex#14343), so round-N output stays free-form text
# with the VERDICT: sentinel; capability detector confirms this so we
# don't add --output-schema where it'd be dropped.
# shellcheck source=lib/codex-capabilities.sh
. "$(dirname "$0")/lib/codex-capabilities.sh"
codex_detect_capabilities "${PROJECT_DIR}"
HAS_LAST_MSG="$(codex_cap_supports supports_output_last_message "${PROJECT_DIR}")"
HAS_JSON_EVENTS="$(codex_cap_supports supports_json "${PROJECT_DIR}")"

# --- build codex flags ---
CODEX_FLAGS=()
[[ -n "${MODEL}" ]] && CODEX_FLAGS+=(--model "${MODEL}")
[[ "${WEB_SEARCH}" == "live" ]] && CODEX_FLAGS+=(-c "web_search=\"live\"")
CODEX_FLAGS+=(--dangerously-bypass-approvals-and-sandbox)

ROUND_TXT="${CYCLE_DIR}/round-${ROUND}.txt"
EVENTS_FILE=""
if [[ "${HAS_LAST_MSG}" == "true" ]]; then
  CODEX_FLAGS+=(-o "${ROUND_TXT}")
fi
if [[ "${HAS_JSON_EVENTS}" == "true" ]]; then
  EVENTS_FILE="${CYCLE_DIR}/codex-events-round-${ROUND}.jsonl"
  CODEX_FLAGS+=(--json)
fi

# --- invoke ---
# Three paths depending on capability detection:
#   1. --json + -o : stdout → events file, last message → ROUND_TXT
#   2. -o only     : stdout discarded, last message → ROUND_TXT
#   3. neither     : stdout → ROUND_TXT (current behavior)
RC=0
if [[ -n "${EVENTS_FILE}" ]]; then
  codex exec resume "${SESSION_ID}" "${CODEX_FLAGS[@]}" "${PROMPT}" \
    > "${EVENTS_FILE}" \
    2>>"${CYCLE_DIR}/codex-stderr.log" || RC=$?
elif [[ "${HAS_LAST_MSG}" == "true" ]]; then
  codex exec resume "${SESSION_ID}" "${CODEX_FLAGS[@]}" "${PROMPT}" \
    > /dev/null \
    2>>"${CYCLE_DIR}/codex-stderr.log" || RC=$?
else
  codex exec resume "${SESSION_ID}" "${CODEX_FLAGS[@]}" "${PROMPT}" \
    > "${ROUND_TXT}" \
    2>>"${CYCLE_DIR}/codex-stderr.log" || RC=$?
fi

if [[ "${RC}" -ne 0 ]]; then
  echo "[codex-round-n] codex exec resume exited non-zero" >&2
  echo "failed:codex_resume_nonzero" > "${CYCLE_DIR}/.status"
  exit 1
fi

if [[ ! -s "${ROUND_TXT}" ]]; then
  echo "[codex-round-n] round ${ROUND} produced no output at ${ROUND_TXT}" >&2
  echo "failed:empty_output" > "${CYCLE_DIR}/.status"
  exit 1
fi

exit 0
