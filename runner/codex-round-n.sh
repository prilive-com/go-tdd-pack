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

# --- preflight ---
[[ -f "${SESSION_FILE}" ]] || { echo "[codex-round-n] missing session id" >&2; echo "failed:no_session" > "${CYCLE_DIR}/.status"; exit 1; }
[[ -f "${ROUND1_JSON}" ]]  || { echo "[codex-round-n] missing round-1.json" >&2; echo "failed:no_round1" > "${CYCLE_DIR}/.status"; exit 1; }
[[ -f "${RESPONSE_FILE}" ]] || { echo "[codex-round-n] missing ${RESPONSE_FILE}" >&2; echo "failed:no_response" > "${CYCLE_DIR}/.status"; exit 1; }

SESSION_ID=$(cat "${SESSION_FILE}")

# --- read config ---
CONFIG="${PROJECT_DIR}/tdd-pack.toml"
toml_val() {
  awk -F' = ' "/^$1 =/ {gsub(/\"/,\"\",\$2); print \$2; exit}" "${CONFIG}"
}
MODEL=$(toml_val "model")
WEB_SEARCH=$(toml_val "web_search")
MAX_ROUNDS=$(awk -F' = ' '/^max_rounds =/ {print $2; exit}' "${CONFIG}" | tr -d ' ')
MAX_ROUNDS="${MAX_ROUNDS:-4}"

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

# --- build codex flags (same as round 1) ---
CODEX_FLAGS=()
[[ -n "${MODEL}" ]] && CODEX_FLAGS+=(--model "${MODEL}")
[[ "${WEB_SEARCH}" == "live" ]] && CODEX_FLAGS+=(-c "web_search=\"live\"")
# NOTE: No --output-schema, no -o. Per openai/codex#14343 and #12538,
# these are silently dropped on `codex exec resume`. We capture stdout
# and parse VERDICT: ... via extract-verdict.sh.
# NOTE: No --skip-git-repo-check, no --cd. The resumed session
# inherits the cwd and project context of the original `codex exec`.
CODEX_FLAGS+=(--dangerously-bypass-approvals-and-sandbox)

# --- invoke (capture stdout to round-N.txt) ---
if ! codex exec resume "${SESSION_ID}" "${CODEX_FLAGS[@]}" "${PROMPT}" \
       > "${CYCLE_DIR}/round-${ROUND}.txt" \
       2>>"${CYCLE_DIR}/codex-stderr.log"; then
  echo "[codex-round-n] codex exec resume exited non-zero" >&2
  echo "failed:codex_resume_nonzero" > "${CYCLE_DIR}/.status"
  exit 1
fi

if [[ ! -s "${CYCLE_DIR}/round-${ROUND}.txt" ]]; then
  echo "[codex-round-n] round ${ROUND} produced no output" >&2
  echo "failed:empty_output" > "${CYCLE_DIR}/.status"
  exit 1
fi

exit 0
