#!/usr/bin/env bash
# test/smoke-ops-triage-slice1.sh
#
# v2.2 slice 1 smoke for hooks/ops-risk-triage.sh.
# Covers ONLY the slice 1 scope:
#   - Disabled-safe (kill switch + config) → silent allow, no log
#   - Tool gating (non-Bash) → silent allow
#   - Layer 1 fast-path (safe NAME + safe SHAPE) → silent allow, no log
#   - Layer 1 name-OK + shape-UNSAFE → falls through, log "would_classify"
#   - Layer 1b catastrophic denylist match → log "denylist_match", ALLOW
#     (slice 1 is observe-only; slice 3 will convert this to deny)
#   - Layer 1b near-miss → does NOT match, falls through
#   - Mode degradation (ask/governed) → logs "degraded_to_observe", allows
#   - Counterfactual: every shape_unsafe trigger from the parser, asserted
#     to defeat the fast-path even on a name-allowlisted command.
#
# Each "match" assertion is paired with a "near-miss does NOT match"
# assertion, per the v2.1.1 lesson (smoke-schema-strict-mode counterfactual
# pattern). A regex that catches the bug AND fires on benign cases is worse
# than no regex.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${PROJECT_ROOT}/hooks/ops-risk-triage.sh"
SAFE_EX="${PROJECT_ROOT}/config/ops-safe-allowlist.txt.example"
DENY_EX="${PROJECT_ROOT}/config/ops-catastrophic-denylist.txt.example"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
PASS_COUNT=0

command -v jq >/dev/null 2>&1 || fail "jq required"
[[ -x "${HOOK}" ]] || fail "hook missing or not executable: ${HOOK}"
[[ -f "${SAFE_EX}" ]] || fail "safe allowlist example missing"
[[ -f "${DENY_EX}" ]] || fail "denylist example missing"

# Sandbox the hook so we don't touch the real project tree.
CLEANUP=()
_cleanup() {
  local p
  for p in "${CLEANUP[@]}"; do
    [[ -n "${p}" ]] && rm -rf "${p}"
  done
}
trap _cleanup EXIT

SANDBOX=$(mktemp -d); CLEANUP+=("${SANDBOX}")
mkdir -p "${SANDBOX}/config" "${SANDBOX}/runner/lib"
cp "${SAFE_EX}" "${SANDBOX}/config/ops-safe-allowlist.txt"
cp "${DENY_EX}" "${SANDBOX}/config/ops-catastrophic-denylist.txt"
# Hook sources runner/lib/config.sh for the real cfg_get; mirror it into
# the sandbox so cfg_get parses our test tdd-pack.toml correctly.
cp "${PROJECT_ROOT}/runner/lib/config.sh" "${SANDBOX}/runner/lib/config.sh"

# Minimal tdd-pack.toml with the [ops_triage] section enabled.
cat > "${SANDBOX}/tdd-pack.toml" <<'EOF'
[ops_triage]
enabled = true
mode = "observe"
EOF

LOG="${SANDBOX}/.tdd/ops-triage/observe.log"

# Invoke the hook with a constructed PreToolUse JSON and a given mode/cfg
# override. Returns the hook's stdout. Resets the log before each call.
run_hook() {
  local cmd="$1" mode="${2:-observe}" enabled="${3:-true}"
  rm -f "${LOG}"
  cat > "${SANDBOX}/tdd-pack.toml" <<EOF
[ops_triage]
enabled = ${enabled}
mode = "${mode}"
EOF
  local payload
  payload=$(jq -nc --arg c "${cmd}" '{tool_name:"Bash", tool_input:{command:$c}}')
  CLAUDE_PROJECT_DIR="${SANDBOX}" PRILIVE_REVIEW_DISABLE="${PRILIVE_REVIEW_DISABLE:-}" \
    bash "${HOOK}" <<<"${payload}" 2>/dev/null
}

# log_has <verdict_substr> — does the last hook call's log contain a line
# with the given verdict?
log_has() {
  [[ -f "${LOG}" ]] || return 1
  grep -q "\"verdict\":\"$1\"" "${LOG}"
}

# log_empty — was no log entry written?
log_empty() {
  [[ ! -s "${LOG}" ]]
}

# Hook must always emit empty stdout in slice 1 (observe-only, never JSON).
out_empty() { [[ -z "$1" ]]; }

