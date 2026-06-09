#!/usr/bin/env bash
# scripts/research/probe-codex-sandbox.sh
#
# v2.3 task #105 slice 1 — automate the §3 empirical probes
# documented in docs/RESEARCH-codex-sandbox-features.md.
#
# Maintainers picking up slice 2 (or anyone validating the
# research on a different Codex CLI version) should run this
# script. Writes a structured JSON record to
# .tdd/research/codex-sandbox-features.json that captures:
#   - Codex CLI version + binary path
#   - Linux kernel (for the sandbox backend)
#   - The three sandbox-mode enum values (parsed from --help)
#   - Empirical probe results (A/B/C from §3)
#   - Timestamp
#
# Probes use `codex sandbox linux` to verify the Linux sandbox
# backend WITHOUT invoking the model — zero token cost. The
# slice 2 live smoke (with `codex exec` against a real prompt)
# is intentionally NOT part of this script — it costs tokens and
# is reserved for slice 2's counterfactual smoke.
#
# Usage:
#   bash scripts/research/probe-codex-sandbox.sh
#
# Exit codes:
#   0  probes ran (write may not have happened — check JSON)
#   1  codex CLI not installed / not in PATH
#   2  jq not available (needed for JSON record)
#   3  filesystem error writing record

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
OUT_DIR="${PROJECT_DIR}/.tdd/research"
OUT_FILE="${OUT_DIR}/codex-sandbox-features.json"

fail() { echo "✗ FAIL: $*" >&2; exit "${2:-1}"; }
info() { echo "▶ $*"; }

command -v codex >/dev/null 2>&1 || fail "codex CLI not in PATH" 1
command -v jq    >/dev/null 2>&1 || fail "jq not in PATH"        2

mkdir -p "${OUT_DIR}" || fail "cannot create ${OUT_DIR}" 3

# ---- Static probes (parsing --help / --version) ------------

CODEX_VERSION=$(codex --version 2>&1 | head -1)
CODEX_BIN=$(command -v codex)
KERNEL=$(uname -sr)
TS=$(date -u +%FT%TZ)

HELP_TEXT=$(codex exec --help 2>&1)

# Parse the sandbox enum from the help text. Format observed in
# 0.129.0: `[possible values: read-only, workspace-write, danger-full-access]`
SANDBOX_ENUM=$(printf '%s\n' "${HELP_TEXT}" \
  | grep -oE '\[possible values: [^]]+\]' \
  | head -1 \
  | sed -E 's/\[possible values: //; s/\]$//; s/, /\n/g')

# Detect documented flags. Use a substring search of the help text;
# clap formats long-form flags as `--name <ARG>` on their own line,
# sometimes with `-x, ` prefix. Looking for the long form alone is
# more robust than trying to anchor to the start of a line.
has_flag() {
  # Use `--` arg-terminator before the pattern so ugrep (the system's
  # grep on some Linux setups) doesn't try to interpret patterns
  # starting with `--` as its own options.
  local f="$1"
  printf '%s' "${HELP_TEXT}" | grep -qF -- "${f}"
}

FLAG_SANDBOX=$(has_flag '--sandbox <SANDBOX_MODE>' && echo true || echo false)
FLAG_ADD_DIR=$(has_flag '--add-dir <DIR>' && echo true || echo false)
FLAG_EPHEMERAL=$(has_flag '--ephemeral' && echo true || echo false)
FLAG_IGNORE_RULES=$(has_flag '--ignore-rules' && echo true || echo false)
FLAG_BYPASS=$(has_flag '--dangerously-bypass-approvals-and-sandbox' && echo true || echo false)

# ---- Empirical probes (codex sandbox linux; no model calls) ----

# Each probe runs the same flow:
#  1. Pick a unique target path under /tmp.
#  2. Run codex sandbox linux <cmd> attempting the write.
#  3. Record: command exit code, file existence afterwards,
#     any error message from inside the sandbox.

probe_write() {
  # probe_write <label> <target_path> <inside_command>
  local label="$1" target="$2" cmd="$3"
  local stderr exit_code present
  stderr=$(codex sandbox linux -- /bin/sh -c "${cmd}" 2>&1 >/dev/null)
  exit_code=$?
  if [[ -f "${target}" ]]; then
    present="true"
    rm -f "${target}"
  else
    present="false"
  fi
  jq -nc \
    --arg label "${label}" \
    --arg cmd "${cmd}" \
    --arg target "${target}" \
    --arg stderr "${stderr}" \
    --argjson exit_code "${exit_code}" \
    --arg file_present_after "${present}" \
    '{label:$label, command:$cmd, target:$target, exit_code:$exit_code, stderr:$stderr, file_present_after:$file_present_after}'
}

