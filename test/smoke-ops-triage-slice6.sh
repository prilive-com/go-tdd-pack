#!/usr/bin/env bash
# test/smoke-ops-triage-slice6.sh
#
# v2.2 slice 6 smoke. The specific fix for the original outage pattern
# (chown -R then docker compose --build = 12-hour outage).
#
# Two pieces under test:
#
#   A) hooks/ops-tag-session.sh — PostToolUse Bash hook that detects
#      auth / container_uid / config commands and appends matching tags
#      to .tdd/ops-triage/session-tags.txt.
#
#   B) hooks/ops-risk-triage.sh — engine-side R2→R3 escalation: when
#      classifier returns `infra_mutation` AND session has auth or
#      container_uid tags, hook overrides risk to `destructive` and
#      logs `engine_escalated_from`.
#
# Counterfactual discipline: every "match" assertion paired with a
# "near-miss does NOT match" assertion. Same v2.1.1 lesson pattern.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_TRIAGE="${PROJECT_ROOT}/hooks/ops-risk-triage.sh"
HOOK_TAG="${PROJECT_ROOT}/hooks/ops-tag-session.sh"
SAFE_EX="${PROJECT_ROOT}/config/ops-safe-allowlist.txt.example"
DENY_EX="${PROJECT_ROOT}/config/ops-catastrophic-denylist.txt.example"
TAGS_EX="${PROJECT_ROOT}/config/ops-session-tags.txt.example"
RUNNER="${PROJECT_ROOT}/runner/ops-triage-classify.sh"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
PASS_COUNT=0

command -v jq >/dev/null 2>&1 || fail "jq required"
[[ -x "${HOOK_TRIAGE}" ]] || fail "triage hook missing"
[[ -x "${HOOK_TAG}" ]] || fail "tag-session hook missing"
[[ -f "${TAGS_EX}" ]] || fail "tags example config missing"

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
cp "${TAGS_EX}"  "${SANDBOX}/config/ops-session-tags.txt"
cp "${PROJECT_ROOT}/runner/lib/config.sh" "${SANDBOX}/runner/lib/config.sh"
cp "${RUNNER}"   "${SANDBOX}/runner/ops-triage-classify.sh"
cp "${PROJECT_ROOT}/prompts/ops-risk-classifier.md" "${SANDBOX}/prompts/"
cp "${PROJECT_ROOT}/schemas/ops-triage-verdict.schema.json" "${SANDBOX}/schemas/"
chmod +x "${SANDBOX}/runner/ops-triage-classify.sh"

# Stub classifier — same shape as slice 5.
STUB="${SANDBOX}/stub.sh"
cat > "${STUB}" <<'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
CTX=$(cat 2>/dev/null || true)
CMD=$(jq -r '.command // empty' <<<"${CTX}" 2>/dev/null)
case "${CMD}" in
  *INFRA_CMD*)
    jq -nc '{risk:"infra_mutation", confidence:4, escalate_to_codex:true, reason:"stub:infra change"}' ;;
  *SAFE_CMD*)
    jq -nc '{risk:"safe_readonly", confidence:5, escalate_to_codex:false, reason:"stub:safe"}' ;;
  *LOCAL_MUT_CMD*)
    jq -nc '{risk:"local_mutation", confidence:4, escalate_to_codex:false, reason:"stub:local mut"}' ;;
  *DESTRUCTIVE_CMD*)
    jq -nc '{risk:"destructive", confidence:5, escalate_to_codex:true, reason:"stub:destructive"}' ;;
  *)
    jq -nc '{risk:"unknown", confidence:1, escalate_to_codex:true, reason:"stub:unknown"}' ;;
esac
STUB_EOF
chmod +x "${STUB}"

LOG="${SANDBOX}/.tdd/ops-triage/observe.log"
TAGS_FILE="${SANDBOX}/.tdd/ops-triage/session-tags.txt"
CACHE_DIR="${SANDBOX}/.tdd/ops-triage/cache"