# --- check 1: kill switch (env) → silent allow, no log ---
info "[1] PRILIVE_REVIEW_DISABLE=1 → silent allow, no log"
OUT=$(PRILIVE_REVIEW_DISABLE=1 run_hook "rm -rf /etc/passwd")
out_empty "${OUT}" && log_empty || fail "kill switch: expected empty stdout + empty log; got out='${OUT}' log=$(cat "${LOG}" 2>/dev/null)"
pass "kill switch honored"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 2: config disabled → silent allow, no log ---
info "[2] [ops_triage] enabled=false → silent allow, no log"
OUT=$(run_hook "rm -rf /etc/passwd" observe false)
out_empty "${OUT}" && log_empty || fail "disabled: expected empty stdout + empty log"
pass "disabled-safe honored"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 3: mode=off → silent allow, no log ---
info "[3] mode=off → silent allow, no log"
OUT=$(run_hook "rm -rf /etc/passwd" off true)
out_empty "${OUT}" && log_empty || fail "mode=off: expected empty stdout + empty log"
pass "mode=off honored"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 4: non-Bash tool → silent allow, no log ---
info "[4] non-Bash tool → silent allow, no log"
rm -f "${LOG}"
PAYLOAD=$(jq -nc '{tool_name:"Write", tool_input:{file_path:"x.txt", content:"x"}}')
OUT=$(CLAUDE_PROJECT_DIR="${SANDBOX}" bash "${HOOK}" <<<"${PAYLOAD}" 2>/dev/null)
out_empty "${OUT}" && log_empty || fail "non-Bash: expected empty stdout + empty log"
pass "non-Bash tools skipped"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 5: Layer 1 fast-path (trivially safe) → silent allow, no log ---
info "[5] Layer 1 fast-path: trivially safe commands → silent allow, no log"
for c in "pwd" "ls" "git status" "git diff" "docker ps" "kubectl get pods" "go version"; do
  OUT=$(run_hook "${c}")
  out_empty "${OUT}" && log_empty || fail "fast-path: '${c}' should have silent-allowed; out='${OUT}' log=$(cat "${LOG}" 2>/dev/null)"
done
pass "Layer 1 fast-path: 7 trivially-safe commands silent-allowed"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 6: name-OK + shape-UNSAFE → falls through, log "would_classify" ---
# This is the counterfactual on the shape_unsafe parser. Each of these
# starts with an allowlisted name BUT has a shape feature that disqualifies
# it — output redirection, chaining, command substitution, sudo, secret
# path. If shape_unsafe misses any of these, the bug shows up immediately.
info "[6] Layer 1 shape-unsafe (name OK but shape disqualifies) → fall through"
for c in \
  'pwd > leak.txt' \
  'ls && rm -rf /tmp/x' \
  'cat .env' \
  'echo $(whoami)' \
  'echo `whoami`' \
  'sudo ls' \
  'ls | xargs echo' \
  'cat <(echo x)' \
  'ls > /dev/null' \
  'pwd >> log' \
  'cat <<< hello' \
  'cat key.pem' \
  'cat my-id_rsa' \
  ; do
  OUT=$(run_hook "${c}")
  out_empty "${OUT}" || fail "shape-unsafe '${c}': expected empty stdout (slice 1 observe); got '${OUT}'"
  log_has "would_classify_in_slice2" \
    || fail "shape-unsafe '${c}': expected log 'would_classify_in_slice2'; log=$(cat "${LOG}" 2>/dev/null)"
