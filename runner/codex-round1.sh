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

# --- detect Codex CLI capabilities + add --json if supported ---
# Task #103: prefer parsing session ID from structured --json events
# (first session_meta event has the UUID at .payload.id) over the
# brittle ~/.codex/sessions scraping heuristic. On older CLI without
# --json, fall back to the heuristic.
# shellcheck source=lib/codex-capabilities.sh
. "$(dirname "$0")/lib/codex-capabilities.sh"
codex_detect_capabilities "${PROJECT_DIR}"
HAS_JSON_EVENTS="$(codex_cap_supports supports_json "${PROJECT_DIR}")"

EVENTS_FILE=""
if [[ "${HAS_JSON_EVENTS}" == "true" ]]; then
  EVENTS_FILE="${CYCLE_DIR}/codex-events.jsonl"
  CODEX_FLAGS+=(--json)
fi

# v2.1 PR 7: MCP-detachment for the --output-schema call.
# openai/codex#15451 — when MCP servers/tools are active in user config,
# --output-schema is silently dropped and the response is unconstrained
# (malformed JSON, missing braces, markdown fences). --ignore-user-config
# skips $CODEX_HOME/config.toml on this invocation only; auth still works.
# Bug is marked closed upstream but no confirmed fix on 0.129.x; the flag
# is harmless when present even if the underlying bug is fixed, so we add
# it unconditionally when the CLI supports it.
HAS_IGNORE_USER_CFG="$(codex_cap_supports supports_ignore_user_config "${PROJECT_DIR}")"
if [[ "${HAS_IGNORE_USER_CFG}" == "true" ]]; then
  CODEX_FLAGS+=(--ignore-user-config)
fi

# --- invoke ---
# When --json is enabled, stdout becomes JSONL events; redirect to file.
# When not, stdout is unused (--output-schema + -o write to files).
if [[ -n "${EVENTS_FILE}" ]]; then
  if ! codex exec "${CODEX_FLAGS[@]}" <<EOF >"${EVENTS_FILE}" 2>>"${CYCLE_DIR}/codex-stderr.log"
$(cat "${SYSTEM_PROMPT}")

---

${USER_PROMPT}
EOF
  then
    echo "[codex-round1] ERROR: codex exec exited non-zero" >&2
    echo "failed:codex_exec_nonzero" > "${CYCLE_DIR}/.status"
    exit 1
  fi
else
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
fi

# --- capture session id ---
# Modern path: first event in --json output is `session_meta` with the
# session UUID at .payload.id. Robust under concurrent Codex use.
# Fallback (legacy CLI without --json): scrape ~/.codex/sessions for
# the most-recent rollout. Brittle (can pick wrong session) but the
# only option pre-0.125.
SESSION_ID=""
if [[ -n "${EVENTS_FILE}" ]] && [[ -s "${EVENTS_FILE}" ]]; then
  SESSION_ID=$(jq -r 'select(.type == "session_meta") | .payload.id' \
                  "${EVENTS_FILE}" 2>/dev/null | head -1)
fi
if [[ -z "${SESSION_ID}" ]]; then
  # shellcheck disable=SC2038
  # SC2038 — this fallback is exactly the old heuristic, kept only for
  # CLI versions without --json. Modern path above is preferred. Use
  # find -printf for proper time sort instead of `xargs ls -t` (which
  # doesn't actually sort across multiple files).
  SESSION_ID=$(
    find ~/.codex/sessions -name 'rollout-*.jsonl' -type f -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn \
      | head -1 \
      | awk '{print $2}' \
      | xargs -I{} basename {} .jsonl 2>/dev/null \
      | sed 's/^rollout-//'
  )
fi
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

# --- contract check: must_address vs verdict consistency ---
# Per tdd-pack.toml [severity] must_address: Codex MUST NOT return
# verdict=approve while leaving any finding at severity >= must_address
# unresolved. This is a contract Codex is asked to honor (see the
# system prompt). If violated, treat as a failed cycle — don't trust the
# approve and silently ship code with unaddressed blockers.
if [[ "${VERDICT}" == "approve" ]]; then
  # shellcheck source=lib/config.sh
  . "$(dirname "$0")/lib/config.sh"
  MUST_ADDRESS=$(cfg_get "${CONFIG}" "severity.must_address" "major")
  VIOLATIONS=$(jq -r --arg ma "${MUST_ADDRESS}" '
    def sn($s): {"blocker":4, "major":3, "minor":2, "nit":1}[$s];
    [.findings[]? | select(sn(.severity) >= sn($ma))] | length
  ' "${CYCLE_DIR}/round-1.json")
  if [[ "${VIOLATIONS:-0}" -gt 0 ]]; then
    echo "[codex-round1] CONTRACT VIOLATION: verdict=approve with ${VIOLATIONS} unresolved finding(s) at severity >= must_address (${MUST_ADDRESS})" >&2
    echo "failed:contract_violation_approve_with_must_address_findings" > "${CYCLE_DIR}/.status"
    exit 1
  fi
fi

exit 0
