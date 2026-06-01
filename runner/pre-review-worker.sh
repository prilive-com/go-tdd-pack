#!/usr/bin/env bash
# runner/pre-review-worker.sh <project_dir>
#
# Task #109 sub-piece #3 — verdict producer for the pre-review queue.
#
# Watches .tdd/queue/*.submission.json files written by
# hooks/pre-review.sh. For each submission without a verdict, runs Codex
# with the pre-review prompt for that payload `kind`
# (file_change | bash_command) and writes
# .tdd/queue/<hash>.verdict.json. The hook (still polling) picks up the
# verdict file and emits the matching permissionDecision.
#
# Single-instance via flock on .tdd/queue/.worker.lock. Idempotent: if
# a verdict already exists for a submission, the worker skips it.
#
# Drain semantics: process every pending submission, then idle for a
# bounded number of rounds in case more arrive, then exit. The hook
# re-launches a fresh worker on the next submission, so the worker
# never has to run forever.
#
# IPC choice: file-based, not Unix socket. File-IPC matches what
# hooks/pre-review.sh already polls, stays portable across Linux/macOS,
# and is correct for the cycle-volume we expect. A socket layer can be
# added later if polling overhead becomes a measurable problem; the
# hook protocol does not change.

set -uo pipefail

PROJECT_DIR="${1:-${CLAUDE_PROJECT_DIR:-}}"
if [[ -z "${PROJECT_DIR}" ]]; then
  echo "[pre-review-worker] BLOCKED: PROJECT_DIR not set" >&2
  exit 2
fi

TDD_DIR="${PROJECT_DIR}/.tdd"
QUEUE_DIR="${TDD_DIR}/queue"
LOG="${TDD_DIR}/pre-review-worker.log"
LOCK="${QUEUE_DIR}/.worker.lock"
SCHEMA="${PROJECT_DIR}/schemas/pre-review-verdict.schema.json"
SYS_PROMPT="${PROJECT_DIR}/prompts/codex-pre-review-system.md"
FILE_USER_TPL="${PROJECT_DIR}/prompts/codex-pre-review-file-user.md"
BASH_USER_TPL="${PROJECT_DIR}/prompts/codex-pre-review-bash-user.md"
CONFIG="${PROJECT_DIR}/tdd-pack.toml"

mkdir -p "${QUEUE_DIR}" "${TDD_DIR}" 2>/dev/null

# Global kill switch (same lever as the rest of the pack).
if [[ "${PRILIVE_REVIEW_DISABLE:-0}" == "1" ]]; then
  exit 0
fi

# Single-instance — second launcher exits immediately, first drains.
exec 9>"${LOCK}"
if ! flock -n 9; then
  exit 0
fi

log() {
  local ts; ts=$(date -u +%FT%TZ 2>/dev/null || echo unknown)
  echo "[${ts}] $*" >> "${LOG}" 2>/dev/null
}

log "worker started"

# --- dependencies ---------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
  log "jq not installed — exiting (hooks will time out and deny)"
  exit 0
fi

if ! command -v codex >/dev/null 2>&1; then
  log "codex CLI not in PATH — exiting (hooks will time out and deny)"
  exit 0
fi

# Capability detection (task #103 — reused as-is).
# shellcheck source=lib/codex-capabilities.sh
. "$(dirname "$0")/lib/codex-capabilities.sh"
codex_detect_capabilities "${PROJECT_DIR}"
HAS_LAST_MSG="$(codex_cap_supports supports_output_last_message "${PROJECT_DIR}")"
HAS_SCHEMA_EXEC="$(codex_cap_supports supports_output_schema_exec "${PROJECT_DIR}")"

# Config (model, reasoning, web_search) — falls back to codex-cli's own
# defaults if the field is absent.
# shellcheck source=lib/config.sh
. "$(dirname "$0")/lib/config.sh"
MODEL=$(cfg_get "${CONFIG}" "codex.model" "")
REASONING=$(cfg_get "${CONFIG}" "codex.reasoning_effort" "high")
WEB_SEARCH=$(cfg_get "${CONFIG}" "codex.web_search" "live")

