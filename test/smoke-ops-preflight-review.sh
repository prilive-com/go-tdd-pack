#!/usr/bin/env bash
# test/smoke-ops-preflight-review.sh
#
# v2.2 slice 4 smoke for runner/ops-preflight-review.sh.
#
# Tests the Layer 3 Codex deep-review runner using a stub Codex so no
# real API tokens are burned. Covers:
#   - happy path: valid context → stub returns valid verdict → artifact
#     written under .tdd/ops-preflight/<hash>.json with command +
#     command_hash + decided_at + verdict embedded
#   - artifact filename matches sha256(command)
#   - verdict shape returned on stdout matches what stub produced
#   - missing command in context → fail with clear error, no artifact
#   - missing required fields in verdict → reject; no artifact written
#   - non-array required_prechecks/postchecks/rollback rejected
#   - code-fence-wrapped JSON from the stub is correctly stripped
#   - empty stdin → fail, no artifact
#   - stub returns valid block verdict (with empty findings allowed only
#     when approve; block must have non-empty findings — schema does
#     NOT enforce this, but our prompt does, so test it surfaces)

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="${PROJECT_ROOT}/runner/ops-preflight-review.sh"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
PASS_COUNT=0

command -v jq >/dev/null 2>&1 || fail "jq required"
[[ -x "${RUNNER}" ]] || fail "runner missing: ${RUNNER}"

CLEANUP=()
_cleanup() {
  local p
  for p in "${CLEANUP[@]}"; do
    [[ -n "${p}" ]] && rm -rf "${p}"
  done
}
trap _cleanup EXIT

SANDBOX=$(mktemp -d); CLEANUP+=("${SANDBOX}")
mkdir -p "${SANDBOX}/prompts" "${SANDBOX}/schemas" "${SANDBOX}/runner"
cp "${PROJECT_ROOT}/prompts/codex-ops-preflight.md" "${SANDBOX}/prompts/"
cp "${PROJECT_ROOT}/schemas/ops-preflight-verdict.schema.json" "${SANDBOX}/schemas/"
cp "${RUNNER}" "${SANDBOX}/runner/ops-preflight-review.sh"
chmod +x "${SANDBOX}/runner/ops-preflight-review.sh"

# --- stub Codex review ---
# Reads the rendered prompt on stdin, emits a canned verdict based on
# a sentinel string in the prompt body. Lets us test happy path +
# malformed paths without spending Codex tokens.
STUB="${SANDBOX}/stub-codex.sh"
cat > "${STUB}" <<'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
PROMPT=$(cat 2>/dev/null || true)
case "${PROMPT}" in
  *"__return_approve__"*)
    jq -nc '{verdict:"approve", risk:"safe_readonly", findings:[],
             required_prechecks:[], required_postchecks:[], rollback:[],
             human_summary:"safe to run as-is"}' ;;
  *"__return_approve_with_checks__"*)
    jq -nc '{verdict:"approve_with_checks", risk:"infra_mutation",
             findings:["may restart service briefly"],
             required_prechecks:["docker ps"],
             required_postchecks:["curl -fsS localhost:8080/health","docker logs --tail=50"],
             rollback:["docker compose up -d --no-build app"],
             human_summary:"infra restart with health-check after"}' ;;
  *"__return_block__"*)
    jq -nc '{verdict:"block", risk:"destructive",
             findings:["irreversible chown on shared volume"],
             required_prechecks:[],
             required_postchecks:[],
             rollback:["restore from backup"],
             human_summary:"unrecoverable risk; do not run"}' ;;
  *"__return_request_changes__"*)
    jq -nc '{verdict:"request_changes", risk:"infra_mutation",
             findings:["UID drift risk"],
             required_prechecks:["verify container UID before rebuild"],
             required_postchecks:["docker logs"],
             rollback:["docker compose up -d --no-build app"],
             human_summary:"verify UID first; then re-run with --no-cache=false"}' ;;
  *"__return_fenced__"*)
    # Code-fence wrapper — the runner must strip it.
    printf '```json\n%s\n```\n' "$(jq -nc '{verdict:"approve", risk:"safe_readonly",
             findings:[], required_prechecks:[], required_postchecks:[],
             rollback:[], human_summary:"fenced output test"}')" ;;
  *"__return_missing_summary__"*)
    jq -nc '{verdict:"approve", risk:"safe_readonly", findings:[],
             required_prechecks:[], required_postchecks:[], rollback:[]}' ;;
  *"__return_non_array_prechecks__"*)
    jq -nc '{verdict:"approve", risk:"safe_readonly", findings:[],
             required_prechecks:"docker ps",
             required_postchecks:[], rollback:[],
             human_summary:"bad prechecks type"}' ;;
  *"__return_missing_risk__"*)
    jq -nc '{verdict:"approve", findings:[], required_prechecks:[],
             required_postchecks:[], rollback:[], human_summary:"no risk field"}' ;;
  *"__return_empty__"*)
    : ;;  # empty stdout
  *"__return_nonzero__"*)
    exit 1 ;;
  *)
    jq -nc '{verdict:"approve", risk:"safe_readonly", findings:[],
             required_prechecks:[], required_postchecks:[], rollback:[],
             human_summary:"default stub verdict"}' ;;
