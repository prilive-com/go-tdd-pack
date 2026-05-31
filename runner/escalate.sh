#!/usr/bin/env bash
# runner/escalate.sh <cycle_id> <project_dir>
#
# Emits the user-facing escalation message as an additionalContext
# JSON payload on stdout. Called by inject-findings.sh when state.json
# shows status=escalated. inject-findings.sh pipes this output through
# to Claude as a system reminder for the user's next turn.
#
# The A/B/V choice gives the user three options:
#   A — ship Claude's version (operator says "go with Claude")
#   B — apply Codex's recommendations (operator asks Claude to redo)
#   V — view full transcript (/show-review slash command, phase 3)

set -uo pipefail

CYCLE_ID="$1"
PROJECT_DIR="$2"
CYCLE_DIR="${PROJECT_DIR}/.tdd/reviews/${CYCLE_ID}"
CONFIG="${PROJECT_DIR}/tdd-pack.toml"

MAX_ROUNDS=$(awk -F' = ' '/^max_rounds =/ {print $2; exit}' "${CONFIG}" | tr -d ' ')
MAX_ROUNDS="${MAX_ROUNDS:-4}"

# Pull headline from round 1.
SUMMARY="(no summary available)"
if [[ -f "${CYCLE_DIR}/round-1.json" ]]; then
  S=$(jq -r '.summary_one_sentence // empty' "${CYCLE_DIR}/round-1.json" 2>/dev/null)
  [[ -n "${S}" ]] && SUMMARY="${S}"
fi

# Codex's final view: round N text (last round).
CODEX_FINAL="(round ${MAX_ROUNDS} output not captured)"
if [[ -f "${CYCLE_DIR}/round-${MAX_ROUNDS}.txt" ]]; then
  CODEX_FINAL=$(head -30 "${CYCLE_DIR}/round-${MAX_ROUNDS}.txt")
fi

# Claude's final view: claude-response-N.txt (last round's response).
CLAUDE_FINAL="(Claude's last response not captured)"
if [[ -f "${CYCLE_DIR}/claude-response-${MAX_ROUNDS}.txt" ]]; then
  CLAUDE_FINAL=$(head -30 "${CYCLE_DIR}/claude-response-${MAX_ROUNDS}.txt")
fi

# Build the user-facing message.
MESSAGE="[REVIEW ESCALATION — cycle ${CYCLE_ID}]

Claude and Codex did not converge after ${MAX_ROUNDS} rounds.
The disagreement is about:

  ${SUMMARY}

Claude's final view:

${CLAUDE_FINAL}

Codex's final view:

${CODEX_FINAL}

Choose how to proceed:
  [A] /accept-claude     — ship Claude's version as-is
  [B] /accept-codex      — apply Codex's recommendations
  [V] /show-review       — see full transcripts before deciding
      /abandon-review    — neutral exit: drop the cycle without picking a side

Your choice unblocks the cycle. Until you choose, this cycle stays
in escalated state. Future edits will NOT trigger new reviews until
this one is resolved — the runner blocks new cycles when state is
escalated, to protect your pending decision from being silently
overwritten."

# Cap at 49500 chars (matches inject-findings.sh).
MESSAGE="${MESSAGE:0:49500}"

jq -nc --arg event "PostToolUse" --arg ctx "${MESSAGE}" \
  '{hookSpecificOutput: {hookEventName: $event, additionalContext: $ctx}}'

exit 0
