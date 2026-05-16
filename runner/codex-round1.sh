#!/usr/bin/env bash
# runner/codex-round1.sh <cycle_id> <project_dir>
#
# v2.0 round 1 of a review cycle, schema-enforced.
#
# Codex runs in the user's REAL project directory with full access
# (--sandbox danger-full-access --ask-for-approval never). The "no project
# writes" rule is enforced in the system prompt (prompts/codex-system.md)
# and empirically verified by test/smoke-codex-respects-no-write-rule.sh.

set -uo pipefail

CYCLE_ID="$1"
PROJECT_DIR="$2"

CYCLE_DIR="${PROJECT_DIR}/.tdd/reviews/${CYCLE_ID}"
DIFF="${CYCLE_DIR}/diff.patch"
SCHEMA="${PROJECT_DIR}/schemas/findings-round1.schema.json"
SYSTEM_PROMPT="${PROJECT_DIR}/prompts/codex-system.md"
USER_TPL="${PROJECT_DIR}/prompts/codex-round1-user.md"

# --- read config ---
CONFIG="${PROJECT_DIR}/tdd-pack.toml"
toml_val() {
  awk -F' = ' "/^$1 =/ {gsub(/\"/,\"\",\$2); print \$2; exit}" "${CONFIG}"
}
MODEL=$(toml_val "model")
REASONING=$(toml_val "reasoning_effort")
WEB_SEARCH=$(toml_val "web_search")
REASONING="${REASONING:-high}"

# --- build user prompt by substituting templates ---
# v2.0.1 fix: use jq --rawfile instead of awk -v.
# awk -v passed via command line hits ARG_MAX for large diffs (~128KB on Linux,
# smaller on macOS). Real diffs commonly exceed this. jq --rawfile reads file
# content in jq's memory, no command-line size limit.
TREE_FILE=$(mktemp)
cd "${PROJECT_DIR}" && git ls-files 2>/dev/null | head -50 > "${TREE_FILE}"

USER_PROMPT=$(
  jq -rn \
    --rawfile diff "${DIFF}" \
    --rawfile tree "${TREE_FILE}" \
    --rawfile tpl  "${USER_TPL}" \
    '$tpl | gsub("\\{\\{DIFF\\}\\}"; $diff) | gsub("\\{\\{REPO_TREE\\}\\}"; $tree)'
)
rm -f "${TREE_FILE}"

# --- build codex flags ---
# v2.0.1 fix: --search is a TOP-LEVEL codex flag, not a `codex exec` flag.
# To enable live web search via `codex exec`, use the config override
# instead: -c web_search="live". This works on all subcommands and
# matches Codex's own internal config key name.
CODEX_FLAGS=()
[[ -n "${MODEL}" ]] && CODEX_FLAGS+=(--model "${MODEL}")
[[ "${WEB_SEARCH}" == "live" ]] && CODEX_FLAGS+=(-c "web_search=\"live\"")
CODEX_FLAGS+=(-c "model_reasoning_effort=\"${REASONING}\"")
# ★ CRITICAL: --sandbox danger-full-access is the CLI's way of saying
# "no sandbox". Without it, codex exec defaults to --sandbox read-only
# which blocks all command execution. See V2_IMPLEMENTATION_SPEC.md §8.
CODEX_FLAGS+=(--sandbox danger-full-access)
CODEX_FLAGS+=(--ask-for-approval never)
CODEX_FLAGS+=(--output-schema "${SCHEMA}")
CODEX_FLAGS+=(-o "${CYCLE_DIR}/round-1.json")
CODEX_FLAGS+=(--skip-git-repo-check)
CODEX_FLAGS+=(--cd "${PROJECT_DIR}")

# --- invoke ---
if ! codex exec "${CODEX_FLAGS[@]}" <<EOF
$(cat "${SYSTEM_PROMPT}")

---

${USER_PROMPT}
EOF
then
  echo "[codex-round1] ERROR: codex exec exited non-zero" >&2
  echo "failed:codex_exec_nonzero" > "${CYCLE_DIR}/.status"
  exit 1
fi

# --- capture session id (for codex exec resume in later rounds) ---
# Heuristic: most-recent rollout file in ~/.codex/sessions/.
# Brittle under concurrent Codex use; acceptable for v2.0.0. Better approach
# (v2.1.x backlog): parse `codex exec --json` for thread.started event.
SESSION_ID=$(
  find ~/.codex/sessions -name 'rollout-*.jsonl' -type f 2>/dev/null \
    | xargs -I{} ls -t {} 2>/dev/null \
    | head -1 \
    | xargs -I{} basename {} .jsonl 2>/dev/null \
    | sed 's/^rollout-//'
)
if [[ -n "${SESSION_ID}" ]]; then
  echo "${SESSION_ID}" > "${CYCLE_DIR}/codex-session-id"
fi

# --- validate output ---
if ! jq empty "${CYCLE_DIR}/round-1.json" 2>/dev/null; then
  echo "[codex-round1] ERROR: round-1.json is not valid JSON" >&2
  echo "failed:invalid_json" > "${CYCLE_DIR}/.status"
  exit 1
fi

# Validate required fields explicitly (defense vs openai/codex#15451).
if ! jq -e '.verdict and .findings and .summary_one_sentence' \
       "${CYCLE_DIR}/round-1.json" >/dev/null 2>&1; then
  echo "[codex-round1] ERROR: round-1.json missing required fields" >&2
  echo "failed:missing_fields" > "${CYCLE_DIR}/.status"
  exit 1
fi

VERDICT=$(jq -r '.verdict' "${CYCLE_DIR}/round-1.json")
case "${VERDICT}" in
  approve|request_changes) ;;
  *)
    echo "[codex-round1] ERROR: invalid verdict: ${VERDICT}" >&2
    echo "failed:invalid_verdict" > "${CYCLE_DIR}/.status"
    exit 1
    ;;
esac

exit 0
