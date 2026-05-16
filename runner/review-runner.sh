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

# request_changes — MVP STOPS HERE (Phase 2 adds rounds 2+).
# For MVP, the findings are injected into Claude's next turn via
# inject-findings.sh. The cycle stays in `request_changes` state until
# an operator manually finalizes via /abandon or the Phase 2 runner
# orchestrates rounds 2+.
update_state "${CYCLE_ID}" "request_changes" 1

exit 0