write_toml() {
  local mode="${1:-ask}" enabled="${2:-true}"
  cat > "${SANDBOX}/tdd-pack.toml" <<EOF
[ops_triage]
enabled = ${enabled}
mode = "${mode}"
EOF
}

run_tag() {
  local cmd="$1" mode="${2:-ask}" enabled="${3:-true}"
  write_toml "${mode}" "${enabled}"
  local payload
  payload=$(jq -nc --arg c "${cmd}" '{tool_name:"Bash", tool_input:{command:$c}}')
  CLAUDE_PROJECT_DIR="${SANDBOX}" \
    CLAUDE_PLUGIN_ROOT="${SANDBOX}" \
    PRILIVE_REVIEW_DISABLE="${PRILIVE_REVIEW_DISABLE:-}" \
    bash "${HOOK_TAG}" <<<"${payload}" 2>/dev/null
}

run_triage() {
  local cmd="$1" mode="${2:-ask}" enabled="${3:-true}"
  rm -f "${LOG}"
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

decision_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }
log_has_field() {
  [[ -f "${LOG}" ]] || return 1
  jq -e --arg k "$1" --arg v "$2" 'select(.[$k] == $v)' "${LOG}" >/dev/null 2>&1
}
tags_contain() {
  [[ -f "${TAGS_FILE}" ]] || return 1
  grep -q "^$1$" "${TAGS_FILE}"
}

clear_tags() { rm -f "${TAGS_FILE}" 2>/dev/null; }

# =====================================================================
# Tag-session hook (Part A)
# =====================================================================

info "[1] chown -R writes 'container_uid' tag"
clear_tags
run_tag "chown -R 1000:1000 /srv/app/data" "ask"
tags_contain "container_uid" || fail "expected 'container_uid' tag; got: $(cat "${TAGS_FILE}" 2>/dev/null)"
pass "chown -R → container_uid tag"
PASS_COUNT=$((PASS_COUNT+1))

info "[2] chmod -R writes 'container_uid' tag"
clear_tags
run_tag "chmod -R 755 /var/lib/app" "ask"
tags_contain "container_uid" || fail "expected 'container_uid' tag from chmod -R"
pass "chmod -R → container_uid tag"
PASS_COUNT=$((PASS_COUNT+1))

info "[3] useradd writes 'auth' tag"
clear_tags
run_tag "useradd -m newuser" "ask"
tags_contain "auth" || fail "expected 'auth' tag from useradd"
pass "useradd → auth tag"
PASS_COUNT=$((PASS_COUNT+1))

info "[4] kubectl create secret writes 'auth' tag"
clear_tags
run_tag "kubectl create secret generic api-token --from-literal=token=abc" "ask"
tags_contain "auth" || fail "expected 'auth' tag from kubectl create secret"
pass "kubectl create secret → auth tag"
PASS_COUNT=$((PASS_COUNT+1))

info "[5] .env edit writes 'config' tag"
clear_tags
run_tag "cp /tmp/new.env .env" "ask"
tags_contain "config" || fail "expected 'config' tag from .env edit"
pass ".env cp → config tag"
PASS_COUNT=$((PASS_COUNT+1))

info "[6] non-matching command (pwd) writes NO tags (counterfactual)"
clear_tags
run_tag "pwd" "ask"
[[ ! -f "${TAGS_FILE}" ]] || [[ ! -s "${TAGS_FILE}" ]] \
  || fail "innocent command should write no tags; got: $(cat "${TAGS_FILE}")"
pass "innocent command → no tags (counterfactual)"
PASS_COUNT=$((PASS_COUNT+1))

info "[7] near-miss: chown WITHOUT -R does NOT trigger container_uid"
clear_tags
run_tag "chown nobody /tmp/scratch" "ask"
if [[ -f "${TAGS_FILE}" ]] && tags_contain "container_uid"; then
  fail "non-recursive chown should NOT trigger container_uid tag"
fi
pass "chown without -R → no container_uid (counterfactual)"
PASS_COUNT=$((PASS_COUNT+1))

