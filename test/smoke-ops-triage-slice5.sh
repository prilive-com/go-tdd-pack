#!/usr/bin/env bash
# test/smoke-ops-triage-slice5.sh
#
# v2.2 slice 5 smoke. Covers:
#   - Governed-mode destructive override via preflight artifact:
#       no artifact      → deny (slice 3 behavior preserved)
#       artifact=approve → allow + log "governed_override_via_artifact"
#       artifact=approve_with_checks → allow
#       artifact=block   → deny (with different reason than no-artifact)
#       artifact=request_changes → deny
#       malformed artifact (no .verdict.verdict field) → deny
#   - PostToolUse ops-debt-track:
#       observe.log has L2 verdict infra_mutation → debt entry created
#       observe.log has L2 verdict local_mutation → debt entry created
#       observe.log has L2 verdict destructive → debt entry created
#       observe.log has L2 verdict safe_readonly → NO debt
#       preflight artifact present → debt entry CLEARED (counterfactual)
#       mode=observe → no debt tracked (observe never blocks)
#       mode=off / disabled → no debt tracked
#   - Stop hook ops-debt-stop:
#       no .tdd/ops-debt/*.json → exit 0 (allow stop)
#       open .tdd/ops-debt/*.json → emit {"decision":"block","reason":...}
#         with the command list in the reason text
#       stop_hook_active=true → exit 0 immediately (LOOP GUARD; mandatory)
#       PRILIVE_REVIEW_DISABLE=1 → exit 0 (kill switch)

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_TRIAGE="${PROJECT_ROOT}/hooks/ops-risk-triage.sh"
HOOK_TRACK="${PROJECT_ROOT}/hooks/ops-debt-track.sh"
HOOK_STOP="${PROJECT_ROOT}/hooks/ops-debt-stop.sh"
SAFE_EX="${PROJECT_ROOT}/config/ops-safe-allowlist.txt.example"
DENY_EX="${PROJECT_ROOT}/config/ops-catastrophic-denylist.txt.example"
RUNNER="${PROJECT_ROOT}/runner/ops-triage-classify.sh"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
PASS_COUNT=0

command -v jq >/dev/null 2>&1 || fail "jq required"
for h in "${HOOK_TRIAGE}" "${HOOK_TRACK}" "${HOOK_STOP}"; do
  [[ -x "${h}" ]] || fail "hook missing or not executable: ${h}"
done

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
cp "${SAFE_EX}"  "${SANDBOX}/config/ops-safe-allowlist.txt"
cp "${DENY_EX}"  "${SANDBOX}/config/ops-catastrophic-denylist.txt"
cp "${PROJECT_ROOT}/runner/lib/config.sh" "${SANDBOX}/runner/lib/config.sh"
cp "${RUNNER}"   "${SANDBOX}/runner/ops-triage-classify.sh"
cp "${PROJECT_ROOT}/prompts/ops-risk-classifier.md" "${SANDBOX}/prompts/"
cp "${PROJECT_ROOT}/schemas/ops-triage-verdict.schema.json" "${SANDBOX}/schemas/"
chmod +x "${SANDBOX}/runner/ops-triage-classify.sh"

STUB="${SANDBOX}/stub.sh"
cat > "${STUB}" <<'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
CTX=$(cat 2>/dev/null || true)
CMD=$(jq -r '.command // empty' <<<"${CTX}" 2>/dev/null)
case "${CMD}" in
  *DESTRUCTIVE_CMD*)
    jq -nc '{risk:"destructive", confidence:5, escalate_to_codex:true, reason:"stub:destroys things"}' ;;
  *INFRA_CMD*)
    jq -nc '{risk:"infra_mutation", confidence:4, escalate_to_codex:true, reason:"stub:infra change"}' ;;
  *LOCAL_MUT_CMD*)
    jq -nc '{risk:"local_mutation", confidence:4, escalate_to_codex:false, reason:"stub:local mutation"}' ;;
  *SAFE_CMD*)
    jq -nc '{risk:"safe_readonly", confidence:5, escalate_to_codex:false, reason:"stub:safe"}' ;;
  *)
    jq -nc '{risk:"unknown", confidence:1, escalate_to_codex:true, reason:"stub:unknown"}' ;;