esac
STUB_EOF
chmod +x "${STUB}"

# Helper: run the runner with a given context, return stdout.
run_runner() {
  local cmd="$1"
  rm -rf "${SANDBOX}/.tdd/ops-preflight"
  printf '%s' "$(jq -nc --arg c "${cmd}" \
        '{command:$c, service:"app", environment:"prod-like",
          files:["docker-compose.yml"], tags:["auth"],
          status:"running, healthy", logs:"none",
          uid_notes:"container expects UID 1001",
          rollback:"docker compose up -d --no-build app"}')" \
    | CLAUDE_PROJECT_DIR="${SANDBOX}" \
      CLAUDE_PLUGIN_ROOT="${SANDBOX}" \
      PRILIVE_OPS_PREFLIGHT_BIN="${STUB}" \
      bash "${SANDBOX}/runner/ops-preflight-review.sh" 2>/dev/null
}

run_runner_with_ctx() {
  local ctx="$1"
  rm -rf "${SANDBOX}/.tdd/ops-preflight"
  printf '%s' "${ctx}" \
    | CLAUDE_PROJECT_DIR="${SANDBOX}" \
      CLAUDE_PLUGIN_ROOT="${SANDBOX}" \
      PRILIVE_OPS_PREFLIGHT_BIN="${STUB}" \
      bash "${SANDBOX}/runner/ops-preflight-review.sh" 2>/dev/null
}

# Helper: artifact path for a given command
artifact_for() {
  local cmd="$1"
  local hash; hash=$(printf '%s' "${cmd}" | sha256sum | cut -d' ' -f1)
  echo "${SANDBOX}/.tdd/ops-preflight/${hash}.json"
}

# --- check 1: happy path — approve_with_checks → valid verdict + artifact ---
info "[1] approve_with_checks verdict → stdout JSON + artifact at sha256(command).json"
OUT=$(run_runner "__return_approve_with_checks__ docker compose up -d --build app")
[[ -n "${OUT}" ]] || fail "expected stdout JSON; got empty"
VERDICT=$(jq -r '.verdict' <<<"${OUT}")
[[ "${VERDICT}" == "approve_with_checks" ]] || fail "expected verdict=approve_with_checks; got '${VERDICT}'"
ART=$(artifact_for "__return_approve_with_checks__ docker compose up -d --build app")
[[ -f "${ART}" ]] || fail "expected artifact at ${ART}"
jq -e '.command and .command_hash and .decided_at and .verdict' "${ART}" >/dev/null \
  || fail "artifact missing required fields"
# Artifact's embedded verdict must match what we got on stdout.
EMBEDDED=$(jq -c '.verdict' "${ART}")
STDOUT_VERDICT=$(jq -c '.' <<<"${OUT}")
[[ "${EMBEDDED}" == "${STDOUT_VERDICT}" ]] \
  || fail "artifact.verdict does not match stdout verdict"
pass "approve_with_checks → stdout + artifact + content-consistent"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 2: approve verdict (simplest happy path) ---
info "[2] approve verdict → stdout + artifact with empty findings/prechecks/etc"
OUT=$(run_runner "__return_approve__ ls")
[[ "$(jq -r '.verdict' <<<"${OUT}")" == "approve" ]] || fail "expected verdict=approve"
[[ "$(jq -r '.findings | length' <<<"${OUT}")" == "0" ]] \
  || fail "expected empty findings on approve"
pass "approve verdict shaped correctly (empty arrays allowed)"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 3: block verdict (irreversible) ---
info "[3] block verdict → stdout + artifact + non-empty findings"
OUT=$(run_runner "__return_block__ rm -rf /critical/data")
[[ "$(jq -r '.verdict' <<<"${OUT}")" == "block" ]] || fail "expected verdict=block"
[[ "$(jq -r '.findings | length' <<<"${OUT}")" -ge "1" ]] \
  || fail "block verdict must have non-empty findings"
