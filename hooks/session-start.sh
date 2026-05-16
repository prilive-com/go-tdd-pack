#!/usr/bin/env bash
# hooks/session-start.sh
#
# SessionStart hook. If there's an unfinished review cycle on disk,
# tell Claude (and indirectly the user) about it so the operator can
# resume or abandon. If no cycle is active, exit silently.
#
# Known limitation: anthropics/claude-code#10373 — SessionStart
# additionalContext doesn't always inject on brand-new conversations
# (works on /clear, /compact, URL resume). Phase 3 will add /continue
# and /resume slash commands as the explicit fallback.

set -uo pipefail

# Honor emergency disable.
if [[ "${PRILIVE_REVIEW_DISABLE:-0}" == "1" ]]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
STATE="${PROJECT_DIR}/.tdd/reviews/state.json"

# No state = nothing to inject.
if [[ ! -f "${STATE}" ]]; then
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

STATUS=$(jq -r '.status // empty' "${STATE}" 2>/dev/null)
CYCLE_ID=$(jq -r '.cycle_id // empty' "${STATE}" 2>/dev/null)
ROUND=$(jq -r '.round // 1' "${STATE}" 2>/dev/null)

if [[ -z "${STATUS}" ]] || [[ -z "${CYCLE_ID}" ]]; then
  exit 0
fi

case "${STATUS}" in
  reviewing|request_changes|escalated)
    CONTEXT="[Prilive TDD Pack] An unfinished review cycle is on disk:
  cycle:  ${CYCLE_ID}
  round:  ${ROUND}
  status: ${STATUS}

The runner may be in flight (status=reviewing) or paused waiting for
your response (status=request_changes) or stuck after max_rounds
(status=escalated).

If you want to see findings: ask Claude 'show me the latest review' (or
run /show-review when Phase 3 ships). If you want to drop the cycle and
move on: ask Claude 'abandon the current review cycle' (or /abandon)."

    jq -nc --arg event "SessionStart" --arg ctx "${CONTEXT}" \
      '{hookSpecificOutput: {hookEventName: $event, additionalContext: $ctx}}'
    ;;
  *)
    # converged | failed | abandoned — no notification needed.
    exit 0
    ;;
esac

exit 0