esac
STUB_EOF
chmod +x "${STUB}"

LOG="${SANDBOX}/.tdd/ops-triage/observe.log"
PENDING="${SANDBOX}/.tdd/ops-triage/pending-reason.txt"
DEBT_DIR="${SANDBOX}/.tdd/ops-debt"
PREFLIGHT_DIR="${SANDBOX}/.tdd/ops-preflight"
CACHE_DIR="${SANDBOX}/.tdd/ops-triage/cache"

write_toml() {
  local mode="${1:-governed}" enabled="${2:-true}"
  cat > "${SANDBOX}/tdd-pack.toml" <<EOF
[ops_triage]
enabled = ${enabled}
mode = "${mode}"
EOF
}

run_triage() {
  local cmd="$1" mode="${2:-governed}" enabled="${3:-true}"
  rm -f "${LOG}" "${PENDING}"
  rm -rf "${CACHE_DIR}"
  write_toml "${mode}" "${enabled}"
  local payload
  payload=$(jq -nc --arg c "${cmd}" '{tool_name:"Bash", tool_input:{command:$c}}')
  CLAUDE_PROJECT_DIR="${SANDBOX}" \
    CLAUDE_PLUGIN_ROOT="${SANDBOX}" \
    PRILIVE_OPS_TRIAGE_CLASSIFIER_BIN="${STUB}" \
    PRILIVE_REVIEW_DISABLE="${PRILIVE_REVIEW_DISABLE:-}" \
    bash "${HOOK_TRIAGE}" <<<"${payload}" 2>/dev/null
}

run_tracker() {
  local cmd="$1" mode="${2:-governed}" enabled="${3:-true}"
  write_toml "${mode}" "${enabled}"
  local payload
  payload=$(jq -nc --arg c "${cmd}" '{tool_name:"Bash", tool_input:{command:$c}}')
  CLAUDE_PROJECT_DIR="${SANDBOX}" \
    CLAUDE_PLUGIN_ROOT="${SANDBOX}" \
    PRILIVE_REVIEW_DISABLE="${PRILIVE_REVIEW_DISABLE:-}" \
    bash "${HOOK_TRACK}" <<<"${payload}" 2>/dev/null
}

run_stop() {
  local active="${1:-false}" enabled="${2:-true}"
  write_toml "ask" "${enabled}"
  local payload
  payload=$(jq -nc --argjson a "${active}" '{stop_hook_active:$a}')
  CLAUDE_PROJECT_DIR="${SANDBOX}" \
    CLAUDE_PLUGIN_ROOT="${SANDBOX}" \
    PRILIVE_REVIEW_DISABLE="${PRILIVE_REVIEW_DISABLE:-}" \
    bash "${HOOK_STOP}" <<<"${payload}" 2>/dev/null
}

decision_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }
reason_of()   { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }
stop_decision_of() { printf '%s' "$1" | jq -r '.decision // empty' 2>/dev/null; }
stop_reason_of()   { printf '%s' "$1" | jq -r '.reason // empty' 2>/dev/null; }

art_path_for() {
  local cmd="$1"
  local h; h=$(printf '%s' "${cmd}" | sha256sum | cut -d' ' -f1)
  echo "${PREFLIGHT_DIR}/${h}.json"
}
debt_path_for() {
  local cmd="$1"
  local h; h=$(printf '%s' "${cmd}" | sha256sum | cut -d' ' -f1)
  echo "${DEBT_DIR}/${h}.json"
}
write_artifact() {
  local cmd="$1" verdict="$2"
  local p; p=$(art_path_for "${cmd}")
  mkdir -p "${PREFLIGHT_DIR}"
  jq -nc --arg c "${cmd}" --arg v "${verdict}" \
    '{command:$c, command_hash:"x", decided_at:"now",
      verdict:{verdict:$v, risk:"destructive", findings:[], required_prechecks:[],
               required_postchecks:[], rollback:[], human_summary:"stub"}}' \
    > "${p}"
}

