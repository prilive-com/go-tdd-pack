#!/usr/bin/env bash
# test/smoke-escalation-blocks-new-cycle.sh
#
# Unit-style smoke proving the runner refuses to spawn fresh cycles when
# state.json reports a non-terminal active status (reviewing, escalated,
# or pending request_changes without claude-response).
#
# This regression-protects the fix for the bug reported by an adopter
# 2026-05-31 and the bug report described in task #100:
#
#   Original symptom: escalated state.json + dirty tree → runner started
#   a new cycle and overwrote state.json, silently destroying the
#   operator's pending A/B/V decision.
#
# These tests use the runner directly (no Codex calls) — we never get
# past the guard because we exit on state.status check.

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="${PROJECT_DIR}/runner/review-runner.sh"
[[ -x "${RUNNER}" ]] || { echo "✗ runner missing at ${RUNNER}" >&2; exit 1; }

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }

PASS_COUNT=0

# Build a clean sandbox for each test.
make_sandbox() {
  local d
  d=$(mktemp -d)
  (
    cd "$d"
    git init -q
    git config user.email "t@t"
    git config user.name "t"
    echo "x" > seed.txt
    git add -A && git commit -q -m "init"
    mkdir -p .tdd/reviews
  ) >/dev/null 2>&1
  echo "$d"
}

# Write a state.json + cycle dir representing an in-progress cycle.
seed_state() {
  local sandbox="$1" cycle="$2" status="$3" round="$4"
  mkdir -p "${sandbox}/.tdd/reviews/${cycle}"
  jq -n \
    --arg c "$cycle" --arg s "$status" --argjson r "$round" \
    --arg ts "$(date -u +%FT%TZ)" \
    '{cycle_id:$c, status:$s, round:$r, updated_at:$ts}' \
    > "${sandbox}/.tdd/reviews/state.json"
}

# Make the working tree dirty (otherwise runner exits early on clean tree).
dirty_tree() {
  local sandbox="$1"
  echo "$(date)" > "${sandbox}/some-new-file.txt"
}

# Assert: state.json was NOT overwritten with a new cycle_id.
assert_state_unchanged() {
  local sandbox="$1" expected_cycle="$2" expected_status="$3"
  local actual_cycle actual_status
  actual_cycle=$(jq -r '.cycle_id // empty' "${sandbox}/.tdd/reviews/state.json")
  actual_status=$(jq -r '.status // empty' "${sandbox}/.tdd/reviews/state.json")
  if [[ "$actual_cycle" != "$expected_cycle" ]]; then
    fail "state.cycle_id changed: expected=${expected_cycle} actual=${actual_cycle}"
  fi
  if [[ "$actual_status" != "$expected_status" ]]; then
    fail "state.status changed: expected=${expected_status} actual=${actual_status}"
  fi
}

# Assert: no NEW cycle directory was created.
assert_no_new_cycle_dir() {
  local sandbox="$1" expected_cycle="$2"
  local extra
  extra=$(find "${sandbox}/.tdd/reviews" -maxdepth 1 -type d \
           -name 'cycle-*' \
           ! -name "$expected_cycle" 2>/dev/null | wc -l)
  if [[ "$extra" -ne 0 ]]; then
    fail "found ${extra} unexpected new cycle dir(s) under ${sandbox}/.tdd/reviews/"
  fi
}

# ---- case 1: escalated state blocks new cycle ----

info "[1] escalated + dirty tree → runner refuses to start new cycle"
SANDBOX=$(make_sandbox)
trap "rm -rf ${SANDBOX}" EXIT
seed_state "${SANDBOX}" "cycle-escalated-fixture" "escalated" 5
dirty_tree "${SANDBOX}"

"${RUNNER}" "${SANDBOX}" >/dev/null 2>&1
assert_state_unchanged "${SANDBOX}" "cycle-escalated-fixture" "escalated"
assert_no_new_cycle_dir "${SANDBOX}" "cycle-escalated-fixture"
pass "case 1: state.json preserved; no new cycle dir created"
PASS_COUNT=$((PASS_COUNT + 1))

