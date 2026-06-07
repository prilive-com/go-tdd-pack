#!/usr/bin/env bash
# hooks/ops-debt-track.sh
#
# v2.2 slice 5 — PostToolUse Bash hook that records "ops-debt": a
# mutating/destructive command that ran without a Codex preflight
# review. The Stop hook (hooks/ops-debt-stop.sh) reads these entries
# and blocks turn-end until they're resolved.
#
# How debt is determined:
#   1. Read the most recent verdict for this command from
#      .tdd/ops-triage/observe.log.
#   2. If the verdict's risk is local_mutation / infra_mutation /
#      destructive AND no .tdd/ops-preflight/<sha256(command)>.json
#      artifact exists, write a debt entry at
#      .tdd/ops-debt/<sha256(command)>.json.
#   3. If a preflight artifact DOES exist (operator ran /ops-preflight),
#      clear any matching debt entry — the obligation is satisfied.
#
# This hook is silent. It never blocks the Bash, never injects context.
# It just records state for the Stop hook to act on.
#
# Disabled-safe: PRILIVE_REVIEW_DISABLE=1 or [ops_triage] enabled=false
# → exit 0 immediately. ops-debt only tracks when triage itself is on.

set -uo pipefail

[[ "${PRILIVE_REVIEW_DISABLE:-}" == "1" ]] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
TOML="${PROJECT_DIR}/tdd-pack.toml"
LIB="${CLAUDE_PLUGIN_ROOT:-${PROJECT_DIR}}/runner/lib"

if [[ -f "${LIB}/config.sh" ]]; then
  # shellcheck source=../runner/lib/config.sh
  . "${LIB}/config.sh"
else
  cfg_get() { echo "$3"; }
fi

ENABLED=$(cfg_get "${TOML}" "ops_triage.enabled" "false")
[[ "${ENABLED}" != "true" && "${PRILIVE_OPS_TRIAGE:-}" != "1" ]] && exit 0

MODE=$(cfg_get "${TOML}" "ops_triage.mode" "ask")
[[ "${MODE}" == "off" ]] && exit 0
# Observe mode does not block on debt; tracking it would be misleading.
[[ "${MODE}" == "observe" ]] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null || true)
[[ -z "${INPUT}" ]] && exit 0

TOOL=$(printf '%s' "${INPUT}" | jq -r '.tool_name // empty' 2>/dev/null)
[[ "${TOOL}" != "Bash" ]] && exit 0

CMD=$(printf '%s' "${INPUT}" | jq -r '.tool_input.command // empty' 2>/dev/null)
[[ -z "${CMD}" ]] && exit 0

LOG="${PROJECT_DIR}/.tdd/ops-triage/observe.log"
[[ -f "${LOG}" ]] || exit 0

DEBT_DIR="${PROJECT_DIR}/.tdd/ops-debt"
PREFLIGHT_DIR="${PROJECT_DIR}/.tdd/ops-preflight"
HASH=$(printf '%s' "${CMD}" | sha256sum | cut -d' ' -f1)
DEBT_FILE="${DEBT_DIR}/${HASH}.json"
PREFLIGHT_FILE="${PREFLIGHT_DIR}/${HASH}.json"

# If a preflight artifact exists, the operator satisfied the obligation.
# Clear any matching debt entry and exit.
if [[ -f "${PREFLIGHT_FILE}" ]]; then
  [[ -f "${DEBT_FILE}" ]] && rm -f "${DEBT_FILE}" 2>/dev/null
  exit 0
fi

# Find the most recent L2 verdict for this exact command in the log.
# JSONL grep + last-match-wins by line.
VERDICT_LINE=$(grep -F "\"command\":\"${CMD//\"/\\\"}\"" "${LOG}" 2>/dev/null \
                | grep '"layer":"L2"' \
                | tail -1)
[[ -z "${VERDICT_LINE}" ]] && exit 0

RISK=$(jq -r '.verdict // empty' <<<"${VERDICT_LINE}" 2>/dev/null)
case "${RISK}" in
  local_mutation|infra_mutation|destructive) ;;
  *) exit 0 ;;   # not mutating → no debt
esac

mkdir -p "${DEBT_DIR}" 2>/dev/null
jq -nc \
   --arg cmd "${CMD}" \
   --arg risk "${RISK}" \
   --arg ts "$(date -u +%FT%TZ)" \
   --arg hash "${HASH}" \
   '{command:$cmd, risk:$risk, command_hash:$hash, created_at:$ts,
     note:"Mutating command ran without /ops-preflight artifact. Run /ops-preflight to record a Codex verdict, or delete this file once you have manually verified the change."}' \
   > "${DEBT_FILE}" 2>/dev/null || true

exit 0