info "[8] near-miss: docker exec WITHOUT chown/chmod does NOT trigger container_uid"
clear_tags
run_tag "docker exec myapp ls /app" "ask"
if [[ -f "${TAGS_FILE}" ]] && tags_contain "container_uid"; then
  fail "docker exec ls should NOT trigger container_uid tag"
fi
pass "docker exec ls → no container_uid (counterfactual)"
PASS_COUNT=$((PASS_COUNT+1))

info "[9] tags are append-only: multiple chown -R writes multiple lines"
clear_tags
run_tag "chown -R 1000:1000 /srv/a" "ask"
run_tag "chown -R 1001:1001 /srv/b" "ask"
LINES=$(wc -l < "${TAGS_FILE}")
[[ "${LINES}" -ge "2" ]] || fail "expected >=2 tag lines; got ${LINES}"
pass "tags append (file grows; classifier deduplicates downstream)"
PASS_COUNT=$((PASS_COUNT+1))

info "[10] disabled (enabled=false) → tagger writes NO tags"
clear_tags
run_tag "chown -R 1000:1000 /srv/x" "ask" "false"
[[ ! -f "${TAGS_FILE}" ]] || [[ ! -s "${TAGS_FILE}" ]] \
  || fail "disabled mode must NOT write tags"
pass "disabled → no tagging"
PASS_COUNT=$((PASS_COUNT+1))

info "[11] kill switch (PRILIVE_REVIEW_DISABLE=1) → tagger writes NO tags"
clear_tags
PRILIVE_REVIEW_DISABLE=1 run_tag "chown -R 1000:1000 /srv/y" "ask"
[[ ! -f "${TAGS_FILE}" ]] || [[ ! -s "${TAGS_FILE}" ]] \
  || fail "kill switch must suppress tagging"
pass "kill switch → no tagging"
PASS_COUNT=$((PASS_COUNT+1))

# =====================================================================
# Engine-side R2→R3 escalation (Part B)
# =====================================================================

info "[12] NO tags + infra_mutation → stays infra_mutation (baseline)"
clear_tags
run_triage "INFRA_CMD restart app" "ask"
log_has_field "verdict" "infra_mutation" \
  || fail "expected verdict=infra_mutation; log=$(cat "${LOG}" 2>/dev/null)"
# Counterfactual: must NOT escalate
if log_has_field "verdict" "destructive"; then
  fail "no tags → must NOT escalate to destructive"
fi
pass "no session tags → infra_mutation stays (no escalation)"
PASS_COUNT=$((PASS_COUNT+1))

info "[13] container_uid tag + infra_mutation → ESCALATED to destructive"
clear_tags
echo "container_uid" > "${TAGS_FILE}"
run_triage "INFRA_CMD restart app" "ask"
log_has_field "verdict" "destructive" \
  || fail "expected ESCALATED verdict=destructive; log=$(cat "${LOG}")"
log_has_field "engine_escalated_from" "infra_mutation" \
  || fail "expected engine_escalated_from=infra_mutation log field"
pass "container_uid tag + infra_mutation → destructive + engine_escalated_from"
PASS_COUNT=$((PASS_COUNT+1))

info "[14] auth tag + infra_mutation → ESCALATED to destructive"
clear_tags
echo "auth" > "${TAGS_FILE}"
run_triage "INFRA_CMD restart app" "ask"
log_has_field "verdict" "destructive" \
  || fail "expected destructive escalation on auth tag"
log_has_field "engine_escalated_from" "infra_mutation" \
  || fail "expected engine_escalated_from log field"
pass "auth tag + infra_mutation → destructive (engine escalated)"
PASS_COUNT=$((PASS_COUNT+1))

info "[15] config tag alone does NOT trigger escalation (only auth/container_uid do)"
clear_tags
echo "config" > "${TAGS_FILE}"
run_triage "INFRA_CMD restart app" "ask"
log_has_field "verdict" "infra_mutation" \
  || fail "config tag alone should NOT escalate; expected infra_mutation"
if log_has_field "engine_escalated_from" "infra_mutation"; then
  fail "config tag alone must NOT trigger engine escalation (counterfactual)"
fi
pass "config tag alone → no escalation (counterfactual)"
PASS_COUNT=$((PASS_COUNT+1))

