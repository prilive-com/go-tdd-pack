#!/usr/bin/env bash
# runner/review-runner.sh <project_dir>
#
# v2.0 Phase 2 orchestrator. Two entry modes:
#
#   1. Fresh cycle: working tree is dirty, no in-progress cycle.
#      → coalesce → snapshot diff → run round 1 → on request_changes,
#        wait for Claude's next response (will be re-fired by Stop hook).
#
#   2. Resume: state.json shows status=request_changes for some cycle,
#      AND that cycle has a claude-response-${next_round}.txt waiting
#      (written by stop-fingerprint.sh from the transcript).
#      → skip coalesce + diff check + round 1 entirely
#      → jump straight into the rounds 2..MAX loop.
#
# Either way: each round 2+ invocation runs at most one round and exits.
# The next round happens on the next invocation (next Stop hook fire
# after Claude's next response). This keeps each runner call short and
# avoids the runner trying to chain rounds across separate Claude turns.

set -uo pipefail

PROJECT_DIR="${1:-${CLAUDE_PROJECT_DIR:-}}"
if [[ -z "${PROJECT_DIR}" ]]; then
  echo "[review-runner] BLOCKED: PROJECT_DIR not set" >&2
  exit 2
fi

TDD_DIR="${PROJECT_DIR}/.tdd"
REVIEWS_DIR="${TDD_DIR}/reviews"
CONFIG="${PROJECT_DIR}/tdd-pack.toml"
STATE_FILE="${REVIEWS_DIR}/state.json"

mkdir -p "${REVIEWS_DIR}"

# --- single-flight via flock ---
LOCK_FILE="${TDD_DIR}/runner.lock"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  exit 0   # another runner already in flight
fi

# --- emergency disable ---
if [[ "${PRILIVE_REVIEW_DISABLE:-0}" == "1" ]]; then
  exit 0
fi

# --- helpers ---
update_state() {
  local cycle="$1" status="$2" round="$3"
  local ts; ts=$(date -u +%FT%TZ 2>/dev/null || echo unknown)
  jq -n \
    --arg cycle "${cycle}" \
    --arg status "${status}" \
    --argjson round "${round}" \
    --arg ts "${ts}" \
    '{cycle_id:$cycle, status:$status, round:$round, updated_at:$ts}' \
    > "${STATE_FILE}.tmp" 2>/dev/null \
    && mv "${STATE_FILE}.tmp" "${STATE_FILE}"
}

log_event() {
  local cycle="$1" round="$2" event="$3"
  local ts; ts=$(date -u +%FT%TZ 2>/dev/null || echo unknown)
  jq -nc \
    --arg cycle "${cycle}" \
    --arg ts "${ts}" \
    --argjson round "${round}" \
    --arg event "${event}" \
    '{cycle_id:$cycle, ts:$ts, round:$round, event:$event}' \
    >> "${REVIEWS_DIR}/debates.jsonl" 2>/dev/null
}

# --- detect resume condition ---
RESUME_CYCLE_ID=""
RESUME_FROM_ROUND=0
if [[ -f "${STATE_FILE}" ]] && command -v jq >/dev/null 2>&1; then
  EXISTING_STATUS=$(jq -r '.status // empty' "${STATE_FILE}" 2>/dev/null)
  EXISTING_CYCLE=$(jq -r '.cycle_id // empty' "${STATE_FILE}" 2>/dev/null)
  EXISTING_ROUND=$(jq -r '.round // 0' "${STATE_FILE}" 2>/dev/null)
  if [[ "${EXISTING_STATUS}" == "request_changes" ]] && [[ -n "${EXISTING_CYCLE}" ]]; then
    NEXT_ROUND=$((EXISTING_ROUND + 1))
    EXISTING_DIR="${REVIEWS_DIR}/${EXISTING_CYCLE}"
    if [[ -d "${EXISTING_DIR}" ]] && [[ -f "${EXISTING_DIR}/claude-response-${NEXT_ROUND}.txt" ]]; then
      RESUME_CYCLE_ID="${EXISTING_CYCLE}"
      RESUME_FROM_ROUND="${NEXT_ROUND}"
    fi
  fi
fi

# --- branch: resume vs fresh ---
if [[ -n "${RESUME_CYCLE_ID}" ]]; then
  # Resume — skip coalesce + clean-tree check + round 1.
  CYCLE_ID="${RESUME_CYCLE_ID}"
  CYCLE_DIR="${REVIEWS_DIR}/${CYCLE_ID}"
  START_ROUND="${RESUME_FROM_ROUND}"
