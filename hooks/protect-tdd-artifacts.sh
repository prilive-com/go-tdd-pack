#!/usr/bin/env bash
# hooks/protect-tdd-artifacts.sh
#
# v2.1 PR 6 — Gate 4 (spec §10): block direct Claude edits to the
# pack's engine-owned evidence chain.
#
# The runner writes these files via plain bash (echo > x, jq > x, mv,
# etc.) and so does NOT trigger Claude Code's PreToolUse hook. Only
# Claude tool invocations (Write/Edit/MultiEdit/NotebookEdit) reach
# this hook, and those are blocked. Net effect: the runner can write,
# Claude cannot.
#
# Bypass: PRILIVE_REVIEW_DISABLE=1 in the shell turns this off (matches
# the rest of the pack's kill switch). Useful for one-off recovery,
# never for daily work.
#
# Protected paths (project-relative):
#   .tdd/findings/**                         FDTDD finding artifacts
#   .tdd/review/ledger.jsonl                 calibration ledger
#   .tdd/reviews/state.json                  cycle state machine
#   .tdd/reviews/debates.jsonl               event log
#   .tdd/reviews/*/round-*.json              Codex round-1 schema output
#   .tdd/reviews/*/round-*.txt               Codex round-N free-form
#   .tdd/reviews/*/.status                   cycle failure status
#   .tdd/reviews/*/codex-session-id          session resume pointer
#   .tdd/reviews/*/claude-response-*.txt     captured Claude turn output
#   .tdd/queue/*.submission.json             pre-review queue (file_change)
#   .tdd/queue/*.verdict.json                pre-review verdicts
#   .tdd/.codex-capabilities.json            CLI capability cache

set -uo pipefail

if [[ "${PRILIVE_REVIEW_DISABLE:-0}" == "1" ]]; then
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  # No jq → cannot parse stdin. Fail-OPEN here: the runner's own JSON
  # writes are already independent of this hook, and a missing jq is
  # already covered by other diagnostics. Don't add a second deny path
  # for tooling gaps.
  exit 0
fi

INPUT=$(cat 2>/dev/null || true)
if [[ -z "${INPUT}" ]]; then
  exit 0
fi

TOOL_NAME=$(printf '%s' "${INPUT}" | jq -r '.tool_name // empty' 2>/dev/null)
case "${TOOL_NAME}" in
  Write|Edit|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(printf '%s' "${INPUT}" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
[[ -z "${FILE_PATH}" ]] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Normalize to PROJECT_DIR-relative if the path is under PROJECT_DIR.
REL_PATH="${FILE_PATH#${PROJECT_DIR}/}"

# Emit a deny with the engine-mediated-write hint.
deny() {
  local rel="$1" hint="$2"
  jq -nc --arg path "${rel}" --arg hint "${hint}" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("Gate 4 (TDD artifact protection): direct Claude edits to engine-owned files are blocked. The runner owns " + $path + ". " + $hint + " To bypass for a session: PRILIVE_REVIEW_DISABLE=1.")
    }
  }'
}

# Prefix-match patterns (anything under these prefixes is protected).
PROTECTED_PREFIXES=(
  ".tdd/findings/"
  ".tdd/queue/"
)

for prefix in "${PROTECTED_PREFIXES[@]}"; do
  if [[ "${REL_PATH}" == "${prefix}"* ]]; then
    deny "${REL_PATH}" "Engine path: use the runner or a slash command (e.g. /accept-claude, /accept-codex, /abandon-review)."
    exit 0
  fi
done

# Exact-file patterns.
case "${REL_PATH}" in
  .tdd/review/ledger.jsonl)
    deny "${REL_PATH}" "Calibration ledger is append-only via the engine."
    exit 0
    ;;
  .tdd/reviews/state.json)
    deny "${REL_PATH}" "Cycle state machine — let the runner update it."
    exit 0
    ;;
  .tdd/reviews/debates.jsonl)
    deny "${REL_PATH}" "Event log is append-only via the engine."
    exit 0
    ;;
  .tdd/.codex-capabilities.json)
    deny "${REL_PATH}" "Codex capability cache; rebuilt from `codex --version` on next runner invocation."
    exit 0
    ;;
  .tdd/active-finding)
    deny "${REL_PATH}" "FDTDD active-finding marker (v2.1 PR 8). Engine path: scripts/tdd/finding-start.sh and scripts/tdd/finding-finish.sh."
    exit 0
    ;;
esac

# Patterned files under .tdd/reviews/<cycle>/.
case "${REL_PATH}" in
  .tdd/reviews/*/round-*.json \
  | .tdd/reviews/*/round-*.txt \
  | .tdd/reviews/*/.status \
  | .tdd/reviews/*/codex-session-id \
  | .tdd/reviews/*/claude-response-*.txt)
    deny "${REL_PATH}" "Codex review artifact — written by the runner only."
    exit 0
    ;;
esac

exit 0