# --- governed-mode artifact override ----------------------------------

info "[1] governed + destructive WITHOUT artifact → deny (slice 3 baseline preserved)"
rm -rf "${PREFLIGHT_DIR}"
OUT=$(run_triage "DESTRUCTIVE_CMD wipe" "governed")
[[ "$(decision_of "${OUT}")" == "deny" ]] \
  || fail "expected deny (no artifact); got '$(decision_of "${OUT}")'"
grep -qi "Run /ops-preflight first" <<<"$(reason_of "${OUT}")" \
  || fail "deny reason should mention /ops-preflight"
pass "governed + destructive + no artifact → deny"
PASS_COUNT=$((PASS_COUNT+1))

info "[2] governed + destructive WITH artifact verdict=approve → ALLOW + log override"
write_artifact "DESTRUCTIVE_CMD wipe" "approve"
OUT=$(run_triage "DESTRUCTIVE_CMD wipe" "governed")
[[ -z "${OUT}" ]] || fail "expected no JSON emission (allow); got '${OUT}'"
grep -q '"verdict":"governed_override_via_artifact"' "${LOG}" \
  || fail "expected log entry governed_override_via_artifact; log=$(cat "${LOG}" 2>/dev/null)"
grep -q '"art_verdict":"approve"' "${LOG}" \
  || fail "expected art_verdict=approve in log"
pass "governed override via approve artifact → allow + log"
PASS_COUNT=$((PASS_COUNT+1))

info "[3] governed + destructive WITH artifact verdict=approve_with_checks → ALLOW"
write_artifact "DESTRUCTIVE_CMD wipe" "approve_with_checks"
OUT=$(run_triage "DESTRUCTIVE_CMD wipe" "governed")
[[ -z "${OUT}" ]] || fail "expected allow on approve_with_checks; got '${OUT}'"
grep -q '"art_verdict":"approve_with_checks"' "${LOG}" \
  || fail "expected art_verdict=approve_with_checks in log"
pass "governed override via approve_with_checks artifact → allow"
PASS_COUNT=$((PASS_COUNT+1))

info "[4] governed + destructive WITH artifact verdict=block → deny (with Codex-specific reason)"
write_artifact "DESTRUCTIVE_CMD wipe" "block"
OUT=$(run_triage "DESTRUCTIVE_CMD wipe" "governed")
[[ "$(decision_of "${OUT}")" == "deny" ]] || fail "expected deny on block verdict"
grep -qi "Codex preflight returned 'block'" <<<"$(reason_of "${OUT}")" \
  || fail "deny reason should mention Codex returned block; got: $(reason_of "${OUT}")"
pass "governed + artifact verdict=block → deny with Codex-specific reason"
PASS_COUNT=$((PASS_COUNT+1))

info "[5] governed + destructive WITH artifact verdict=request_changes → deny"
write_artifact "DESTRUCTIVE_CMD wipe" "request_changes"
OUT=$(run_triage "DESTRUCTIVE_CMD wipe" "governed")
[[ "$(decision_of "${OUT}")" == "deny" ]] || fail "expected deny on request_changes"
pass "governed + artifact verdict=request_changes → deny"
PASS_COUNT=$((PASS_COUNT+1))

info "[6] governed + destructive WITH malformed artifact (no verdict.verdict) → deny"
mkdir -p "${PREFLIGHT_DIR}"
echo '{"command":"DESTRUCTIVE_CMD wipe","verdict":{"no":"shape"}}' \
  > "$(art_path_for "DESTRUCTIVE_CMD wipe")"
