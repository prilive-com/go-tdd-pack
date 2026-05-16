#!/usr/bin/env bash
# hooks/post-edit-review.sh
#
# v2.0 async PostToolUse launcher. Returns immediately; the runner continues
# detached. Single-purpose: fire-and-forget the background review-runner.
#
# Must return in <50ms. Does NOT read stdin (Claude Code passes a JSON payload
# but we don't need it — Bash leaves the fd open without blocking).
# Does NOT emit JSON output (so Claude Code treats it as no-op).

if [[ "${PRILIVE_REVIEW_DISABLE:-0}" == "1" ]]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
RUNNER="${PROJECT_DIR}/runner/review-runner.sh"

# If runner missing (broken install), be silent.
if [[ ! -x "${RUNNER}" ]]; then
  exit 0
fi

# Fire-and-forget. nohup + & + disown + redirected fds = truly detached.
# macOS bash 3.2 supports this idiom.
nohup "${RUNNER}" "${PROJECT_DIR}" </dev/null >/dev/null 2>&1 &
disown

exit 0
