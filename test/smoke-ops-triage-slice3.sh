#!/usr/bin/env bash
# test/smoke-ops-triage-slice3.sh
#
# v2.2 slice 3 smoke for hooks/ops-risk-triage.sh.
# Tests the ACTIVE GATE: ask-mode default + governed-mode hard-deny on
# destructive + §9 file-based reason fallback (.tdd/ops-triage/pending-
# reason.txt) + fail-closed escalation when the classifier is unavailable.
#
# Stub classifier reused from slice 2 (sentinel-based canned verdicts).
#
# Covers:
#   - ask mode + would_escalate=true → emit JSON ask + write reason file
#   - ask mode + would_escalate=false → silent allow (no JSON, no file)
#   - governed mode + destructive verdict → emit JSON deny + reason file
#   - governed mode + escalate-worthy non-destructive → emit JSON ask
#   - L1b denylist match in ask/governed → emit JSON deny (always, regardless
#     of mode)
#   - L1b denylist match in observe → log only, allow (slice 1 behavior)
#   - Classifier unavailable in ask/governed → fail-closed: emit ask with
#     "classifier down" reason
#   - Classifier unavailable in observe → log + allow (slice 2 behavior)
#   - The reason text inside the JSON matches the text written to the
#     pending-reason.txt file (§9 fallback consistency)
#   - All emitted JSON conforms to the documented PreToolUse decision shape
#   - JSON contains permissionDecisionReason (the §8 concern: it's there
#     even if Claude Code's UI on Bash doesn't render it)

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${PROJECT_ROOT}/hooks/ops-risk-triage.sh"
RUNNER="${PROJECT_ROOT}/runner/ops-triage-classify.sh"
SAFE_EX="${PROJECT_ROOT}/config/ops-safe-allowlist.txt.example"
DENY_EX="${PROJECT_ROOT}/config/ops-catastrophic-denylist.txt.example"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
PASS_COUNT=0

command -v jq >/dev/null 2>&1 || fail "jq required"
[[ -x "${HOOK}" ]] || fail "hook missing"
[[ -x "${RUNNER}" ]] || fail "runner missing"

CLEANUP=()
_cleanup() {
  local p
  for p in "${CLEANUP[@]}"; do
    [[ -n "${p}" ]] && rm -rf "${p}"
  done
}
trap _cleanup EXIT

SANDBOX=$(mktemp -d); CLEANUP+=("${SANDBOX}")
mkdir -p "${SANDBOX}/config" "${SANDBOX}/runner/lib" "${SANDBOX}/runner" \
         "${SANDBOX}/prompts" "${SANDBOX}/schemas"
cp "${SAFE_EX}" "${SANDBOX}/config/ops-safe-allowlist.txt"
cp "${DENY_EX}" "${SANDBOX}/config/ops-catastrophic-denylist.txt"
cp "${PROJECT_ROOT}/runner/lib/config.sh" "${SANDBOX}/runner/lib/config.sh"
cp "${RUNNER}" "${SANDBOX}/runner/ops-triage-classify.sh"
cp "${PROJECT_ROOT}/prompts/ops-risk-classifier.md" "${SANDBOX}/prompts/"
cp "${PROJECT_ROOT}/schemas/ops-triage-verdict.schema.json" "${SANDBOX}/schemas/"
chmod +x "${SANDBOX}/runner/ops-triage-classify.sh"