ART=$(artifact_for "__return_block__ rm -rf /critical/data")
[[ -f "${ART}" ]] || fail "block verdict must still write artifact (for audit)"
pass "block verdict written + audit artifact present"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 4: request_changes verdict ---
info "[4] request_changes verdict shaped correctly"
OUT=$(run_runner "__return_request_changes__ docker compose up -d --build")
[[ "$(jq -r '.verdict' <<<"${OUT}")" == "request_changes" ]] \
  || fail "expected verdict=request_changes"
pass "request_changes verdict OK"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 5: code-fence-wrapped JSON is stripped ---
info '[5] stub wrapping output in code-fence (```json … ```) → runner strips fences'
OUT=$(run_runner "__return_fenced__ /tmp/x")
[[ "$(jq -r '.verdict' <<<"${OUT}")" == "approve" ]] \
  || fail "fenced output not stripped correctly; got '${OUT}'"
pass "code-fence wrapper stripped"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 6: artifact filename matches sha256(command) ---
info "[6] artifact filename is sha256(command).json"
CMD="__return_approve__ specific-command-for-hash-test"
HASH=$(printf '%s' "${CMD}" | sha256sum | cut -d' ' -f1)
run_runner "${CMD}" >/dev/null
[[ -f "${SANDBOX}/.tdd/ops-preflight/${HASH}.json" ]] \
  || fail "expected artifact at ${HASH}.json"
pass "artifact filename = sha256(command).json"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 7: missing .command in context → fail + clear error + no artifact ---
info "[7] missing .command in stdin → exit 1, no artifact, error message"
rm -rf "${SANDBOX}/.tdd/ops-preflight"
ERR=$(printf '%s' '{"service":"app"}' \
       | CLAUDE_PROJECT_DIR="${SANDBOX}" \
         CLAUDE_PLUGIN_ROOT="${SANDBOX}" \
         PRILIVE_OPS_PREFLIGHT_BIN="${STUB}" \
         bash "${SANDBOX}/runner/ops-preflight-review.sh" 2>&1 >/dev/null)
echo "${ERR}" | grep -qi "command is required" \
  || fail "expected error mentioning '.command is required'; got: ${ERR}"
[[ ! -d "${SANDBOX}/.tdd/ops-preflight" ]] || \
  [[ -z "$(ls -A "${SANDBOX}/.tdd/ops-preflight" 2>/dev/null)" ]] \
  || fail "expected no artifact written on missing .command"
pass "missing .command → fail + clear error + no artifact"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 8: malformed verdict (missing human_summary) → fail + NO artifact ---
info "[8] malformed verdict (missing human_summary) → fail, NO artifact written"
rm -rf "${SANDBOX}/.tdd/ops-preflight"
ERR=$(printf '%s' "$(jq -nc --arg c '__return_missing_summary__ x' '{command:$c}')" \
       | CLAUDE_PROJECT_DIR="${SANDBOX}" \
         CLAUDE_PLUGIN_ROOT="${SANDBOX}" \
         PRILIVE_OPS_PREFLIGHT_BIN="${STUB}" \
         bash "${SANDBOX}/runner/ops-preflight-review.sh" 2>&1 >/dev/null)
echo "${ERR}" | grep -qi "human_summary" \
  || fail "expected error mentioning human_summary; got: ${ERR}"
[[ ! -f "$(artifact_for "__return_missing_summary__ x")" ]] \
  || fail "malformed verdict was incorrectly cached as artifact"
pass "malformed verdict (no human_summary) rejected; no artifact"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 9: malformed verdict (missing risk) → fail + NO artifact ---
info "[9] malformed verdict (missing .risk) → fail, NO artifact"
rm -rf "${SANDBOX}/.tdd/ops-preflight"
ERR=$(printf '%s' "$(jq -nc --arg c '__return_missing_risk__ x' '{command:$c}')" \
       | CLAUDE_PROJECT_DIR="${SANDBOX}" \
         CLAUDE_PLUGIN_ROOT="${SANDBOX}" \
         PRILIVE_OPS_PREFLIGHT_BIN="${STUB}" \
         bash "${SANDBOX}/runner/ops-preflight-review.sh" 2>&1 >/dev/null)
echo "${ERR}" | grep -qi "malformed verdict\|verdict\b" \
  || fail "expected validation error on missing risk; got: ${ERR}"