info "[16] auth tag + safe_readonly → NO escalation (safe stays safe)"
clear_tags
echo "auth" > "${TAGS_FILE}"
run_triage "SAFE_CMD checking" "ask"
log_has_field "verdict" "safe_readonly" \
  || fail "expected safe_readonly to remain; got: $(cat "${LOG}")"
if log_has_field "engine_escalated_from" "safe_readonly"; then
  fail "safe_readonly must NOT be escalated by session tags (counterfactual)"
fi
pass "tags do NOT escalate safe_readonly (only infra_mutation gets escalated)"
PASS_COUNT=$((PASS_COUNT+1))

info "[17] container_uid tag + local_mutation → NO escalation"
clear_tags
echo "container_uid" > "${TAGS_FILE}"
run_triage "LOCAL_MUT_CMD touch" "ask"
log_has_field "verdict" "local_mutation" \
  || fail "expected local_mutation to remain"
if log_has_field "verdict" "destructive"; then
  fail "tags must only escalate infra_mutation, not local_mutation (counterfactual)"
fi
pass "tags do NOT escalate local_mutation (scope limited to infra_mutation)"
PASS_COUNT=$((PASS_COUNT+1))

info "[18] container_uid tag + destructive → stays destructive (no double-escalation)"
clear_tags
echo "container_uid" > "${TAGS_FILE}"
run_triage "DESTRUCTIVE_CMD wipe" "ask"
log_has_field "verdict" "destructive" || fail "expected destructive"
# Counterfactual: no engine_escalated_from since the original verdict was already destructive
if log_has_field "engine_escalated_from" "destructive"; then
  fail "destructive should NOT have engine_escalated_from set (no escalation needed)"
fi
pass "destructive + tag → destructive (no false escalation log)"
PASS_COUNT=$((PASS_COUNT+1))

info "[19] FULL INCIDENT REPLAY: chown -R writes container_uid tag, then INFRA_CMD rebuild → escalated to destructive"
# This is THE original outage pattern. The test replays it end-to-end:
# the chown -R (Bash) triggers the PostToolUse tag hook, then the
# subsequent rebuild (Bash) triggers PreToolUse triage which sees the
# tag and escalates. Without slice 6, the rebuild would have been
# classified infra_mutation and asked the operator with mild reason;
# with slice 6, it's destructive — which in governed mode is a hard
# deny until /ops-preflight runs.
clear_tags
run_tag "chown -R 1000:1000 /srv/ainews/data" "ask"
tags_contain "container_uid" || fail "tag hook didn't tag chown -R"
run_triage "INFRA_CMD docker compose up -d --build ainews-processor" "ask"
log_has_field "verdict" "destructive" \
  || fail "rebuild after chown -R should have been escalated to destructive; log: $(cat "${LOG}")"
log_has_field "engine_escalated_from" "infra_mutation" \
  || fail "expected engine_escalated_from=infra_mutation log field"
pass "FULL INCIDENT REPLAY: chown -R → rebuild correctly escalated to destructive"
PASS_COUNT=$((PASS_COUNT+1))

info "[20] governed mode + replay → ask mode emits 'ask', governed mode would deny"
# In ask mode + destructive escalation, the hook emits ask (operator
# can approve with eyes open). The reason text mentions the engine
# escalation so the operator knows what happened.
clear_tags
echo "container_uid" > "${TAGS_FILE}"
OUT=$(run_triage "INFRA_CMD docker compose up -d --build app" "ask")
[[ "$(decision_of "${OUT}")" == "ask" ]] \
  || fail "ask mode + escalated destructive should emit ask; got '${OUT}'"
REASON=$(printf '%s' "${OUT}" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')
grep -qi "engine-escalated to destructive" <<<"${REASON}" \
  || fail "reason should mention engine-escalated-to-destructive; got: ${REASON}"
pass "ask mode + escalated destructive → ask with escalation cited in reason"
PASS_COUNT=$((PASS_COUNT+1))

echo ""
echo "================================================================"
echo "  OPS-TRIAGE SLICE 6 SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
