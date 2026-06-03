#!/usr/bin/env bash
# test/smoke-protect-tdd-artifacts-traversal.sh
#
# v2.1 release guard (Blocker 6). The Gate 4 hook normalized paths with a
# literal prefix strip and literal matching, so a non-canonical path
# (traversal, dot-relative, bare-relative, symlinked dir) bypassed the gate
# and fell through to ALLOW. Gate 4 is the evidence-chain integrity
# boundary, so a silent bypass defeats FDTDD's trust model.
#
# This test feeds the hook the bypass routes and asserts each is DENIED,
# and that a normal source file and an out-of-project path are NOT denied.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${PROJECT_ROOT}/hooks/protect-tdd-artifacts.sh"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
PASS_COUNT=0

command -v jq >/dev/null 2>&1 || fail "jq required"

CLEANUP=()
trap 'for p in "${CLEANUP[@]}"; do [[ -n "$p" ]] && rm -rf "$p"; done' EXIT

SANDBOX=$(mktemp -d); CLEANUP+=("${SANDBOX}")
mkdir -p "${SANDBOX}/.tdd/findings/R1-F1" "${SANDBOX}/sub" "${SANDBOX}/internal/auth"

# Run the hook with a given tool_input.file_path; echo "deny" or "allow".
run_gate() {
  local fp="$1"
  local input
  input=$(jq -nc --arg fp "$fp" '{tool_name:"Write", tool_input:{file_path:$fp, content:"x"}}')
  local out
  out=$(CLAUDE_PROJECT_DIR="${SANDBOX}" printf '%s' "${input}" | CLAUDE_PROJECT_DIR="${SANDBOX}" bash "${HOOK}" 2>/dev/null)
  if grep -q '"permissionDecision": *"deny"' <<< "${out}" 2>/dev/null \
     || jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 <<< "${out}"; then
    echo "deny"
  else
    echo "allow"
  fi
}

PROT=".tdd/findings/R1-F1/finding.json"

info "[1] canonical absolute path to protected artifact → deny"
[[ "$(run_gate "${SANDBOX}/${PROT}")" == "deny" ]] || fail "canonical abs not denied"
pass "canonical absolute → deny"
PASS_COUNT=$((PASS_COUNT+1))

info "[2] traversal path (sub/../) to protected artifact → deny"
[[ "$(run_gate "${SANDBOX}/sub/../${PROT}")" == "deny" ]] || fail "traversal bypass NOT denied (regression)"
pass "traversal → deny"
PASS_COUNT=$((PASS_COUNT+1))

info "[3] dot-relative path → deny (hook cwd is project root)"
# The hook resolves relative paths against its own cwd; emulate by cd'ing.
out=$(cd "${SANDBOX}" && printf '%s' "$(jq -nc --arg fp "./${PROT}" '{tool_name:"Write",tool_input:{file_path:$fp,content:"x"}}')" | CLAUDE_PROJECT_DIR="${SANDBOX}" bash "${HOOK}" 2>/dev/null)
jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 <<< "${out}" \
  || fail "dot-relative bypass NOT denied (regression)"
pass "dot-relative → deny"
PASS_COUNT=$((PASS_COUNT+1))

info "[4] normal source file → allow (no over-block)"
[[ "$(run_gate "${SANDBOX}/internal/auth/login.go")" == "allow" ]] || fail "normal source over-blocked"
pass "normal source → allow"
PASS_COUNT=$((PASS_COUNT+1))

info "[5] out-of-project path → allow (not ours to protect)"
[[ "$(run_gate "/etc/hosts")" == "allow" ]] || fail "out-of-project path incorrectly denied"
pass "out-of-project → allow"
PASS_COUNT=$((PASS_COUNT+1))

info "[6] symlinked directory into .tdd → deny"
ln -s "${SANDBOX}/.tdd" "${SANDBOX}/link-to-tdd" 2>/dev/null || true
if [[ -L "${SANDBOX}/link-to-tdd" ]]; then
  [[ "$(run_gate "${SANDBOX}/link-to-tdd/findings/R1-F1/finding.json")" == "deny" ]] \
    || fail "symlinked-dir route NOT denied (regression)"
  pass "symlinked dir → deny"
  PASS_COUNT=$((PASS_COUNT+1))
else
  info "    (symlink unsupported here; skipping case 6)"
fi

echo ""
echo "================================================================"
echo "  GATE 4 TRAVERSAL SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
exit 0
