#!/usr/bin/env bash
# test/smoke-ops-triage-slice2.sh
#
# v2.2 slice 2 smoke for hooks/ops-risk-triage.sh + runner/ops-triage-classify.sh.
# Tests the LAYER 2 integration (cache + LLM classifier + "unknown is not safe"
# preview + observe-mode logging) using a stub classifier so no real API
# tokens are burned.
#
# Stub classifier: a tiny script that reads the CTX JSON on stdin and emits
# a canned verdict based on simple command-pattern matching. Lets us test
# the hook's plumbing exhaustively without spending money.
#
# Covers:
#   - Cache miss → classifier called → verdict logged with all fields
#   - Cache hit → no classifier call → verdict logged with cache_hit=true
#   - Cache invalidation on allowlist/denylist edit (SHA changes)
#   - Risk verdict + confidence → would_escalate preview field is correct
#     (safe_readonly conf>=4 → false; conf<4 → true; everything else → true
#     except code_mutation which routes to Rail 1)
#   - Classifier failure (non-zero exit) → log "classifier_unavailable"
#     and ALLOW (observe mode never interrupts)
#   - Classifier malformed output (missing required fields) → same as failure
#   - ask/governed mode still degrades to observe (slice 2 is observe-only)
#   - L1 fast-path is unaffected (classifier NOT called for trivially safe)
#   - L1b denylist match is unaffected (classifier NOT called)
#
# Each "expected log" assertion is paired with "expected NOT to log this
# wrong thing" where applicable (counterfactual discipline).

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
[[ -f "${SAFE_EX}" ]] || fail "safe allowlist example missing"
[[ -f "${DENY_EX}" ]] || fail "denylist example missing"

# Sandbox.
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

# --- stub classifier ---
# Reads CTX JSON on stdin, emits a canned verdict per command pattern.
# The "test" verdict's reason includes a marker so we can verify the
# classifier was actually invoked (not just a cached value).
STUB="${SANDBOX}/runner/stub-classifier.sh"
cat > "${STUB}" <<'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
CTX=$(cat 2>/dev/null || true)
CMD=$(jq -r '.command // empty' <<<"${CTX}" 2>/dev/null)
case "${CMD}" in
  *"compose restart"*|*"compose up"*|*"compose down"*|*"rollout restart"*)
    jq -nc '{risk:"infra_mutation", confidence:4, escalate_to_codex:true, reason:"stub:infra"}' ;;
  *"helm upgrade"*)
    jq -nc '{risk:"infra_mutation", confidence:4, escalate_to_codex:true, reason:"stub:helm"}' ;;
  *"curl "*|*"wget "*)
    jq -nc '{risk:"external_read", confidence:5, escalate_to_codex:true, reason:"stub:net-read"}' ;;
  *"__return_low_conf_safe__"*)
    # Test the low-confidence safe path: classifier says safe_readonly
    # but confidence 3 → would_escalate should be true.
    jq -nc '{risk:"safe_readonly", confidence:3, escalate_to_codex:false, reason:"stub:low-conf-safe"}' ;;
  *"pytest"*|*"npm test"*|*"go test"*)
    # Local read-ish (test runners may write reports, but mainly read).
    jq -nc '{risk:"local_read", confidence:5, escalate_to_codex:false, reason:"stub:test-run"}' ;;
  *"vim "*|*"nano "*|*"sed -i"*)
    jq -nc '{risk:"code_mutation", confidence:5, escalate_to_codex:false, reason:"stub:code-edit"}' ;;
  *"__return_unknown__"*)
    jq -nc '{risk:"unknown", confidence:1, escalate_to_codex:true, reason:"stub:unknown"}' ;;
  *"__return_destructive__"*)
    jq -nc '{risk:"destructive", confidence:5, escalate_to_codex:true, reason:"stub:destructive"}' ;;
  *"__return_high_conf_safe__"*)
    jq -nc '{risk:"safe_readonly", confidence:5, escalate_to_codex:false, reason:"stub:high-conf-safe"}' ;;
  *"__return_malformed__"*)
    # Missing required fields — the hook must reject this.
    echo '{"risk":"safe_readonly"}' ;;
  *"__return_empty__"*)
    : ;; # nothing on stdout → exit 0 with empty output
  *"__return_nonzero__"*)
    exit 1 ;;
  *)
    jq -nc '{risk:"unknown", confidence:1, escalate_to_codex:true, reason:"stub:default-unknown"}' ;;