done
pass "Layer 1 shape-unsafe: 13 disqualifying shapes correctly fell through (counterfactual)"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 7: Layer 1b denylist TRUE-POSITIVE matches ---
# Each should LOG denylist_match (slice 1 observe; slice 3 will deny).
info "[7] Layer 1b denylist: true-positive matches"
declare -A DENY_POS=(
  ["rm -rf /"]="recursive root rm"
  ["rm -rf ~"]="recursive home rm"
  ["mkfs.ext4 /dev/sda1"]="mkfs"
  ["dd if=/dev/zero of=/dev/sda bs=1M"]="dd to device"
  ["terraform apply -auto-approve"]="terraform apply auto-approve"
  ["terraform destroy -auto-approve"]="terraform destroy auto-approve"
  ["git push --force origin main"]="force push long flag to main"
  ["git push -f origin main"]="force push short flag to main"
  ["DROP DATABASE prod"]="drop db"
  ["TRUNCATE TABLE users"]="truncate"
  ["kubectl delete namespace prod"]="kubectl delete namespace"
  ["kubectl -n prod delete namespace foo"]="kubectl flag-order delete namespace"
  ["kubectl delete pvc -A"]="kubectl delete pvc -A"
  ["kubectl delete --all"]="kubectl delete --all"
  ["helm uninstall myrelease"]="helm uninstall"
  ["aws secretsmanager rotate-secret --secret-id foo"]="aws secret rotate"
  ["drizzle-kit push --force"]="drizzle force push"
)
for cmd in "${!DENY_POS[@]}"; do
  OUT=$(run_hook "${cmd}")
  out_empty "${OUT}" || fail "denylist '${cmd}' (${DENY_POS[$cmd]}): expected empty stdout in slice 1; got '${OUT}'"
  log_has "denylist_match" \
    || fail "denylist '${cmd}' (${DENY_POS[$cmd]}): expected 'denylist_match' log; log=$(cat "${LOG}" 2>/dev/null)"
done
pass "Layer 1b: ${#DENY_POS[@]} true-positive matches logged correctly"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 8: Layer 1b denylist NEAR-MISS does NOT match (counterfactual) ---
# A regex that catches the bug AND fires on benign cases is worse than no
# regex. Each of these is intentionally close to a denylist pattern but
# should NOT match.
info "[8] Layer 1b denylist: near-misses do NOT match (counterfactual)"
declare -A DENY_NEG=(
  ["rm -rf /tmp/build"]="contained rm (NOT root)"
  ["git push --force-with-lease origin main"]="force-with-lease is safe"
  ["git push origin feature/x"]="non-force push"
  ["kubectl delete pod my-pod"]="delete pod (self-heals)"
  ["kubectl delete deployment myapp"]="delete deployment (separate tier)"
  ["terraform plan"]="plan is read-only"
  ["terraform apply"]="apply WITHOUT auto-approve (operator confirms)"
  ["dd if=/dev/zero of=/tmp/file bs=1M count=10"]="dd to file (not /dev/disk)"
  ["helm upgrade myrelease ./chart"]="helm upgrade (has rollback)"
  ["echo DROP DATABASE prod"]="echo string (not real SQL)"
)
for cmd in "${!DENY_NEG[@]}"; do
  OUT=$(run_hook "${cmd}")
  # In slice 1 observe, near-misses fall through and log "would_classify"
  # (not "denylist_match"). The KEY assertion is no denylist_match.
  out_empty "${OUT}" || fail "near-miss '${cmd}' (${DENY_NEG[$cmd]}): expected empty stdout; got '${OUT}'"
  if log_has "denylist_match"; then
    fail "near-miss '${cmd}' (${DENY_NEG[$cmd]}): unexpected denylist_match in log; log=$(cat "${LOG}" 2>/dev/null)"
  fi
done
pass "Layer 1b: ${#DENY_NEG[@]} near-misses correctly did NOT match"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 9: mode degradation (ask/governed degrade to observe in slice 1) ---
info "[9] mode=ask/governed degrade to observe in slice 1 + log warning"
for m in "ask" "governed"; do
  OUT=$(run_hook "docker compose restart app" "${m}")
  out_empty "${OUT}" || fail "mode=${m}: slice 1 must NOT emit JSON; got '${OUT}'"
  log_has "would_classify_in_slice2" || fail "mode=${m}: expected fall-through log entry"
  log_has "degraded_to_observe" || fail "mode=${m}: expected 'degraded_to_observe' warning log"
done
pass "Modes ask + governed degrade to observe with warning logged"
PASS_COUNT=$((PASS_COUNT+1))

# --- check 10: log format is valid JSONL ---
info "[10] log entries are valid JSONL (one verdict per line, well-formed)"
run_hook "docker compose up -d --build app" >/dev/null
ENTRIES=$(wc -l < "${LOG}")
[[ "${ENTRIES}" -ge 1 ]] || fail "expected at least one log entry"
while IFS= read -r line; do
  jq empty <<<"${line}" 2>/dev/null || fail "malformed JSONL line: ${line}"
done < "${LOG}"
pass "log is well-formed JSONL (${ENTRIES} entries)"
PASS_COUNT=$((PASS_COUNT+1))

echo ""
echo "================================================================"
echo "  OPS-TRIAGE SLICE 1 SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