else
  # Fresh — coalesce, check clean tree, mint cycle, run round 1.

  COALESCE_MS=5000
  if [[ -f "${CONFIG}" ]]; then
    CFG_COALESCE=$(awk -F' = ' '/^coalesce_ms =/ {print $2; exit}' "${CONFIG}" | tr -d ' ')
    [[ "${CFG_COALESCE}" =~ ^[0-9]+$ ]] && COALESCE_MS="${CFG_COALESCE}"
  fi
  "${PROJECT_DIR}/runner/coalesce.sh" "${PROJECT_DIR}" "${COALESCE_MS}"

  if cd "${PROJECT_DIR}" && git diff --quiet HEAD 2>/dev/null; then
    exit 0   # no uncommitted changes
  fi

  CYCLE_ID="cycle-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  CYCLE_DIR="${REVIEWS_DIR}/${CYCLE_ID}"
  mkdir -p "${CYCLE_DIR}"

  git -C "${PROJECT_DIR}" diff HEAD > "${CYCLE_DIR}/diff.patch" 2>/dev/null

  update_state "${CYCLE_ID}" "reviewing" 1
  log_event "${CYCLE_ID}" 1 "started"

  if ! "${PROJECT_DIR}/runner/codex-round1.sh" "${CYCLE_ID}" "${PROJECT_DIR}"; then
    STATUS_DETAIL=$(cat "${CYCLE_DIR}/.status" 2>/dev/null || echo "failed")
    update_state "${CYCLE_ID}" "failed" 1
    log_event "${CYCLE_ID}" 1 "${STATUS_DETAIL}"
    exit 0
  fi

  VERDICT=$(jq -r '.verdict' "${CYCLE_DIR}/round-1.json" 2>/dev/null || echo unknown)
  log_event "${CYCLE_ID}" 1 "verdict:${VERDICT}"

  if [[ "${VERDICT}" == "approve" ]]; then
    update_state "${CYCLE_ID}" "converged" 1
    log_event "${CYCLE_ID}" 1 "converged"
    exit 0
  fi

  # request_changes — record and wait for Claude's response.
  update_state "${CYCLE_ID}" "request_changes" 1
  exit 0
fi

# ---- rounds START_ROUND..MAX_ROUNDS (resume path only) ----

MAX_ROUNDS=$(awk -F' = ' '/^max_rounds =/ {print $2; exit}' "${CONFIG}" | tr -d ' ')
MAX_ROUNDS="${MAX_ROUNDS:-4}"

for ROUND in $(seq "${START_ROUND}" "${MAX_ROUNDS}"); do
  RESPONSE_FILE="${CYCLE_DIR}/claude-response-${ROUND}.txt"
  if [[ ! -f "${RESPONSE_FILE}" ]]; then
    # No response yet for this round — wait for next Stop hook fire.
    update_state "${CYCLE_ID}" "request_changes" "$((ROUND - 1))"
    exit 0
  fi

  update_state "${CYCLE_ID}" "reviewing" "${ROUND}"
  log_event "${CYCLE_ID}" "${ROUND}" "started"

  if ! "${PROJECT_DIR}/runner/codex-round-n.sh" "${CYCLE_ID}" "${PROJECT_DIR}" "${ROUND}"; then
    STATUS_DETAIL=$(cat "${CYCLE_DIR}/.status" 2>/dev/null || echo "failed")
    update_state "${CYCLE_ID}" "failed" "${ROUND}"
    log_event "${CYCLE_ID}" "${ROUND}" "${STATUS_DETAIL}"
    exit 0
  fi

  VERDICT=$("${PROJECT_DIR}/runner/extract-verdict.sh" "${CYCLE_DIR}/round-${ROUND}.txt")
  log_event "${CYCLE_ID}" "${ROUND}" "verdict:${VERDICT}"

  case "${VERDICT}" in
    approve)
      update_state "${CYCLE_ID}" "converged" "${ROUND}"
      log_event "${CYCLE_ID}" "${ROUND}" "converged"
      exit 0
      ;;
    request_changes|unclear)
      update_state "${CYCLE_ID}" "request_changes" "${ROUND}"
      exit 0
      ;;
  esac
done

# Reached max_rounds without convergence — escalate.
update_state "${CYCLE_ID}" "escalated" "${MAX_ROUNDS}"
log_event "${CYCLE_ID}" "${MAX_ROUNDS}" "escalated"

exit 0