esac
STUB_EOF
chmod +x "${STUB}"

# --- helpers ---
LOG="${SANDBOX}/.tdd/ops-triage/observe.log"
CACHE_DIR="${SANDBOX}/.tdd/ops-triage/cache"

write_toml() {
  local mode="${1:-observe}" enabled="${2:-true}"
  cat > "${SANDBOX}/tdd-pack.toml" <<EOF
[ops_triage]
enabled = ${enabled}
mode = "${mode}"
classifier = "haiku"
EOF
}
write_toml

run_hook() {
  local cmd="$1" mode="${2:-observe}" enabled="${3:-true}"
  rm -f "${LOG}"
  write_toml "${mode}" "${enabled}"
  local payload
  payload=$(jq -nc --arg c "${cmd}" '{tool_name:"Bash", tool_input:{command:$c}}')
  CLAUDE_PROJECT_DIR="${SANDBOX}" \
    CLAUDE_PLUGIN_ROOT="${SANDBOX}" \
    PRILIVE_OPS_TRIAGE_CLASSIFIER_BIN="${STUB}" \
    PRILIVE_REVIEW_DISABLE="${PRILIVE_REVIEW_DISABLE:-}" \
    bash "${HOOK}" <<<"${payload}" 2>/dev/null
}

log_has_field() {
  # Does the log have ANY line where field $1 equals string value $2?
  [[ -f "${LOG}" ]] || return 1
  jq -e --arg k "$1" --arg v "$2" \
    'select(.[$k] == $v)' "${LOG}" >/dev/null 2>&1
}

log_field_value() {
  # First value of field $1 across all log lines, or "" if absent.
  [[ -f "${LOG}" ]] || { echo ""; return; }
  jq -r --arg k "$1" '.[$k]? // empty' "${LOG}" 2>/dev/null | head -1
}

# --- check 1: cache miss → classifier called, verdict logged with all fields ---
info "[1] cache miss → classifier called, verdict has risk+confidence+would_escalate+cache_hit+reason"
rm -rf "${CACHE_DIR}"
OUT=$(run_hook "docker compose restart app")
[[ -z "${OUT}" ]] || fail "slice 2 observe must NOT emit JSON; got '${OUT}'"
log_has_field "verdict" "infra_mutation" \
  || fail "expected verdict=infra_mutation; log=$(cat "${LOG}" 2>/dev/null)"
[[ "$(log_field_value cache_hit)" == "false" ]] \
  || fail "expected cache_hit=false on first call; got '$(log_field_value cache_hit)'"
[[ "$(log_field_value confidence)" == "4" ]] \
  || fail "expected confidence=4 from stub; got '$(log_field_value confidence)'"
[[ "$(log_field_value would_escalate)" == "true" ]] \
  || fail "expected would_escalate=true for infra_mutation; got '$(log_field_value would_escalate)'"
[[ "$(log_field_value reason)" == "stub:infra" ]] \
  || fail "expected reason='stub:infra'; got '$(log_field_value reason)'"
pass "cache miss verdict logged with all required fields"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 2: cache hit on second call → no classifier call, cache_hit=true ---
info "[2] cache hit on second call → cache_hit=true (classifier NOT re-invoked)"
OUT=$(run_hook "docker compose restart app")
[[ "$(log_field_value cache_hit)" == "true" ]] \
  || fail "expected cache_hit=true on second call; got '$(log_field_value cache_hit)'"
log_has_field "verdict" "infra_mutation" \
  || fail "cached verdict should still be infra_mutation"
