#!/usr/bin/env bash
# hooks/inject-findings.sh
#
# v2.0 sync hook (PostToolUse + UserPromptSubmit). Reads .tdd/reviews/state.json
# and emits additionalContext as a system reminder if findings are pending.
#
# Two firing points for defense-in-depth against anthropics/claude-code#18427
# (PostToolUse additionalContext may not inject reliably on Edit/Write in some
# Claude Code builds):
#   - PostToolUse: immediate next turn — preferred path
#   - UserPromptSubmit: surfaces findings on the user's next prompt — fallback

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
STATE="${PROJECT_DIR}/.tdd/reviews/state.json"

# Honor disable.
if [[ "${PRILIVE_REVIEW_DISABLE:-0}" == "1" ]]; then
  exit 0
fi

# No state file = no active cycle = nothing to inject.
if [[ ! -f "${STATE}" ]]; then
  exit 0
fi

# Need jq to parse state.
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

STATUS=$(jq -r '.status // empty' "${STATE}" 2>/dev/null)
CYCLE_ID=$(jq -r '.cycle_id // empty' "${STATE}" 2>/dev/null)
ROUND=$(jq -r '.round // 1' "${STATE}" 2>/dev/null)

if [[ -z "${STATUS}" ]] || [[ -z "${CYCLE_ID}" ]]; then
  exit 0
fi

CYCLE_DIR="${PROJECT_DIR}/.tdd/reviews/${CYCLE_ID}"

# --- helper: emit additionalContext JSON ---
emit_context() {
  local ctx="$1"
  local event="${2:-PostToolUse}"
  # Cap at 9800 chars to stay under additionalContext 10K limit.
  ctx="${ctx:0:9800}"
  jq -nc \
    --arg event "${event}" \
    --arg ctx "${ctx}" \
    '{hookSpecificOutput: {hookEventName: $event, additionalContext: $ctx}}'
}

# --- behavior by cycle status ---
case "${STATUS}" in
  reviewing)
    # Cycle is in flight. Nothing to inject yet.
    exit 0
    ;;
  converged|failed|abandoned)
    # Cycle is done. Nothing to inject.
    exit 0
    ;;
  request_changes)
    # Codex returned findings. Inject for Claude's next turn.
    ;;
  escalated)
    # Codex and Claude couldn't converge. Surface escalation to user.
    # MVP: emit a simple message. Phase 2 swaps in runner/escalate.sh.
    emit_context "[Codex review escalation — cycle ${CYCLE_ID}, round ${ROUND}] Claude and Codex did not converge after ${ROUND} rounds. Run /show-review for details and tell me how to proceed."
    exit 0
    ;;
  *)
    exit 0
    ;;
esac

# --- compose findings injection (request_changes branch) ---
ROUND1_JSON="${CYCLE_DIR}/round-1.json"
if [[ ! -f "${ROUND1_JSON}" ]]; then
  # Findings file missing — shouldn't happen but be defensive.
  exit 0
fi

VERDICT_SUMMARY=$(jq -r '.summary_one_sentence // "review requested"' "${ROUND1_JSON}" 2>/dev/null)

# Filter findings: only blocker / major / minor (drop nit per default min_surface).
FINDINGS=$(jq -r '
  [.findings[]?
   | select(.severity == "blocker" or .severity == "major" or .severity == "minor")]
  | if length == 0 then "(no findings above minor severity)"
    else (
      map(
        "- [\(.severity)/\(.category)] \(.title)\n  \(.body)"
        + (if .file != "" then "\n  at \(.file):\(.line // 0)" else "" end)
      ) | join("\n")
    )
    end
' "${ROUND1_JSON}" 2>/dev/null)

CONTEXT="[Codex review — cycle ${CYCLE_ID}, round ${ROUND}, status: changes requested]

Summary: ${VERDICT_SUMMARY}

Findings:
${FINDINGS}

What to do next:
- If you agree with a finding, fix the code silently. The runner will re-review.
- If you disagree, write a one-line rationale in a code comment or in your next response.
- Do NOT ask the user about review issues. Continue working.
- Your next response will be captured and sent to Codex for re-review (Phase 2).
- For MVP, you may continue iterating; the runner will not auto-re-fire until Phase 2 ships."

emit_context "${CONTEXT}" "PostToolUse"