# Same stub classifier shape as slice 2 (sentinel-driven canned verdicts).
STUB="${SANDBOX}/runner/stub-classifier.sh"
cat > "${STUB}" <<'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
CTX=$(cat 2>/dev/null || true)
CMD=$(jq -r '.command // empty' <<<"${CTX}" 2>/dev/null)
case "${CMD}" in
  *"compose restart"*|*"compose up"*|*"compose down"*)
    jq -nc '{risk:"infra_mutation", confidence:4, escalate_to_codex:true, reason:"stub:infra restart/up"}' ;;
  *"__return_destructive__"*)
    jq -nc '{risk:"destructive", confidence:5, escalate_to_codex:true, reason:"stub:irreversible action"}' ;;
  *"__return_external_read__"*)
    jq -nc '{risk:"external_read", confidence:5, escalate_to_codex:true, reason:"stub:network read"}' ;;
  *"__return_high_conf_safe__"*)
    jq -nc '{risk:"safe_readonly", confidence:5, escalate_to_codex:false, reason:"stub:high-conf safe"}' ;;
  *"__return_low_conf_safe__"*)
    jq -nc '{risk:"safe_readonly", confidence:3, escalate_to_codex:false, reason:"stub:low-conf safe"}' ;;
  *"__return_unknown__"*)
    jq -nc '{risk:"unknown", confidence:1, escalate_to_codex:true, reason:"stub:unknown"}' ;;
  *"__return_nonzero__"*)
    exit 1 ;;
  *"__return_code_mutation__"*)
    jq -nc '{risk:"code_mutation", confidence:5, escalate_to_codex:false, reason:"stub:source edit"}' ;;
  *)
    jq -nc '{risk:"unknown", confidence:1, escalate_to_codex:true, reason:"stub:default-unknown"}' ;;
esac
STUB_EOF
chmod +x "${STUB}"

LOG="${SANDBOX}/.tdd/ops-triage/observe.log"
PENDING="${SANDBOX}/.tdd/ops-triage/pending-reason.txt"
CACHE_DIR="${SANDBOX}/.tdd/ops-triage/cache"

write_toml() {
  local mode="${1:-ask}" enabled="${2:-true}"
  cat > "${SANDBOX}/tdd-pack.toml" <<EOF
[ops_triage]
enabled = ${enabled}
mode = "${mode}"
EOF
}

run_hook() {
  local cmd="$1" mode="${2:-ask}" enabled="${3:-true}"
  rm -f "${LOG}" "${PENDING}"
  rm -rf "${CACHE_DIR}"  # force cache miss every call so verdicts are fresh
  write_toml "${mode}" "${enabled}"
  local payload
  payload=$(jq -nc --arg c "${cmd}" '{tool_name:"Bash", tool_input:{command:$c}}')
  CLAUDE_PROJECT_DIR="${SANDBOX}" \
    CLAUDE_PLUGIN_ROOT="${SANDBOX}" \
    PRILIVE_OPS_TRIAGE_CLASSIFIER_BIN="${STUB}" \
    PRILIVE_REVIEW_DISABLE="${PRILIVE_REVIEW_DISABLE:-}" \
    bash "${HOOK}" <<<"${payload}" 2>/dev/null
}

decision_of() {
  # Pull permissionDecision from the JSON OUT string. Empty if not a decision.
  printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null
}
reason_of() {
  printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null
}

# --- check 1: ask + would_escalate=true → emit ask + reason file ---
info "[1] ask mode + escalate-worthy verdict → emit JSON ask + write pending-reason.txt"
OUT=$(run_hook "docker compose restart app" "ask")
[[ "$(decision_of "${OUT}")" == "ask" ]] \
  || fail "expected permissionDecision=ask; got out='${OUT}'"
R=$(reason_of "${OUT}")
[[ -n "${R}" ]] || fail "expected non-empty permissionDecisionReason in JSON"
grep -q "stub:infra restart/up" <<<"${R}" \
  || fail "expected classifier reason 'stub:infra restart/up' in JSON reason; got: ${R}"
[[ -f "${PENDING}" ]] || fail "expected pending-reason.txt to be written (§9 fallback)"
grep -q "stub:infra restart/up" "${PENDING}" \
  || fail "expected pending-reason.txt to contain classifier reason"
# Consistency: file content === JSON reason
[[ "$(cat "${PENDING}")" == "${R}" ]] \
  || fail "pending-reason.txt content does not match JSON reason (§9 consistency)"
pass "ask emission + reason file + content consistency"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 2: ask + high-conf safe → silent allow (no JSON, no file) ---
info "[2] ask mode + high-conf safe → silent allow (no decision, no pending file)"
OUT=$(run_hook "__return_high_conf_safe__ checking-status" "ask")
[[ -z "${OUT}" ]] || fail "high-conf safe must NOT emit JSON; got '${OUT}'"
[[ ! -f "${PENDING}" ]] \
  || fail "high-conf safe must NOT write pending-reason.txt; file present: $(cat "${PENDING}" 2>/dev/null)"