OUT=$(run_triage "DESTRUCTIVE_CMD wipe" "governed")
[[ "$(decision_of "${OUT}")" == "deny" ]] || fail "malformed artifact must deny"
pass "governed + malformed artifact → deny"
PASS_COUNT=$((PASS_COUNT+1))

info "[7] ask mode + destructive WITH approve artifact → still emits ask (artifact override is governed-only)"
rm -rf "${PREFLIGHT_DIR}"
write_artifact "DESTRUCTIVE_CMD wipe" "approve"
OUT=$(run_triage "DESTRUCTIVE_CMD wipe" "ask")
[[ "$(decision_of "${OUT}")" == "ask" ]] \
  || fail "ask mode must still emit ask for destructive even with artifact present"
pass "ask mode + destructive ignores artifact (governed-only feature)"
PASS_COUNT=$((PASS_COUNT+1))

# --- PostToolUse ops-debt tracker --------------------------------------

triage_then_track() {
  local cmd="$1" mode="${2:-ask}"
  rm -rf "${DEBT_DIR}" "${PREFLIGHT_DIR}"
  run_triage "${cmd}" "${mode}" >/dev/null
  run_tracker "${cmd}" "${mode}" >/dev/null
}

info "[8] tracker records debt for infra_mutation verdict"
triage_then_track "INFRA_CMD restart" "ask"
[[ -f "$(debt_path_for "INFRA_CMD restart")" ]] \
  || fail "expected debt file for infra_mutation"
DEBT_RISK=$(jq -r '.risk' "$(debt_path_for "INFRA_CMD restart")")
[[ "${DEBT_RISK}" == "infra_mutation" ]] || fail "debt.risk should be infra_mutation"
pass "infra_mutation → debt recorded"
PASS_COUNT=$((PASS_COUNT+1))

info "[9] tracker records debt for local_mutation verdict"
triage_then_track "LOCAL_MUT_CMD touch" "ask"
[[ -f "$(debt_path_for "LOCAL_MUT_CMD touch")" ]] \
  || fail "expected debt file for local_mutation"
pass "local_mutation → debt recorded"
PASS_COUNT=$((PASS_COUNT+1))

info "[10] tracker records debt for destructive verdict"
triage_then_track "DESTRUCTIVE_CMD wipe" "ask"
[[ -f "$(debt_path_for "DESTRUCTIVE_CMD wipe")" ]] \
  || fail "expected debt file for destructive"
pass "destructive → debt recorded"
PASS_COUNT=$((PASS_COUNT+1))

info "[11] tracker does NOT record debt for safe_readonly verdict"
triage_then_track "SAFE_CMD checking" "ask"
[[ ! -f "$(debt_path_for "SAFE_CMD checking")" ]] \
  || fail "safe_readonly must NOT create debt"
pass "safe_readonly → no debt (counterfactual)"
PASS_COUNT=$((PASS_COUNT+1))

info "[12] preflight artifact present → tracker CLEARS existing debt"
triage_then_track "INFRA_CMD restart" "ask"
[[ -f "$(debt_path_for "INFRA_CMD restart")" ]] || fail "setup failed: expected debt"
write_artifact "INFRA_CMD restart" "approve"
run_tracker "INFRA_CMD restart" "ask" >/dev/null
[[ ! -f "$(debt_path_for "INFRA_CMD restart")" ]] \
  || fail "tracker should have cleared debt when artifact present"
pass "preflight artifact → debt cleared (obligation satisfied)"
PASS_COUNT=$((PASS_COUNT+1))

info "[13] mode=observe → tracker creates NO debt (observe never blocks)"
rm -rf "${DEBT_DIR}" "${PREFLIGHT_DIR}"
run_triage "INFRA_CMD restart" "observe" >/dev/null
run_tracker "INFRA_CMD restart" "observe" >/dev/null
[[ ! -f "$(debt_path_for "INFRA_CMD restart")" ]] \
  || fail "observe mode must NOT create debt"
pass "observe mode → no debt tracking"
PASS_COUNT=$((PASS_COUNT+1))