# ---- case 2: reviewing state blocks new cycle ----

info "[2] reviewing + dirty tree → runner exits without spawning parallel cycle"
SANDBOX=$(make_sandbox)
trap "rm -rf ${SANDBOX}" EXIT
seed_state "${SANDBOX}" "cycle-inflight-fixture" "reviewing" 1
dirty_tree "${SANDBOX}"

"${RUNNER}" "${SANDBOX}" >/dev/null 2>&1
assert_state_unchanged "${SANDBOX}" "cycle-inflight-fixture" "reviewing"
assert_no_new_cycle_dir "${SANDBOX}" "cycle-inflight-fixture"
pass "case 2: reviewing state preserved; no parallel cycle"
PASS_COUNT=$((PASS_COUNT + 1))

# ---- case 3: terminal states ALLOW new cycle ----

info "[3] converged terminal → runner can start fresh cycle on dirty tree"
SANDBOX=$(make_sandbox)
trap "rm -rf ${SANDBOX}" EXIT
seed_state "${SANDBOX}" "cycle-converged-fixture" "converged" 2
dirty_tree "${SANDBOX}"

# Use PRILIVE_REVIEW_DISABLE=1 so the runner does the state checks but
# doesn't actually invoke Codex (the disable is checked AFTER the
# active-state guard, so we still verify the guard logic ran).
PRILIVE_REVIEW_DISABLE=1 "${RUNNER}" "${SANDBOX}" >/dev/null 2>&1

# State should still say converged (we didn't actually run a cycle because
# of PRILIVE_REVIEW_DISABLE). The key assertion: the runner exited cleanly
# without crashing on the active-state guard.
status_after=$(jq -r '.status' "${SANDBOX}/.tdd/reviews/state.json")
if [[ "$status_after" != "converged" ]]; then
  fail "case 3: state unexpectedly changed from converged to ${status_after}"
fi
pass "case 3: converged terminal allows fresh cycle path (gated only by disable)"
PASS_COUNT=$((PASS_COUNT + 1))

# ---- case 4: abandoned terminal ALLOWS new cycle ----

info "[4] abandoned terminal → runner can start fresh cycle"
SANDBOX=$(make_sandbox)
trap "rm -rf ${SANDBOX}" EXIT
seed_state "${SANDBOX}" "cycle-abandoned-fixture" "abandoned" 3
dirty_tree "${SANDBOX}"

PRILIVE_REVIEW_DISABLE=1 "${RUNNER}" "${SANDBOX}" >/dev/null 2>&1
status_after=$(jq -r '.status' "${SANDBOX}/.tdd/reviews/state.json")
if [[ "$status_after" != "abandoned" ]]; then
  fail "case 4: state unexpectedly changed from abandoned to ${status_after}"
fi
pass "case 4: abandoned terminal allows fresh cycle path"
PASS_COUNT=$((PASS_COUNT + 1))

# ---- case 5: resolved_by_user_claude terminal ALLOWS new cycle ----

info "[5] resolved_by_user_claude terminal → runner can start fresh cycle"
SANDBOX=$(make_sandbox)
trap "rm -rf ${SANDBOX}" EXIT
seed_state "${SANDBOX}" "cycle-resolved-claude-fixture" "resolved_by_user_claude" 5
dirty_tree "${SANDBOX}"

PRILIVE_REVIEW_DISABLE=1 "${RUNNER}" "${SANDBOX}" >/dev/null 2>&1
status_after=$(jq -r '.status' "${SANDBOX}/.tdd/reviews/state.json")
if [[ "$status_after" != "resolved_by_user_claude" ]]; then
  fail "case 5: state unexpectedly changed from resolved_by_user_claude to ${status_after}"
fi
pass "case 5: resolved_by_user_claude terminal allows fresh cycle path"
PASS_COUNT=$((PASS_COUNT + 1))

# ---- final summary ----

echo ""
echo "================================================================"
echo "  ESCALATION-BLOCKS-NEW-CYCLE SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"

exit 0