# --- helpers --------------------------------------------------------------

# write_verdict <verdict_path> <decision> <classification> <reason> <findings_json>
write_verdict() {
  local path="$1" decision="$2" classification="$3" reason="$4" findings="$5"
  jq -n \
    --arg d "${decision}" \
    --arg c "${classification}" \
    --arg r "${reason}" \
    --argjson f "${findings}" \
    '{decision:$d, classification:$c, reason:$r, findings:$f}' \
    > "${path}.tmp" 2>/dev/null \
    && mv "${path}.tmp" "${path}"
}

# process_submission <submission_path> <verdict_path>
process_submission() {
  local sub="$1" verdict="$2"
  local hash; hash=$(basename "${sub}" .submission.json)
  log "processing ${hash}"

  local kind
  kind=$(jq -r '.payload.kind // empty' "${sub}" 2>/dev/null)
  case "${kind}" in
    file_change|bash_command) ;;
    *)
      log "${hash}: unknown payload kind '${kind}' — deny"
      write_verdict "${verdict}" deny "state_changing" \
        "pre-review worker: unknown payload kind '${kind}'" "[]"
      return 0
      ;;
  esac

  # Pick the right user template per kind.
  local user_tpl
  if [[ "${kind}" == "file_change" ]]; then
    user_tpl="${FILE_USER_TPL}"
  else
    user_tpl="${BASH_USER_TPL}"
  fi

  if [[ ! -f "${SYS_PROMPT}" ]] || [[ ! -f "${user_tpl}" ]] || [[ ! -f "${SCHEMA}" ]]; then
    log "${hash}: missing prompt or schema files — deny"
    write_verdict "${verdict}" deny "state_changing" \
      "pre-review worker: prompt or schema files missing (broken install)" "[]"
    return 0
  fi

  # Build user prompt by substituting the payload JSON into the template.
  # jq --rawfile avoids ARG_MAX limits on large payloads.
  local payload_json; payload_json=$(jq -c '.payload' "${sub}" 2>/dev/null)
  local user_prompt
  user_prompt=$(jq -rn \
    --rawfile tpl "${user_tpl}" \
    --arg payload "${payload_json}" \
    '$tpl | gsub("\\{\\{PAYLOAD\\}\\}"; $payload)')

  # Output capture.
  local out_tmp stderr_tmp
  out_tmp=$(mktemp 2>/dev/null) || out_tmp="${QUEUE_DIR}/${hash}.codex-out.tmp"
  stderr_tmp=$(mktemp 2>/dev/null) || stderr_tmp="${QUEUE_DIR}/${hash}.codex-err.tmp"

  # Build codex flags. Matches runner/codex-round1.sh — full access,
  # bypass approvals + sandbox (same semantics as the existing review path).
  local codex_flags=()
  [[ -n "${MODEL}" ]] && codex_flags+=(--model "${MODEL}")
  [[ "${WEB_SEARCH}" == "live" ]] && codex_flags+=(-c "web_search=\"live\"")
  codex_flags+=(-c "model_reasoning_effort=\"${REASONING}\"")
  codex_flags+=(--dangerously-bypass-approvals-and-sandbox)
  if [[ "${HAS_SCHEMA_EXEC}" == "true" ]]; then
    codex_flags+=(--output-schema "${SCHEMA}")
  fi
  if [[ "${HAS_LAST_MSG}" == "true" ]]; then
    codex_flags+=(-o "${out_tmp}")
  fi
  codex_flags+=(--skip-git-repo-check)
  codex_flags+=(--cd "${PROJECT_DIR}")

  if ! codex exec "${codex_flags[@]}" 2>"${stderr_tmp}" <<EOF
$(cat "${SYS_PROMPT}")

---

