#!/usr/bin/env bash
# runner/review-runner.sh <project_dir>
#
# v2.0 MVP — Detached background orchestrator. Round 1 only for MVP.
# (Phase 2 adds rounds 2+, escalation, fingerprint stop.)
#
# Flow:
#   1. Acquire single-flight lock (flock).
#   2. Honor PRILIVE_REVIEW_DISABLE.
#   3. Coalesce — wait for the working tree to be quiet for coalesce_ms.
#   4. Skip if no uncommitted changes.
#   5. Snapshot diff.
#   6. Run codex round 1.
#   7. Update state.json and audit log.

set -uo pipefail

PROJECT_DIR="${1:-${CLAUDE_PROJECT_DIR:-}}"
if [[ -z "${PROJECT_DIR}" ]]; then
  echo "[review-runner] BLOCKED: PROJECT_DIR not set" >&2
  exit 2
fi

TDD_DIR="${PROJECT_DIR}/.tdd"
REVIEWS_DIR="${TDD_DIR}/reviews"
CONFIG="${PROJECT_DIR}/tdd-pack.toml"

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

# --- coalesce window ---
COALESCE_MS=5000
if [[ -f "${CONFIG}" ]]; then
  CFG_COALESCE=$(awk -F' = ' '/^coalesce_ms =/ {print $2; exit}' "${CONFIG}" | tr -d ' ')
  [[ "${CFG_COALESCE}" =~ ^[0-9]+$ ]] && COALESCE_MS="${CFG_COALESCE}"
fi
"${PROJECT_DIR}/runner/coalesce.sh" "${PROJECT_DIR}" "${COALESCE_MS}"

# --- skip if nothing to review ---
if cd "${PROJECT_DIR}" && git diff --quiet HEAD 2>/dev/null; then
  exit 0   # no uncommitted changes
fi

# --- mint cycle id ---
CYCLE_ID="cycle-$(date -u +%Y%m%dT%H%M%SZ)-$$"
CYCLE_DIR="${REVIEWS_DIR}/${CYCLE_ID}"
mkdir -p "${CYCLE_DIR}"

# --- snapshot diff ---
git -C "${PROJECT_DIR}" diff HEAD > "${CYCLE_DIR}/diff.patch" 2>/dev/null

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
    > "${REVIEWS_DIR}/state.json.tmp" 2>/dev/null \
    && mv "${REVIEWS_DIR}/state.json.tmp" "${REVIEWS_DIR}/state.json"
}

log_event() {
  local round="$1" event="$2"
  local ts; ts=$(date -u +%FT%TZ 2>/dev/null || echo unknown)
  jq -nc \
    --arg cycle "${CYCLE_ID}" \
    --arg ts "${ts}" \
    --argjson round "${round}" \
    --arg event "${event}" \
    '{cycle_id:$cycle, ts:$ts, round:$round, event:$event}' \
    >> "${REVIEWS_DIR}/debates.jsonl" 2>/dev/null
}

# --- run round 1 ---
update_state "${CYCLE_ID}" "reviewing" 1
log_event 1 "started"

if ! "${PROJECT_DIR}/runner/codex-round1.sh" "${CYCLE_ID}" "${PROJECT_DIR}"; then
  STATUS_DETAIL=$(cat "${CYCLE_DIR}/.status" 2>/dev/null || echo "failed")
  update_state "${CYCLE_ID}" "failed" 1
  log_event 1 "${STATUS_DETAIL}"
  exit 0
fi

VERDICT=$(jq -r '.verdict' "${CYCLE_DIR}/round-1.json" 2>/dev/null || echo unknown)
log_event 1 "verdict:${VERDICT}"

if [[ "${VERDICT}" == "approve" ]]; then
  update_state "${CYCLE_ID}" "converged" 1
  log_event 1 "converged"
  exit 0
fi

# request_changes after round 1 → leave state.json saying so. The Stop
# hook (stop-fingerprint.sh) will capture Claude's response and fire a
# new runner instance, which will detect the continuation via the
# orchestrate_rounds_2_plus() function below.
update_state "${CYCLE_ID}" "request_changes" 1

# v2.0 Phase 2: if we got here AND there's already a claude-response-2
# file (Stop hook may have captured it before re-firing us), proceed
# into rounds 2+. Otherwise exit; we'll be re-fired by Stop later.
if [[ ! -f "${CYCLE_DIR}/claude-response-2.txt" ]]; then
  exit 0
fi

# ---- Phase 2 orchestration: rounds 2..MAX ----

MAX_ROUNDS=$(awk -F' = ' '/^max_rounds =/ {print $2; exit}' "${CONFIG}" | tr -d ' ')
MAX_ROUNDS="${MAX_ROUNDS:-4}"

for ROUND in $(seq 2 "${MAX_ROUNDS}"); do
  RESPONSE_FILE="${CYCLE_DIR}/claude-response-${ROUND}.txt"
  if [[ ! -f "${RESPONSE_FILE}" ]]; then
    # No response yet for this round — Stop hook hasn't captured it.
    # Leave state in request_changes; we'll be re-fired by Stop on
    # Claude's next turn.
    update_state "${CYCLE_ID}" "request_changes" "$((ROUND - 1))"
    exit 0
  fi

  update_state "${CYCLE_ID}" "reviewing" "${ROUND}"
  log_event "${ROUND}" "started"

  if ! "${PROJECT_DIR}/runner/codex-round-n.sh" "${CYCLE_ID}" "${PROJECT_DIR}" "${ROUND}"; then
    STATUS_DETAIL=$(cat "${CYCLE_DIR}/.status" 2>/dev/null || echo "failed")
    update_state "${CYCLE_ID}" "failed" "${ROUND}"
    log_event "${ROUND}" "${STATUS_DETAIL}"
    exit 0
  fi

  VERDICT=$(${PROJECT_DIR}/runner/extract-verdict.sh "${CYCLE_DIR}/round-${ROUND}.txt")
  log_event "${ROUND}" "verdict:${VERDICT}"

  case "${VERDICT}" in
    approve)
      update_state "${CYCLE_ID}" "converged" "${ROUND}"
      log_event "${ROUND}" "converged"
      exit 0
      ;;
    request_changes|unclear)
      # Stay in request_changes; Stop hook will re-fire after Claude responds.
      update_state "${CYCLE_ID}" "request_changes" "${ROUND}"
      exit 0
      ;;
  esac
done

# Reached max_rounds without convergence — escalate.
update_state "${CYCLE_ID}" "escalated" "${MAX_ROUNDS}"
log_event "${MAX_ROUNDS}" "escalated"

exit 0