pass "high-conf safe → silent allow, no file"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 3: ask + low-conf safe → emit ask (unknown is not safe) ---
info "[3] ask mode + low-conf safe → emit ask (unknown-is-not-safe boundary)"
OUT=$(run_hook "__return_low_conf_safe__ checking" "ask")
[[ "$(decision_of "${OUT}")" == "ask" ]] \
  || fail "low-conf safe must emit ask in ask mode; got '${OUT}'"
pass "low-conf safe → ask (boundary enforced in ask mode)"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 4: ask + code_mutation → silent allow (routes to Rail 1) ---
info "[4] ask mode + code_mutation → silent allow (routes to Rail 1)"
OUT=$(run_hook "__return_code_mutation__ src/x.go" "ask")
[[ -z "${OUT}" ]] || fail "code_mutation in ask mode must NOT emit decision; got '${OUT}'"
[[ ! -f "${PENDING}" ]] || fail "code_mutation must NOT write reason file"
pass "code_mutation → silent allow (Rail 1's job)"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 5: ask + destructive → emit ask (with destructive reason) ---
# In ask mode, destructive is still "ask" — operator can approve with eyes
# open. governed mode is the one that hard-denies destructive (check 6).
info "[5] ask mode + destructive → emit ask (not deny — that's governed)"
OUT=$(run_hook "__return_destructive__ wipe" "ask")
[[ "$(decision_of "${OUT}")" == "ask" ]] \
  || fail "destructive in ASK mode must emit ask; governed is the hard-deny mode"
pass "ask + destructive → ask (operator approves with eyes open)"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 6: governed + destructive → emit DENY ---
info "[6] governed mode + destructive → emit deny + reason file"
OUT=$(run_hook "__return_destructive__ wipe" "governed")
[[ "$(decision_of "${OUT}")" == "deny" ]] \
  || fail "destructive in GOVERNED mode must emit deny; got '${OUT}'"
[[ -f "${PENDING}" ]] || fail "deny must also write pending-reason.txt"
grep -qi "irreversible\|destructive\|governed" "${PENDING}" \
  || fail "deny reason should mention irreversibility/destructive/governed; got: $(cat "${PENDING}")"
pass "governed + destructive → deny + reason file"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 7: governed + escalate-worthy non-destructive → emit ask ---
info "[7] governed mode + infra_mutation (not destructive) → emit ask"
OUT=$(run_hook "docker compose restart app" "governed")
[[ "$(decision_of "${OUT}")" == "ask" ]] \
  || fail "governed + non-destructive escalation must emit ask; got '${OUT}'"
pass "governed + non-destructive escalation → ask"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 8: L1b denylist match in ask mode → emit DENY ---
info "[8] L1b denylist match in ask mode → emit deny (mode-independent fail-closed)"
OUT=$(run_hook "rm -rf /" "ask")
[[ "$(decision_of "${OUT}")" == "deny" ]] \
  || fail "L1b match in ask mode must deny (fail-closed); got '${OUT}'"
log_has_pattern() { grep -q "$1" "${LOG}" 2>/dev/null; }
log_has_pattern '"verdict":"denylist_match"' \
  || fail "L1b deny must also log denylist_match"
[[ -f "${PENDING}" ]] || fail "L1b deny must write pending-reason.txt"
pass "L1b denylist in ask → deny + log + file"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 9: L1b denylist match in governed mode → emit DENY ---
info "[9] L1b denylist match in governed mode → emit deny"
OUT=$(run_hook "rm -rf /" "governed")
[[ "$(decision_of "${OUT}")" == "deny" ]] \
  || fail "L1b match in governed must deny; got '${OUT}'"
pass "L1b denylist in governed → deny"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 10: L1b denylist match in OBSERVE mode → log + allow (no JSON) ---
# Slice 1 invariant: observe never interrupts.
info "[10] L1b denylist match in observe mode → log only, allow (slice 1 invariant)"
OUT=$(run_hook "rm -rf /" "observe")
[[ -z "${OUT}" ]] || fail "observe + L1b must NOT emit JSON; got '${OUT}'"
[[ ! -f "${PENDING}" ]] \
  || fail "observe + L1b must NOT write pending-reason.txt"
log_has_pattern '"verdict":"denylist_match"' \
  || fail "observe + L1b must still log denylist_match"