${user_prompt}
EOF
  then
    log "${hash}: codex exec non-zero; stderr follows"
    cat "${stderr_tmp}" >> "${LOG}" 2>/dev/null
    write_verdict "${verdict}" deny "state_changing" \
      "pre-review: Codex returned non-zero. Check .tdd/pre-review-worker.log." "[]"
    rm -f "${out_tmp}" "${stderr_tmp}"
    return 0
  fi

  # Without --output-last-message support we have no clean place to
  # find the JSON response. Older Codex CLIs print free-form text to
  # stdout, which is unreliable to parse. Treat as deny and tell the
  # adopter to upgrade.
  if [[ "${HAS_LAST_MSG}" != "true" ]]; then
    log "${hash}: --output-last-message unsupported on installed Codex — deny"
    write_verdict "${verdict}" deny "state_changing" \
      "pre-review: installed Codex CLI does not support --output-last-message. Upgrade Codex CLI." "[]"
    rm -f "${out_tmp}" "${stderr_tmp}"
    return 0
  fi

  if [[ ! -s "${out_tmp}" ]]; then
    log "${hash}: Codex output empty"
    write_verdict "${verdict}" deny "state_changing" \
      "pre-review: Codex produced empty output. Check .tdd/pre-review-worker.log." "[]"
    rm -f "${out_tmp}" "${stderr_tmp}"
    return 0
  fi

  if ! jq empty "${out_tmp}" 2>/dev/null; then
    log "${hash}: Codex output not valid JSON"
    write_verdict "${verdict}" deny "state_changing" \
      "pre-review: Codex output was not valid JSON" "[]"
    rm -f "${out_tmp}" "${stderr_tmp}"
    return 0
  fi

  local decision classification reason findings
  decision=$(jq -r '.decision // "deny"' "${out_tmp}")
  classification=$(jq -r '.classification // "state_changing"' "${out_tmp}")
  reason=$(jq -r '.reason // ""' "${out_tmp}")
  findings=$(jq -c '.findings // []' "${out_tmp}")

  case "${decision}" in
    allow|deny|ask) ;;
    *)
      decision="deny"
      reason="pre-review: Codex returned unknown decision; treating as deny."
      ;;
  esac
  case "${classification}" in
    read_only|state_changing|file_change) ;;
    *)
      classification="state_changing"
      ;;
  esac

  write_verdict "${verdict}" "${decision}" "${classification}" "${reason}" "${findings}"
  log "${hash}: verdict=${decision} classification=${classification}"

  rm -f "${out_tmp}" "${stderr_tmp}"
}

# --- drain loop -----------------------------------------------------------
# Process every pending submission, then idle briefly to catch
# late-arriving submissions from concurrent hook fires, then exit. Hook
# re-launches a fresh worker on the next submission.

IDLE_ROUNDS=0
MAX_IDLE_ROUNDS="${PRILIVE_PRE_REVIEW_WORKER_IDLE_ROUNDS:-4}"
IDLE_SLEEP_S="${PRILIVE_PRE_REVIEW_WORKER_IDLE_S:-0.5}"

while true; do
  PROCESSED=0
  shopt -s nullglob
  for sub in "${QUEUE_DIR}"/*.submission.json; do
    hash=$(basename "${sub}" .submission.json)
    verdict="${QUEUE_DIR}/${hash}.verdict.json"
    [[ -f "${verdict}" ]] && continue
    process_submission "${sub}" "${verdict}"
    PROCESSED=$((PROCESSED + 1))
  done
  shopt -u nullglob

  if [[ "${PROCESSED}" -eq 0 ]]; then
    IDLE_ROUNDS=$((IDLE_ROUNDS + 1))
    if [[ "${IDLE_ROUNDS}" -ge "${MAX_IDLE_ROUNDS}" ]]; then
      break
    fi
    sleep "${IDLE_SLEEP_S}"
  else
    IDLE_ROUNDS=0
  fi
done

log "worker idle — exiting"
exit 0
