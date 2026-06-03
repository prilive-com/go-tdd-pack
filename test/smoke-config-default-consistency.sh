#!/usr/bin/env bash
# test/smoke-config-default-consistency.sh
#
# v2.1 release guard (Blocker 2). tdd-pack.toml shipped pre_review.enabled
# = true while its own comments said "Off by default … no behavior change"
# and the precedence comment ended "Otherwise → OFF". An adopter copying the
# config got pre-write gating on by default.
#
# This test asserts the shipped value matches the documented promise: the
# [pre_review] block must ship enabled = false. Users opt in explicitly
# (set enabled = true, or PRILIVE_PRE_REVIEW_EXPERIMENTAL=1).

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOML="${PROJECT_ROOT}/tdd-pack.toml"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
PASS_COUNT=0

[[ -f "${TOML}" ]] || fail "tdd-pack.toml not found"

# Pull the enabled value from inside the [pre_review] section only.
info "[1] [pre_review] ships enabled = false (matches 'off by default' docs)"
VALUE=$(awk '
  /^\[pre_review\]/ { in_s=1; next }
  /^\[/             { in_s=0 }
  in_s && /^[[:space:]]*enabled[[:space:]]*=/ {
    sub(/^[[:space:]]*enabled[[:space:]]*=[[:space:]]*/, "")
    sub(/[[:space:]]*#.*$/, "")
    gsub(/[[:space:]]/, "")
    print; exit
  }
' "${TOML}")
[[ -n "${VALUE}" ]] || fail "no enabled key found in [pre_review] block"
[[ "${VALUE}" == "false" ]] \
  || fail "[pre_review] enabled = ${VALUE}; must be false for the shipped default (docs say off-by-default). Users opt in explicitly."
pass "[pre_review] enabled = false"
PASS_COUNT=$((PASS_COUNT+1))

# The block must still document the opt-in path so the default isn't a
# silent dead end.
info "[2] opt-in path is documented in the [pre_review] block"
BLOCK=$(awk '/^\[pre_review\]/{in_s=1} /^\[/&&!/^\[pre_review\]/{if(seen)in_s=0} {if(in_s)print} /^\[pre_review\]/{seen=1}' "${TOML}")
grep -q "PRILIVE_PRE_REVIEW_EXPERIMENTAL" <<< "${BLOCK}" \
  || fail "opt-in env override not documented in [pre_review] block"
pass "opt-in path (PRILIVE_PRE_REVIEW_EXPERIMENTAL) documented"
PASS_COUNT=$((PASS_COUNT+1))

echo ""
echo "================================================================"
echo "  CONFIG DEFAULT CONSISTENCY SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
exit 0