info "[14] disabled (enabled=false) → tracker creates NO debt"
rm -rf "${DEBT_DIR}"
run_tracker "INFRA_CMD restart" "ask" "false" >/dev/null
[[ ! -f "$(debt_path_for "INFRA_CMD restart")" ]] \
  || fail "disabled mode must NOT create debt"
pass "disabled → no debt tracking"
PASS_COUNT=$((PASS_COUNT+1))

# --- Stop hook ops-debt block ------------------------------------------

info "[15] Stop hook + no debt files → exit 0, no JSON (allow stop)"
rm -rf "${DEBT_DIR}"
OUT=$(run_stop "false")
[[ -z "${OUT}" ]] || fail "Stop hook must NOT block when no debt exists; got '${OUT}'"
pass "no debt → Stop allows turn-end"
PASS_COUNT=$((PASS_COUNT+1))

info "[16] Stop hook + open debt → emit {decision:block, reason:...}"
mkdir -p "${DEBT_DIR}"
jq -nc --arg c "INFRA_CMD restart app" \
  '{command:$c, risk:"infra_mutation", command_hash:"abc", created_at:"now", note:"x"}' \
  > "${DEBT_DIR}/abc.json"
OUT=$(run_stop "false")
[[ "$(stop_decision_of "${OUT}")" == "block" ]] \
  || fail "Stop hook must block on open debt; got '${OUT}'"
grep -q "INFRA_CMD restart app" <<<"$(stop_reason_of "${OUT}")" \
  || fail "Stop reason should include the open debt command"
grep -qi "ops-preflight\|ops-debt" <<<"$(stop_reason_of "${OUT}")" \
  || fail "Stop reason should mention how to resolve"
pass "open debt → Stop blocks with command list in reason"
PASS_COUNT=$((PASS_COUNT+1))

info "[17] Stop hook + stop_hook_active=true → exit 0 immediately (MANDATORY loop guard)"
OUT=$(run_stop "true")
[[ -z "${OUT}" ]] \
  || fail "stop_hook_active=true must suppress block (infinite-loop guard); got '${OUT}'"
pass "loop guard honored (stop_hook_active=true → no block)"
PASS_COUNT=$((PASS_COUNT+1))

info "[18] Stop hook + PRILIVE_REVIEW_DISABLE=1 → exit 0 (kill switch)"
OUT=$(PRILIVE_REVIEW_DISABLE=1 run_stop "false")
[[ -z "${OUT}" ]] || fail "kill switch must suppress Stop block; got '${OUT}'"
pass "PRILIVE_REVIEW_DISABLE=1 → Stop hook silent"
PASS_COUNT=$((PASS_COUNT+1))

info "[19] Stop hook + multiple open debts → all listed in reason"
rm -rf "${DEBT_DIR}"
mkdir -p "${DEBT_DIR}"
for cmd in "INFRA_CMD foo" "DESTRUCTIVE_CMD bar" "LOCAL_MUT_CMD baz"; do
  h=$(printf '%s' "${cmd}" | sha256sum | cut -d' ' -f1)
  jq -nc --arg c "${cmd}" --arg h "${h}" \
    '{command:$c, risk:"infra_mutation", command_hash:$h, created_at:"now", note:"x"}' \
    > "${DEBT_DIR}/${h}.json"
done
OUT=$(run_stop "false")
[[ "$(stop_decision_of "${OUT}")" == "block" ]] || fail "expected block"
REASON=$(stop_reason_of "${OUT}")
for snippet in "INFRA_CMD foo" "DESTRUCTIVE_CMD bar" "LOCAL_MUT_CMD baz"; do
  grep -qF "${snippet}" <<<"${REASON}" \
    || fail "Stop reason missing command '${snippet}'"
done
pass "multiple open debts → all listed in Stop reason"
PASS_COUNT=$((PASS_COUNT+1))

echo ""
echo "================================================================"
echo "  OPS-TRIAGE SLICE 5 SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
