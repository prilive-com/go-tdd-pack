#!/usr/bin/env bash
# hooks/ops-debt-stop.sh
#
# v2.2 slice 5 — Stop hook. Blocks Claude's turn-end while unresolved
# ops-debt entries exist. Uses the Stop hook `{"decision":"block",
# "reason":"..."}` channel (verified working as of v2.1.165; unaffected
# by bug #55889 which only drops PreToolUse/PostToolUse additionalContext
# on Bash).
#
# Resolution: operator either
#   1. Runs /ops-preflight for each debt entry (writes preflight artifact;
#      ops-debt-track.sh clears the debt on the next Bash); OR
#   2. Manually verifies the change and deletes the debt file:
#      rm .tdd/ops-debt/<hash>.json
#   3. /ops-debt-clear slash command (slice 6 nice-to-have; not in slice 5).
#
# Loop guard: MANDATORY. Without it, blocking forever in a loop is
# possible if Claude can't resolve the debt mid-turn. Honors
# CLAUDE_CODE_STOP_HOOK_BLOCK_CAP (default 8) as the platform-level
# safety net (Claude Code overrides after N consecutive blocks).
#
# Disabled-safe: PRILIVE_REVIEW_DISABLE=1 or [ops_triage] enabled=false
# → exit 0 immediately.

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

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null || true)
[[ -z "${INPUT}" ]] && exit 0

# MANDATORY loop guard — without this the hook will block in an infinite
# loop (Claude Code re-invokes Stop hooks on each "stop, but blocked"
# attempt; without the guard the hook keeps blocking).
ACTIVE=$(printf '%s' "${INPUT}" | jq -r '.stop_hook_active // false' 2>/dev/null)
[[ "${ACTIVE}" == "true" ]] && exit 0

DEBT_DIR="${PROJECT_DIR}/.tdd/ops-debt"
[[ -d "${DEBT_DIR}" ]] || exit 0

shopt -s nullglob
DEBT_FILES=( "${DEBT_DIR}"/*.json )
shopt -u nullglob
(( ${#DEBT_FILES[@]} == 0 )) && exit 0

# Build a human-readable list of open debts.
SUMMARY=""
for f in "${DEBT_FILES[@]}"; do
  CMD=$(jq -r '.command // "(unknown command)"' "$f" 2>/dev/null)
  RISK=$(jq -r '.risk // "?"' "$f" 2>/dev/null)
  CREATED=$(jq -r '.created_at // "?"' "$f" 2>/dev/null)
  SUMMARY="${SUMMARY}  - [${RISK}] ${CMD}  (recorded ${CREATED})
"
done

REASON="Unresolved ops-debt before you finish this turn:
${SUMMARY}
For each:
  - Run /ops-preflight to record a Codex post-hoc verdict (writes
    .tdd/ops-preflight/<hash>.json; ops-debt-track.sh will clear the
    matching debt on the next Bash invocation), OR
  - Verify the change manually (status + health + logs) and delete the
    debt file: rm .tdd/ops-debt/<hash>.json.

Do NOT report 'done' while ops-debt is open."

jq -nc --arg r "${REASON}" '{decision:"block", reason:$r}'
