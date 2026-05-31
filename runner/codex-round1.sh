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
# Send only changed file paths for orientation. The full repo tree is
# attention dilution per current evidence; Codex can `git ls-files`
# itself if it wants the whole layout.
cd "${PROJECT_DIR}" && git diff --name-only HEAD 2>/dev/null > "${TREE_FILE}"

# Tool grounding — pre-execute go vet, gofmt -l, staticcheck,
# golangci-lint, govulncheck (each skipped silently if not installed).
# Output is markdown, included verbatim in the user prompt. Best-effort:
# script always exits 0.
TOOLS_FILE=$(mktemp)
"${PROJECT_DIR}/runner/tool-grounding.sh" "${PROJECT_DIR}" > "${TOOLS_FILE}" 2>/dev/null || true

USER_PROMPT=$(
  jq -rn \
    --rawfile diff  "${DIFF}" \
    --rawfile tree  "${TREE_FILE}" \
    --rawfile tools "${TOOLS_FILE}" \
    --rawfile tpl   "${USER_TPL}" \
    '$tpl
     | gsub("\\{\\{DIFF\\}\\}";            $diff)
     | gsub("\\{\\{REPO_TREE\\}\\}";       $tree)
     | gsub("\\{\\{TOOL_GROUNDING\\}\\}";  $tools)'
)
rm -f "${TREE_FILE}" "${TOOLS_FILE}"

# --- build codex flags ---
# v2.0.2 fix: --ask-for-approval and --search are TOP-LEVEL codex flags,
# not `codex exec` flags. Use --dangerously-bypass-approvals-and-sandbox
# instead — single flag that bypasses BOTH the sandbox AND approvals,
# which is exactly the semantics we want (no sandbox + no approval gates,
# matching Claude's environment). Web search uses the -c config override
# that works on any subcommand.
#
# Verified via `codex exec --help` on codex-cli 0.129.0:
#   * --sandbox <SANDBOX_MODE>                          (subcommand flag)
#   * --dangerously-bypass-approvals-and-sandbox        (subcommand flag)
#   * --ask-for-approval                                NOT a subcommand flag
#   * --search                                          NOT a subcommand flag
CODEX_FLAGS=()
[[ -n "${MODEL}" ]] && CODEX_FLAGS+=(--model "${MODEL}")
[[ "${WEB_SEARCH}" == "live" ]] && CODEX_FLAGS+=(-c "web_search=\"live\"")
CODEX_FLAGS+=(-c "model_reasoning_effort=\"${REASONING}\"")
# ★ CRITICAL: bypass sandbox AND approvals. Single flag, same semantics
# as user's "Codex runs in real environment like Claude" requirement.
CODEX_FLAGS+=(--dangerously-bypass-approvals-and-sandbox)
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
# tracked in task #103 (v2.1.0 Codex modernization): parse
# `codex exec --json` for thread.started event.
# shellcheck disable=SC2038
# (SC2038 flags find|xargs without -print0/-0; the whole pipeline is
# planned for replacement per task #103, so don't bother fixing here.)
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
