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

# v2.3.2: model key MUST be present and quoted. Value can be:
#   ""        — DEFAULT. No pin. Runner omits --model; Codex CLI applies
#               its own default (currently gpt-5.5 per OpenAI June-2026
#               docs, works on both ChatGPT-auth and API-key auth).
#               When OpenAI updates the default, we auto-track.
#   "auto"    — resolver reads ~/.codex/models_cache.json and picks
#               highest-priority slug. Fallback when cache fails: empty.
#   "<slug>"  — explicit pin (e.g. "gpt-5.5", "gpt-5.5-codex"). Stale-
#               by-design; the adopter maintains the bump cadence.
#
# History this smoke captures:
#   v2.1.0 shipped model = "" (trust upstream).
#   v2.1.1 forced shipped model to be non-empty after Codex CLI 0.130
#     changed its default to gpt-5.3-codex (paid-only) and broke every
#     fresh subscription account on first cycle.
#   v2.3.0/v2.3.1 kept pinning a specific slug ("gpt-5.5", then
#     auth-aware split).
#   v2.3.2 REVERTS to "" by explicit decision: the user refuses to
#     keep patching pins as OpenAI ships new minors. The v2.1.1
#     incident is on OpenAI to fix going forward.
#
# This smoke now asserts: model key exists, value is a string. ANY
# value (including "") is valid.
info "[3] [codex] ships model key (any string value is valid in v2.3.2)"
MODEL=$(awk '
  /^\[codex\]/ { in_s=1; next }
  /^\[/        { in_s=0 }
  in_s && /^[[:space:]]*model[[:space:]]*=/ {
    sub(/^[[:space:]]*model[[:space:]]*=[[:space:]]*/, "")
    sub(/[[:space:]]*#.*$/, "")
    gsub(/^[[:space:]]+|[[:space:]]+$/, "")
    print; exit
  }
' "${TOML}")
# Fall back to file-wide search if the file is not sectioned with [codex].
if [[ -z "${MODEL}" ]]; then
  MODEL=$(awk '
    /^[[:space:]]*model[[:space:]]*=/ {
      sub(/^[[:space:]]*model[[:space:]]*=[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      print; exit
    }
  ' "${TOML}")
fi
# We just need the assignment to exist. MODEL captures the literal
# RHS including quotes. Empty string + quotes ("") is a VALID value.
case "${MODEL}" in
  '""'|'"'*'"') pass "model = ${MODEL} (quoted string, any value valid in v2.3.2)" ;;
  '')           fail "no model key found in tdd-pack.toml" ;;
  *)            fail "model value must be a quoted string; got: ${MODEL}" ;;
esac
PASS_COUNT=$((PASS_COUNT+1))

# v2.2 slice 1: ops-triage ships disabled. Adopters opt in by editing
# tdd-pack.toml + creating the two config/ops-*.txt files. The pack
# itself must NOT ship enabled=true (same lesson as v2.1.1 Bug 2 —
# shipped default must match the "off by default" promise).
info "[4] [ops_triage] ships enabled = false (matches 'opt-in' docs)"
OPS=$(awk '
  /^\[ops_triage\]/ { in_s=1; next }
  /^\[/             { in_s=0 }
  in_s && /^[[:space:]]*enabled[[:space:]]*=/ {
    sub(/^[[:space:]]*enabled[[:space:]]*=[[:space:]]*/, "")
    sub(/[[:space:]]*#.*$/, "")
    gsub(/[[:space:]]/, "")
    print; exit
  }
' "${TOML}")
[[ -n "${OPS}" ]] || fail "no enabled key found in [ops_triage] block"
[[ "${OPS}" == "false" ]] \
  || fail "[ops_triage] enabled = ${OPS}; must be false for the shipped default (slice 1 ships observe-mode logging only; adopters opt in explicitly)."
pass "[ops_triage] enabled = false"
PASS_COUNT=$((PASS_COUNT+1))

echo ""
echo "================================================================"
echo "  CONFIG DEFAULT CONSISTENCY SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
exit 0