probe_read() {
  # probe_read <label> <path_to_read>
  local label="$1" path="$2"
  local stdout stderr exit_code
  stdout=$(codex sandbox linux -- /bin/sh -c "cat \"${path}\"" 2>/tmp/probe.err.$$)
  exit_code=$?
  stderr=$(cat /tmp/probe.err.$$ 2>/dev/null || true)
  rm -f /tmp/probe.err.$$
  jq -nc \
    --arg label "${label}" \
    --arg path "${path}" \
    --argjson exit_code "${exit_code}" \
    --arg stdout "${stdout}" \
    --arg stderr "${stderr}" \
    '{label:$label, path:$path, exit_code:$exit_code, stdout:$stdout, stderr:$stderr}'
}

UID_TAG="$$-$(date +%s)"

info "Probe A: default-sandbox /tmp write should fail"
PROBE_A=$(probe_write \
  "A_tmp_write_default" \
  "/tmp/codex-probe-A-${UID_TAG}.txt" \
  "echo TEST > /tmp/codex-probe-A-${UID_TAG}.txt")

info "Probe B: default-sandbox cwd write should fail"
TMPCWD=$(mktemp -d)
PROBE_B=$(cd "${TMPCWD}" && probe_write \
  "B_cwd_write_default" \
  "${TMPCWD}/codex-probe-B-${UID_TAG}.txt" \
  "echo TEST > ./codex-probe-B-${UID_TAG}.txt")
rm -rf "${TMPCWD}"

info "Probe C: default-sandbox read of /etc/hostname should succeed"
PROBE_C=$(probe_read "C_read_etc_hostname" "/etc/hostname")

# ---- Assemble JSON record ----------------------------------

# Sandbox enum into a JSON array.
SANDBOX_ENUM_JSON=$(printf '%s\n' "${SANDBOX_ENUM}" \
  | grep -v '^$' \
  | jq -R . | jq -s .)

jq -n \
  --arg ts "${TS}" \
  --arg bin "${CODEX_BIN}" \
  --arg ver "${CODEX_VERSION}" \
  --arg kernel "${KERNEL}" \
  --argjson sandbox_enum "${SANDBOX_ENUM_JSON}" \
  --arg flag_sandbox "${FLAG_SANDBOX}" \
  --arg flag_add_dir "${FLAG_ADD_DIR}" \
  --arg flag_ephemeral "${FLAG_EPHEMERAL}" \
  --arg flag_ignore_rules "${FLAG_IGNORE_RULES}" \
  --arg flag_bypass "${FLAG_BYPASS}" \
  --argjson probe_a "${PROBE_A}" \
  --argjson probe_b "${PROBE_B}" \
  --argjson probe_c "${PROBE_C}" \
  '{
    schema_version: 1,
    captured_at: $ts,
    host: { codex_binary: $bin, codex_version: $ver, kernel: $kernel },
    static: {
      sandbox_modes: $sandbox_enum,
      flags: {
        sandbox: ($flag_sandbox == "true"),
        add_dir: ($flag_add_dir == "true"),
        ephemeral: ($flag_ephemeral == "true"),
        ignore_rules: ($flag_ignore_rules == "true"),
        dangerously_bypass_approvals_and_sandbox: ($flag_bypass == "true")
      }
    },
    empirical: { probe_a: $probe_a, probe_b: $probe_b, probe_c: $probe_c },
    notes: "Generated by scripts/research/probe-codex-sandbox.sh. See docs/RESEARCH-codex-sandbox-features.md for analysis. Probes use codex sandbox linux directly (no model invocation, zero token cost). The live codex exec --sandbox workspace-write smoke is reserved for slice 2."
  }' > "${OUT_FILE}" || fail "could not write ${OUT_FILE}" 3

echo "✓ Wrote ${OUT_FILE}"
echo ""
echo "Findings summary:"
echo "  codex version:        $(jq -r '.host.codex_version' "${OUT_FILE}")"
echo "  sandbox modes:        $(jq -r '.static.sandbox_modes | join(", ")' "${OUT_FILE}")"
echo "  --sandbox flag:       $(jq -r '.static.flags.sandbox' "${OUT_FILE}")"
echo "  --add-dir flag:       $(jq -r '.static.flags.add_dir' "${OUT_FILE}")"
echo "  --ephemeral flag:     $(jq -r '.static.flags.ephemeral' "${OUT_FILE}")"
echo "  --ignore-rules flag:  $(jq -r '.static.flags.ignore_rules' "${OUT_FILE}")"
echo "  bypass flag exists:   $(jq -r '.static.flags.dangerously_bypass_approvals_and_sandbox' "${OUT_FILE}")"
echo "  probe A (tmp write, default):  exit=$(jq -r '.empirical.probe_a.exit_code' "${OUT_FILE}"), file_after=$(jq -r '.empirical.probe_a.file_present_after' "${OUT_FILE}")"
echo "  probe B (cwd write, default):  exit=$(jq -r '.empirical.probe_b.exit_code' "${OUT_FILE}"), file_after=$(jq -r '.empirical.probe_b.file_present_after' "${OUT_FILE}")"
echo "  probe C (read /etc/hostname):  exit=$(jq -r '.empirical.probe_c.exit_code' "${OUT_FILE}")"
exit 0