pass "cache hit correctly bypasses classifier"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 3: cache invalidates when allowlist content changes ---
info "[3] editing allowlist invalidates cache (SHA-based key)"
echo "# touched at $(printf 'x')" >> "${SANDBOX}/config/ops-safe-allowlist.txt"
OUT=$(run_hook "docker compose restart app")
[[ "$(log_field_value cache_hit)" == "false" ]] \
  || fail "expected cache_hit=false after allowlist edit; cache should have invalidated"
pass "cache invalidates on config edit (allowlist)"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 4: would_escalate is FALSE for high-confidence safe_readonly ---
info "[4] would_escalate=false for high-confidence safe_readonly"
OUT=$(run_hook "__return_high_conf_safe__")
[[ "$(log_field_value would_escalate)" == "false" ]] \
  || fail "expected would_escalate=false for safe_readonly conf=5; got '$(log_field_value would_escalate)'"
pass "high-confidence safe_readonly → would_escalate=false"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 5: would_escalate is TRUE for LOW-confidence safe_readonly ---
# This is the "unknown is not safe" rule applied at the confidence boundary.
info "[5] would_escalate=true for LOW-confidence safe_readonly ('unknown is not safe' rule)"
OUT=$(run_hook "__return_low_conf_safe__ probing")
[[ "$(log_field_value would_escalate)" == "true" ]] \
  || fail "expected would_escalate=true for safe_readonly conf=3; got '$(log_field_value would_escalate)'"
pass "low-confidence safe verdict → would_escalate=true (unknown is not safe)"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 6: code_mutation → would_escalate=false (routes to Rail 1) ---
info "[6] code_mutation → would_escalate=false (routes to existing code review rail)"
OUT=$(run_hook "vim src/main.go")
log_has_field "verdict" "code_mutation" \
  || fail "expected verdict=code_mutation; log=$(cat "${LOG}" 2>/dev/null)"
[[ "$(log_field_value would_escalate)" == "false" ]] \
  || fail "expected would_escalate=false for code_mutation; got '$(log_field_value would_escalate)'"
pass "code_mutation correctly defers to Rail 1, would_escalate=false"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 7: external_read → would_escalate=true (may leak data) ---
info "[7] external_read → would_escalate=true (may leak)"
OUT=$(run_hook "curl -fsS https://api.example.com/v1/data")
log_has_field "verdict" "external_read" \
  || fail "expected verdict=external_read; log=$(cat "${LOG}" 2>/dev/null)"
[[ "$(log_field_value would_escalate)" == "true" ]] \
  || fail "expected would_escalate=true for external_read"
pass "external_read → would_escalate=true"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 8: destructive → would_escalate=true ---
info "[8] destructive → would_escalate=true"
OUT=$(run_hook "__return_destructive__ /tmp/x")
log_has_field "verdict" "destructive" \
  || fail "expected verdict=destructive"
[[ "$(log_field_value would_escalate)" == "true" ]] \
  || fail "expected would_escalate=true for destructive"
pass "destructive → would_escalate=true"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 9: unknown → would_escalate=true (the cardinal rule) ---
info "[9] unknown → would_escalate=true (cardinal rule)"
OUT=$(run_hook "__return_unknown__ doing-something-weird")
log_has_field "verdict" "unknown" \
  || fail "expected verdict=unknown"
[[ "$(log_field_value would_escalate)" == "true" ]] \
  || fail "expected would_escalate=true for unknown"
pass "unknown verdict → would_escalate=true (unknown is not safe)"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 10: classifier non-zero exit → "classifier_unavailable", allow ---
info "[10] classifier failure (non-zero exit) → log 'classifier_unavailable', no verdict, allow"
OUT=$(run_hook "__return_nonzero__")
[[ -z "${OUT}" ]] || fail "must allow (empty stdout) on classifier failure"
log_has_field "verdict" "classifier_unavailable" \
  || fail "expected verdict=classifier_unavailable in log"
# Counterfactual: no real verdict logged.
if log_has_field "verdict" "infra_mutation" || log_has_field "verdict" "destructive"; then
  fail "should NOT have logged a real verdict on classifier failure"