[[ ! -f "$(artifact_for "__return_missing_risk__ x")" ]] \
  || fail "malformed verdict was incorrectly cached as artifact"
pass "malformed verdict (no risk) rejected; no artifact"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 10: non-array required_prechecks → fail + NO artifact ---
info "[10] non-array required_prechecks (string instead of array) → fail"
rm -rf "${SANDBOX}/.tdd/ops-preflight"
ERR=$(printf '%s' "$(jq -nc --arg c '__return_non_array_prechecks__ x' '{command:$c}')" \
       | CLAUDE_PROJECT_DIR="${SANDBOX}" \
         CLAUDE_PLUGIN_ROOT="${SANDBOX}" \
         PRILIVE_OPS_PREFLIGHT_BIN="${STUB}" \
         bash "${SANDBOX}/runner/ops-preflight-review.sh" 2>&1 >/dev/null)
echo "${ERR}" | grep -qi "prechecks must be array" \
  || fail "expected validation error on non-array prechecks; got: ${ERR}"
pass "non-array prechecks rejected"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 11: empty stub stdout → fail + NO artifact ---
info "[11] empty reviewer output → fail, NO artifact"
rm -rf "${SANDBOX}/.tdd/ops-preflight"
ERR=$(printf '%s' "$(jq -nc --arg c '__return_empty__ x' '{command:$c}')" \
       | CLAUDE_PROJECT_DIR="${SANDBOX}" \
         CLAUDE_PLUGIN_ROOT="${SANDBOX}" \
         PRILIVE_OPS_PREFLIGHT_BIN="${STUB}" \
         bash "${SANDBOX}/runner/ops-preflight-review.sh" 2>&1 >/dev/null)
# Empty output triggers the malformed-verdict validation path.
[[ ! -f "$(artifact_for "__return_empty__ x")" ]] \
  || fail "empty reviewer output was incorrectly cached as artifact"
pass "empty reviewer output rejected; no artifact"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 12: stub exit nonzero → runner exits nonzero, no artifact ---
info "[12] stub exits 1 → runner exits nonzero, no artifact written"
rm -rf "${SANDBOX}/.tdd/ops-preflight"
printf '%s' "$(jq -nc --arg c '__return_nonzero__ x' '{command:$c}')" \
  | CLAUDE_PROJECT_DIR="${SANDBOX}" \
    CLAUDE_PLUGIN_ROOT="${SANDBOX}" \
    PRILIVE_OPS_PREFLIGHT_BIN="${STUB}" \
    bash "${SANDBOX}/runner/ops-preflight-review.sh" >/dev/null 2>&1
RC=$?
# When the stub injection is used, the runner uses the stub output regardless
# of stub exit code (the runner only checks codex exit when calling codex
# directly). With our stub returning exit 1, the OUT variable gets empty
# stdout, then validation fails, so runner exits 1.
[[ "${RC}" -ne 0 ]] || fail "runner should exit nonzero on stub failure"
[[ ! -f "$(artifact_for "__return_nonzero__ x")" ]] \
  || fail "stub failure was incorrectly cached as artifact"
pass "stub failure handled: runner exits nonzero, no artifact"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 13: empty stdin → fail + NO artifact ---
info "[13] empty stdin → fail with clear error"
rm -rf "${SANDBOX}/.tdd/ops-preflight"
ERR=$( : | CLAUDE_PROJECT_DIR="${SANDBOX}" \
            CLAUDE_PLUGIN_ROOT="${SANDBOX}" \
            PRILIVE_OPS_PREFLIGHT_BIN="${STUB}" \
            bash "${SANDBOX}/runner/ops-preflight-review.sh" 2>&1 >/dev/null )
echo "${ERR}" | grep -qi "empty stdin" \
  || fail "expected error mentioning empty stdin; got: ${ERR}"
pass "empty stdin rejected"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 14: artifact embeds the original command verbatim ---
info "[14] artifact embeds .command field with the verbatim proposed command"
CMD="__return_approve__ docker compose up -d --build my-precise-app"
run_runner "${CMD}" >/dev/null
ART=$(artifact_for "${CMD}")
EMBEDDED_CMD=$(jq -r '.command' "${ART}")
[[ "${EMBEDDED_CMD}" == "${CMD}" ]] \
  || fail "artifact.command != original command; expected '${CMD}', got '${EMBEDDED_CMD}'"
pass "artifact preserves verbatim command"
PASS_COUNT=$((PASS_COUNT+1))

echo ""
echo "================================================================"
echo "  OPS-PREFLIGHT-REVIEW SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
