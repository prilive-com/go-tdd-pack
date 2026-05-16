#!/usr/bin/env bash
# hooks/stop-fingerprint.sh
#
# Stop hook. Two jobs:
#
# 1. If we're in an active request_changes cycle, capture Claude's last
#    assistant message into claude-response-${next_round}.txt so the
#    runner can use it on the next round invocation.
#
# 2. Fingerprint check: if the working tree changed since the last
#    review (operator made out-of-band edits, or PostToolUse didn't
#    fire for some reason), fire the runner. Belt-and-suspenders.
#
# Either way: exit 0. We never block Stop. Quiet success.

set -uo pipefail

# Honor emergency disable.
if [[ "${PRILIVE_REVIEW_DISABLE:-0}" == "1" ]]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
STATE="${PROJECT_DIR}/.tdd/reviews/state.json"
TDD_DIR="${PROJECT_DIR}/.tdd"
RUNNER="${PROJECT_DIR}/runner/review-runner.sh"

# Read transcript_path from stdin (Claude Code passes a JSON payload).
HOOK_INPUT=""
if [[ ! -t 0 ]]; then
  HOOK_INPUT=$(cat)
fi

TRANSCRIPT_PATH=""
if [[ -n "${HOOK_INPUT}" ]] && command -v jq >/dev/null 2>&1; then
  TRANSCRIPT_PATH=$(printf '%s' "${HOOK_INPUT}" | jq -r '.transcript_path // empty' 2>/dev/null)
fi

# ---- job 1: capture Claude's response if cycle is request_changes ----

if [[ -f "${STATE}" ]] && command -v jq >/dev/null 2>&1; then
  STATUS=$(jq -r '.status // empty' "${STATE}" 2>/dev/null)
  CYCLE_ID=$(jq -r '.cycle_id // empty' "${STATE}" 2>/dev/null)
  ROUND=$(jq -r '.round // 1' "${STATE}" 2>/dev/null)

  if [[ "${STATUS}" == "request_changes" ]] && [[ -n "${CYCLE_ID}" ]]; then
    NEXT_ROUND=$((ROUND + 1))
    CYCLE_DIR="${PROJECT_DIR}/.tdd/reviews/${CYCLE_ID}"
    OUT_FILE="${CYCLE_DIR}/claude-response-${NEXT_ROUND}.txt"

    if [[ -n "${TRANSCRIPT_PATH}" ]] && [[ -f "${TRANSCRIPT_PATH}" ]]; then
      # Transcript is JSONL; each line is a message. Extract the last
      # assistant message's content (which may be a string OR an array
      # of content blocks — handle both shapes).
      LAST_MSG=$(
        jq -rs '
          [.[] | select(.type? == "assistant")] | last
          | if .message.content | type == "array" then
              .message.content | map(select(.type? == "text") | .text) | join("\n")
            else
              .message.content // ""
            end
        ' "${TRANSCRIPT_PATH}" 2>/dev/null
      )

      if [[ -n "${LAST_MSG}" ]] && [[ "${LAST_MSG}" != "null" ]]; then
        mkdir -p "${CYCLE_DIR}"
        printf '%s\n' "${LAST_MSG}" > "${OUT_FILE}"
      fi
    fi

    # Fire the runner to attempt the continuation round.
    # post-edit-review.sh-style detached invocation.
    if [[ -x "${RUNNER}" ]]; then
      nohup "${RUNNER}" "${PROJECT_DIR}" </dev/null >/dev/null 2>&1 &
      disown
    fi
  fi
fi

# ---- job 2: fingerprint check ----

# If working tree changed since last fingerprint, fire runner.
FINGERPRINT_FILE="${TDD_DIR}/.last-fingerprint"
CURRENT_FP=""
if command -v git >/dev/null 2>&1; then
  CURRENT_FP=$(cd "${PROJECT_DIR}" && git status --porcelain 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}')
fi

if [[ -n "${CURRENT_FP}" ]]; then
  PREV_FP=""
  [[ -f "${FINGERPRINT_FILE}" ]] && PREV_FP=$(cat "${FINGERPRINT_FILE}" 2>/dev/null)
  if [[ "${CURRENT_FP}" != "${PREV_FP}" ]]; then
    mkdir -p "${TDD_DIR}"
    echo "${CURRENT_FP}" > "${FINGERPRINT_FILE}"
    # Only fire if not already fired above (avoid double-firing).
    if [[ "${STATUS:-}" != "request_changes" ]] && [[ -x "${RUNNER}" ]]; then
      nohup "${RUNNER}" "${PROJECT_DIR}" </dev/null >/dev/null 2>&1 &
      disown
    fi
  fi
fi

exit 0