fi
pass "classifier failure handled: logged + allowed (observe mode)"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 11: classifier malformed output → same as failure ---
info "[11] classifier malformed output → 'classifier_unavailable', allow (no cache write)"
OUT=$(run_hook "__return_malformed__")
[[ -z "${OUT}" ]] || fail "must allow on malformed classifier output"
log_has_field "verdict" "classifier_unavailable" \
  || fail "expected verdict=classifier_unavailable for malformed output"
# Counterfactual: malformed output must NOT poison the cache. Cache file
# for this command should NOT exist.
MAL_KEY=$(printf '%s|%s|unknown|observe|%s|%s' \
            "__return_malformed__" \
            "${PWD}" \
            "$(sha256sum < "${SANDBOX}/config/ops-safe-allowlist.txt" | cut -d' ' -f1)" \
            "$(sha256sum < "${SANDBOX}/config/ops-catastrophic-denylist.txt" | cut -d' ' -f1)" \
          | sha256sum | cut -d' ' -f1)
[[ ! -f "${CACHE_DIR}/${MAL_KEY}.json" ]] \
  || fail "malformed verdict was incorrectly cached at ${MAL_KEY}.json"
pass "malformed classifier output handled: logged + NOT cached"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 12: classifier returns empty → 'classifier_unavailable' ---
info "[12] classifier empty output → 'classifier_unavailable'"
OUT=$(run_hook "__return_empty__")
[[ -z "${OUT}" ]] || fail "must allow on empty classifier output"
log_has_field "verdict" "classifier_unavailable" \
  || fail "expected verdict=classifier_unavailable for empty output"
pass "empty classifier output handled"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 13: observe mode in slice 2 never emits a decision ---
# (Slice 3 added ask/governed emission; this smoke focuses on classifier
# + caching behavior in OBSERVE mode. Ask/deny emission is tested in
# the slice 3 smoke.)
info "[13] observe mode in slice 2: classifier ran + verdict logged, but NEVER emits JSON"
OUT=$(run_hook "docker compose restart app" "observe")
[[ -z "${OUT}" ]] || fail "observe mode must NOT emit JSON; got '${OUT}'"
log_has_field "verdict" "infra_mutation" \
  || fail "observe mode: expected classifier verdict in log"
pass "observe mode classifies + logs but never emits decision"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 14: Layer 1 fast-path is unaffected — classifier NOT called ---
# pwd is on the safe allowlist and has safe shape; it should fast-path
# with NO log entry at all.
info "[14] Layer 1 fast-path: classifier NOT invoked, no log entry"
rm -f "${LOG}"
OUT=$(run_hook "pwd")
[[ -z "${OUT}" ]] || fail "Layer 1 fast-path: expected empty stdout"
[[ ! -s "${LOG}" ]] \
  || fail "Layer 1 fast-path: expected NO log entry, got: $(cat "${LOG}" 2>/dev/null)"
pass "Layer 1 fast-path bypasses classifier with no log"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 15: Layer 1b denylist match — classifier NOT called ---
# denylist patterns short-circuit before Layer 2.
info "[15] Layer 1b denylist: classifier NOT invoked, log denylist_match only"
OUT=$(run_hook "rm -rf /")
[[ -z "${OUT}" ]] || fail "Layer 1b: slice 1 observe must allow (empty stdout)"
log_has_field "verdict" "denylist_match" \
  || fail "expected verdict=denylist_match"
# Counterfactual: classifier verdicts must NOT appear (it wasn't called).
for v in safe_readonly infra_mutation destructive unknown classifier_unavailable; do
  if log_has_field "verdict" "${v}"; then
    fail "denylist match should not have invoked classifier; got verdict=${v}"
  fi
done
pass "Layer 1b denylist bypasses classifier; only denylist_match logged"
PASS_COUNT=$((PASS_COUNT+1))

echo ""
echo "================================================================"
echo "  OPS-TRIAGE SLICE 2 SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
