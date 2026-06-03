#!/usr/bin/env bash
# test/smoke-escalate-origin-aware.sh
#
# v2.1 PR 6 — runner/escalate.sh emits different escalation messages
# based on origin detection (spec §11):
#   - interactive → A/B/V menu
#   - unattended  → fail-closed message (no menu, instructions to re-run)

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ESCALATE="${PROJECT_ROOT}/runner/escalate.sh"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
PASS_COUNT=0

CLEANUP_PATHS=()
cleanup_all() {
  local p
  for p in "${CLEANUP_PATHS[@]}"; do
    [[ -n "$p" ]] && rm -rf "$p"
  done
}
trap cleanup_all EXIT

# Build a sandbox project with a minimal escalated cycle so escalate.sh
# has the fixtures it needs (state.json, round-1.json, etc.).
make_sandbox() {
  local d cycle_id=cycle-test
  d=$(mktemp -d)
  mkdir -p "$d/.tdd/reviews/$cycle_id"
  cat > "$d/tdd-pack.toml" <<'TOML'
[review]
max_rounds = 4
TOML
  cat > "$d/.tdd/reviews/$cycle_id/round-1.json" <<'JSON'
{"verdict":"request_changes","summary_one_sentence":"test disagreement headline","summary_one_paragraph":"x","findings":[],"files_read":[],"questions_for_human":[]}
JSON
  echo "round 4 text" > "$d/.tdd/reviews/$cycle_id/round-4.txt"
  echo "claude final response" > "$d/.tdd/reviews/$cycle_id/claude-response-4.txt"
  echo "$d"
}

# Run escalate.sh under a given env and return the additionalContext text.
run_escalate() {
  local sandbox="$1" env_assignments="$2"
  # Use env -i to strip the parent's environment so CI from this shell
  # doesn't leak into the test. Re-add PATH so jq is found.
  env -i PATH="${PATH}" bash -c "$env_assignments \"${ESCALATE}\" cycle-test \"${sandbox}\"" \
    | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
}

# ============================================================

info "[1] default (no CI env) → interactive A/B/V menu"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_escalate "$SANDBOX" '')
[[ "$OUT" == *"REVIEW ESCALATION"* ]]                  || fail "case 1: header missing"
[[ "$OUT" != *"unattended environment"* ]]             || fail "case 1: should NOT flag unattended"
[[ "$OUT" == *"[A] /accept-claude"* ]]                 || fail "case 1: A/B/V menu missing"
[[ "$OUT" == *"[V] /show-review"* ]]                   || fail "case 1: /show-review missing"
pass "default: interactive A/B/V menu rendered"
PASS_COUNT=$((PASS_COUNT+1))

info "[2] CI=true → unattended message (no A/B/V menu)"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_escalate "$SANDBOX" 'CI=true')
[[ "$OUT" == *"REVIEW ESCALATION"* ]]                  || fail "case 2: header missing"
[[ "$OUT" == *"UNATTENDED ENVIRONMENT DETECTED"* ]]    || fail "case 2: should flag unattended"
[[ "$OUT" != *"[A] /accept-claude"* ]]                 || fail "case 2: should NOT have A/B/V menu"
[[ "$OUT" == *"Failing closed"* || "$OUT" == *"fail-closed"* ]] || fail "case 2: should mention fail-closed"
pass "CI=true: unattended message, no A/B/V menu, fail-closed framing"
PASS_COUNT=$((PASS_COUNT+1))

info "[3] GITHUB_ACTIONS=true → unattended"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_escalate "$SANDBOX" 'GITHUB_ACTIONS=true')
[[ "$OUT" == *"UNATTENDED ENVIRONMENT DETECTED"* ]] || fail "case 3: GITHUB_ACTIONS should trigger unattended"
pass "GITHUB_ACTIONS: unattended"
PASS_COUNT=$((PASS_COUNT+1))

info "[4] GITLAB_CI=true → unattended"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_escalate "$SANDBOX" 'GITLAB_CI=true')
[[ "$OUT" == *"UNATTENDED ENVIRONMENT DETECTED"* ]] || fail "case 4: GITLAB_CI should trigger unattended"
pass "GITLAB_CI: unattended"
PASS_COUNT=$((PASS_COUNT+1))

info "[5] TDD_REVIEW_ORIGIN=interactive OVERRIDES CI=true"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_escalate "$SANDBOX" 'CI=true TDD_REVIEW_ORIGIN=interactive')
[[ "$OUT" == *"[A] /accept-claude"* ]]                 || fail "case 5: override to interactive should restore menu"
[[ "$OUT" != *"UNATTENDED ENVIRONMENT DETECTED"* ]]    || fail "case 5: should NOT be unattended"
pass "TDD_REVIEW_ORIGIN=interactive overrides CI env (explicit > implicit)"
PASS_COUNT=$((PASS_COUNT+1))

info "[6] TDD_REVIEW_ORIGIN=ci forces unattended even without CI env"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_escalate "$SANDBOX" 'TDD_REVIEW_ORIGIN=ci')
[[ "$OUT" == *"UNATTENDED ENVIRONMENT DETECTED"* ]] || fail "case 6: explicit ci should force unattended"
pass "TDD_REVIEW_ORIGIN=ci forces unattended"
PASS_COUNT=$((PASS_COUNT+1))

info "[7] TDD_REVIEW_ORIGIN=unattended same as ci"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_escalate "$SANDBOX" 'TDD_REVIEW_ORIGIN=unattended')
[[ "$OUT" == *"UNATTENDED ENVIRONMENT DETECTED"* ]] || fail "case 7: explicit unattended should force unattended"
pass "TDD_REVIEW_ORIGIN=unattended → unattended message"
PASS_COUNT=$((PASS_COUNT+1))

# ---- summary ----

echo ""
echo "================================================================"
echo "  ESCALATE ORIGIN-AWARE SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
exit 0
