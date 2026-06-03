#!/usr/bin/env bash
# runner/escalate.sh <cycle_id> <project_dir>
#
# Emits the user-facing escalation message as an additionalContext
# JSON payload on stdout. Called by inject-findings.sh when state.json
# shows status=escalated. inject-findings.sh pipes this output through
# to Claude as a system reminder for the user's next turn.
#
# v2.1 PR 6 (spec §11) — origin-aware: in interactive sessions, present
# the A/B/V menu; in CI / dontAsk / bypassPermissions environments there
# is no human to pick, so emit a fail-closed message instead.
#
# Origin detection (highest priority first):
#   1. TDD_REVIEW_ORIGIN=interactive|ci|unattended (explicit override)
#   2. CI / GITHUB_ACTIONS / GITLAB_CI in env → unattended
#   3. Default → interactive
#
# DO NOT use TTY tests like `[ -t 0 ]` here — escalate.sh is called
# from inject-findings.sh which always has stdin as a pipe, so the
# TTY test would always say "not interactive" even when a human is at
# the keyboard. The env-var path is the verified-correct mechanism.

set -uo pipefail

CYCLE_ID="$1"
PROJECT_DIR="$2"
CYCLE_DIR="${PROJECT_DIR}/.tdd/reviews/${CYCLE_ID}"
CONFIG="${PROJECT_DIR}/tdd-pack.toml"

MAX_ROUNDS=$(awk -F' = ' '/^max_rounds =/ {print $2; exit}' "${CONFIG}" | tr -d ' ')
MAX_ROUNDS="${MAX_ROUNDS:-4}"

# Origin detection. Returns "interactive" or "unattended".
detect_origin() {
  case "${TDD_REVIEW_ORIGIN:-}" in
    interactive)         echo interactive; return ;;
    ci|unattended)       echo unattended;  return ;;
  esac
  if [[ -n "${CI:-}" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ -n "${GITLAB_CI:-}" ]]; then
    echo unattended; return
  fi
  echo interactive
}
ORIGIN=$(detect_origin)

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

# Build the user-facing message — origin-dependent.
if [[ "${ORIGIN}" == "unattended" ]]; then
  MESSAGE="[REVIEW ESCALATION — cycle ${CYCLE_ID}] (unattended environment, fail-closed)

Claude and Codex did not converge after ${MAX_ROUNDS} rounds.
The disagreement is about:

  ${SUMMARY}

Claude's final view:

${CLAUDE_FINAL}

Codex's final view:

${CODEX_FINAL}

UNATTENDED ENVIRONMENT DETECTED — cannot prompt for A/B/V because no
human is present (one of CI=true / GITHUB_ACTIONS / GITLAB_CI /
TDD_REVIEW_ORIGIN=ci is set). The cycle remains in escalated state.

To resolve:
  - Re-run in an interactive shell to surface the A/B/V menu.
  - Or run one of these slash commands manually to break the deadlock:
      /accept-claude     — ship Claude's version as-is
      /accept-codex      — apply Codex's recommendations
      /abandon-review    — neutral exit, drop the cycle

The runner blocks NEW review cycles while this one is escalated, so
no further reviews will fire until you resolve it. Failing closed in
CI is intentional — never auto-resolve a Claude/Codex disagreement
without a human in the loop."
else
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
fi

# Cap at 49500 chars (matches inject-findings.sh).
MESSAGE="${MESSAGE:0:49500}"

jq -nc --arg event "PostToolUse" --arg ctx "${MESSAGE}" \
  '{hookSpecificOutput: {hookEventName: $event, additionalContext: $ctx}}'

exit 0
