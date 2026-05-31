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
  # Cap at 49500 chars to stay under additionalContext 50KB ceiling
  # (Claude Code platform limit). Earlier 9800 cap was overly conservative
  # and silently dropped the majority of findings when Codex returned a
  # long list. Quality-tuned higher cap preserves the full signal.
  ctx="${ctx:0:49500}"
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
  converged|abandoned|resolved_by_user_claude|resolved_by_user_codex)
    # Cycle is done cleanly. Nothing to inject.
    exit 0
    ;;
  failed)
    # Cycle failed (codex crash, auth expiry, no-git workdir, etc.).
    # Surface ONCE per failed cycle so the adopter knows to look at
    # .tdd/runner.log. Avoid spamming every turn — write a marker file
    # under the cycle dir so subsequent invocations stay silent.
    MARKER="${CYCLE_DIR}/.failure-surfaced"
    if [[ ! -f "${MARKER}" ]]; then
      DETAIL=""
      if [[ -f "${CYCLE_DIR}/.status" ]]; then
        DETAIL=$(head -1 "${CYCLE_DIR}/.status" 2>/dev/null)
      fi
      HINT=""
      case "${DETAIL}" in
        *codex_exec_nonzero*|*codex_resume_nonzero*)
          HINT="Likely cause: Codex CLI error. Common: expired ChatGPT auth (run \`codex login\` to refresh), API quota, or network. Check \`.tdd/runner.log\` for the raw Codex stderr."
          ;;
        *invalid_json*|*missing_fields*)
          HINT="Codex returned unexpected output. Schema validation failed. Check \`.tdd/reviews/${CYCLE_ID}/round-1.json\` and \`.tdd/runner.log\`."
          ;;
        *no_session*|*no_response*|*no_round1*)
          HINT="Internal state inconsistency. Check \`.tdd/reviews/${CYCLE_ID}/\` for missing artifacts."
          ;;
        *)
          HINT="Check \`.tdd/runner.log\` for runner stderr."
          ;;
      esac
      emit_context "[Codex review failed — cycle ${CYCLE_ID}, round ${ROUND}, detail: ${DETAIL:-unknown}]

${HINT}

The runner is fail-open: subsequent edits will start fresh cycles. To
suppress this notice and move on, run /abandon-review."
      touch "${MARKER}" 2>/dev/null
    fi
    exit 0
    ;;
  request_changes)
    # Codex returned findings. Inject for Claude's next turn.
    ;;
  escalated)
    # v2.0 Phase 2: delegate to runner/escalate.sh, which renders the
    # full A/B/V message with Claude's + Codex's final positions.
    ESCALATE="${PROJECT_DIR}/runner/escalate.sh"
    if [[ -x "${ESCALATE}" ]]; then
      "${ESCALATE}" "${CYCLE_ID}" "${PROJECT_DIR}"
    else
      # Fallback if escalate.sh is missing.
      emit_context "[Codex review escalation — cycle ${CYCLE_ID}, round ${ROUND}] Claude and Codex did not converge. Tell me how to proceed."
    fi
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

# Surface ALL findings (blocker + major + minor + nit). Quality-tuned:
# even nits can be useful signal for Claude. Per tdd-pack.toml
# min_surface = "nit". If you want to filter, raise the bar here.
# Confidence is shown as c=N (1-5); 5=verified, 1=guess.
FINDINGS=$(jq -r '
  [.findings[]?]
  | if length == 0 then "(no findings)"
    else (
      map(
        "- [\(.severity)/\(.category) c=\(.confidence // "?")] \(.title)\n  \(.body)"
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
