#!/usr/bin/env bash
# test/smoke-plugin-manifest-v21.sh
#
# v2.1 release guard (Blocker 1 + part of Blocker 3). The plugin manifest
# .claude-plugin/plugin.json shipped stale: version 2.0.1, a Bash
# PostToolUse matcher (the thing PR 1 deleted), and no registration of the
# v2.1 hooks (protect-tdd-artifacts.sh, pre-review.sh). A plugin-path
# adopter would silently get v2.0.1 behavior.
#
# This test asserts the manifest is v2.1-correct and that its hook graph
# matches the canonical hooks/settings.json on the load-bearing points.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${PROJECT_ROOT}/.claude-plugin/plugin.json"
HOOKS_SETTINGS="${PROJECT_ROOT}/hooks/settings.json"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
PASS_COUNT=0

command -v jq >/dev/null 2>&1 || fail "jq required"
[[ -f "${MANIFEST}" ]] || fail "plugin manifest not found"

info "[1] manifest version is 2.1.x"
VER=$(jq -r '.version // empty' "${MANIFEST}")
[[ "${VER}" == 2.1.* ]] || fail "manifest version is '${VER}', expected 2.1.x"
pass "version = ${VER}"
PASS_COUNT=$((PASS_COUNT+1))

info "[2] Bash matchers in manifest: only the v2.2 ops-risk-triage hook (no PR-1-style code-review Bash matchers)"
# v2.1 deleted the Bash matcher that fired post-edit-review.sh on every Bash
# command (PR #19). v2.2 slice 1 re-introduces a Bash matcher for a DIFFERENT
# purpose: ops-risk-triage classifies runtime safety, not code quality, and
# is disabled-by-default. Any Bash matcher in the manifest MUST be wired only
# to ops-risk-triage.sh. Anything else is a v2.1 regression.
BASH_BLOCKS=$(jq -r '
  [.hooks // {} | to_entries[] | .value[]?
    | select((.matcher // "") | test("(^|\\|)Bash(\\||$)"))]
' "${MANIFEST}")
# Every Bash-matched hook must reference ops-risk-triage.sh (and nothing
# else from the v2.1 code-review path).
OFFENDERS=$(jq -r '
  .[] | .hooks[] | .command
  | select(test("ops-risk-triage\\.sh$") | not)
' <<<"${BASH_BLOCKS}")
[[ -z "${OFFENDERS}" ]] \
  || fail "manifest has Bash matcher(s) wired to non-ops-triage hook(s) — v2.1 PR 1 regression: ${OFFENDERS}"
pass "Bash matchers in manifest reference ops-risk-triage only (no PR 1 regression)"
PASS_COUNT=$((PASS_COUNT+1))

info "[3] PreToolUse registers protect-tdd-artifacts.sh BEFORE pre-review.sh"
PRE_CMDS=$(jq -r '
  [.hooks.PreToolUse[]?
    | select((.matcher // "") | test("Edit|Write|MultiEdit|NotebookEdit"))
    | .hooks[]?.command]
  | @tsv
' "${MANIFEST}")
grep -q "protect-tdd-artifacts.sh" <<< "${PRE_CMDS}" \
  || fail "protect-tdd-artifacts.sh (Gate 4) not registered on PreToolUse"
grep -q "pre-review.sh" <<< "${PRE_CMDS}" \
  || fail "pre-review.sh not registered on PreToolUse"
# Order: artifact protection must precede pre-review.
GATE_POS=$(awk '{for(i=1;i<=NF;i++) if($i ~ /protect-tdd-artifacts/) print i}' <<< "${PRE_CMDS}")
REVIEW_POS=$(awk '{for(i=1;i<=NF;i++) if($i ~ /pre-review/) print i}' <<< "${PRE_CMDS}")
[[ -n "${GATE_POS}" && -n "${REVIEW_POS}" && "${GATE_POS}" -lt "${REVIEW_POS}" ]] \
  || fail "protect-tdd-artifacts.sh must run before pre-review.sh (got positions gate=${GATE_POS}, review=${REVIEW_POS})"
pass "Gate 4 registered before pre-review on PreToolUse"
PASS_COUNT=$((PASS_COUNT+1))

info "[4] PostToolUse matcher is file-only (no Bash)"
PT_MATCHERS=$(jq -r '[.hooks.PostToolUse[]? | .matcher // ""] | join(",")' "${MANIFEST}")
grep -q "Bash" <<< "${PT_MATCHERS}" \
  && fail "PostToolUse still has a Bash matcher: ${PT_MATCHERS}"
pass "PostToolUse matchers are file-only: ${PT_MATCHERS}"
PASS_COUNT=$((PASS_COUNT+1))

# Cross-check: the set of PreToolUse commands in the manifest matches the
# canonical hooks/settings.json (load-bearing parity, ignoring ${VAR} prefix).
if [[ -f "${HOOKS_SETTINGS}" ]]; then
  info "[5] manifest PreToolUse command set matches hooks/settings.json"
  norm() { jq -r '[.hooks.PreToolUse[]? | .hooks[]?.command] | map(sub(".*/hooks/";"hooks/")) | sort | .[]' "$1"; }
  M=$(norm "${MANIFEST}")
  H=$(norm "${HOOKS_SETTINGS}")
  [[ "${M}" == "${H}" ]] \
    || fail "PreToolUse command set differs between manifest and hooks/settings.json:
manifest:
${M}
hooks/settings.json:
${H}"
  pass "PreToolUse command set matches canonical hooks/settings.json"
  PASS_COUNT=$((PASS_COUNT+1))
fi

echo ""
echo "================================================================"
echo "  PLUGIN MANIFEST v2.1 SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
exit 0