pass "L1b in observe → log only, never interrupts (slice 1 invariant preserved)"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 11: classifier unavailable in ask → FAIL-CLOSED escalate ---
info "[11] classifier unavailable in ask mode → fail-closed: emit ask"
OUT=$(run_hook "__return_nonzero__ mystery" "ask")
[[ "$(decision_of "${OUT}")" == "ask" ]] \
  || fail "classifier-down in ask mode must fail-closed to ask; got '${OUT}'"
grep -qi "classifier" <<<"$(reason_of "${OUT}")" \
  || fail "fail-closed reason should mention classifier; got: $(reason_of "${OUT}")"
[[ -f "${PENDING}" ]] || fail "fail-closed ask must also write pending-reason.txt"
pass "classifier-down in ask → fail-closed escalate"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 12: classifier unavailable in governed → FAIL-CLOSED escalate (ask, not deny) ---
# governed escalates same as ask when classifier is unavailable (an unclassified
# command shouldn't be auto-blocked; operator decides).
info "[12] classifier unavailable in governed mode → fail-closed: emit ask (not deny)"
OUT=$(run_hook "__return_nonzero__ mystery" "governed")
[[ "$(decision_of "${OUT}")" == "ask" ]] \
  || fail "classifier-down in governed mode must fail-closed to ask; got '${OUT}'"
pass "classifier-down in governed → fail-closed ask (operator escalation, not auto-deny)"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 13: classifier unavailable in OBSERVE → log + allow (slice 2 invariant) ---
info "[13] classifier unavailable in observe → log only, allow"
OUT=$(run_hook "__return_nonzero__ mystery" "observe")
[[ -z "${OUT}" ]] || fail "observe + classifier-down must NOT emit JSON"
[[ ! -f "${PENDING}" ]] \
  || fail "observe + classifier-down must NOT write pending-reason.txt"
log_has_pattern '"verdict":"classifier_unavailable"' \
  || fail "observe + classifier-down must still log classifier_unavailable"
pass "classifier-down in observe → log only (slice 2 invariant preserved)"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 14: Layer 1 fast-path in ask mode → silent allow (no decision) ---
info "[14] Layer 1 fast-path in ask mode → silent allow (no JSON, no file, no log)"
OUT=$(run_hook "pwd" "ask")
[[ -z "${OUT}" ]] || fail "Layer 1 fast-path must NOT emit decision even in ask mode"
[[ ! -f "${PENDING}" ]] || fail "Layer 1 fast-path must NOT write reason file"
[[ ! -s "${LOG}" ]] || fail "Layer 1 fast-path must NOT log"
pass "Layer 1 fast-path unaffected by ask mode"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 15: pending-reason.txt is overwritten on each ask/deny (not appended) ---
info "[15] pending-reason.txt is OVERWRITTEN on each ask/deny (most recent only)"
OUT1=$(run_hook "docker compose restart app1" "ask")
R1=$(reason_of "${OUT1}")
OUT2=$(run_hook "__return_destructive__ wipe" "governed")
R2=$(reason_of "${OUT2}")
PENDING_CONTENT=$(cat "${PENDING}")
[[ "${PENDING_CONTENT}" == "${R2}" ]] \
  || fail "pending-reason.txt should contain only the LATEST reason; expected '${R2}', got '${PENDING_CONTENT}'"
[[ "${PENDING_CONTENT}" != "${R1}" ]] \
  || fail "pending-reason.txt should NOT contain stale reason from previous call"
pass "pending-reason.txt holds only the latest decision (overwrite, not append)"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 16: kill switch overrides ask mode (operator emergency) ---
info "[16] PRILIVE_REVIEW_DISABLE=1 overrides ask mode (operator emergency kill)"
OUT=$(PRILIVE_REVIEW_DISABLE=1 run_hook "rm -rf /" "ask")
[[ -z "${OUT}" ]] || fail "kill switch must override ask mode and silent-allow; got '${OUT}'"
[[ ! -f "${PENDING}" ]] || fail "kill switch must NOT write reason file"
pass "kill switch overrides ask mode (operator escape hatch)"
PASS_COUNT=$((PASS_COUNT+1))

echo ""
echo "================================================================"
echo "  OPS-TRIAGE SLICE 3 SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
