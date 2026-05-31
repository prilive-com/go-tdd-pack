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

# If runner missing (broken install), record it once so the user can see
# why nothing is happening. Was previously a silent exit which made
# broken installs invisible — adopter pain point.
if [[ ! -x "${RUNNER}" ]]; then
  mkdir -p "${PROJECT_DIR}/.tdd" 2>/dev/null
  echo "[$(date -u +%FT%TZ)] runner missing: ${RUNNER}" \
    >> "${PROJECT_DIR}/.tdd/install-error.log" 2>/dev/null
  exit 0
fi

# Fire-and-forget. nohup + & + disown = truly detached.
# Output goes to .tdd/runner.log instead of /dev/null so adopters can
# diagnose silent failures (e.g., expired Codex auth, no-git workdir,
# transient API errors). The log rotates trivially: each run appends a
# timestamped section; ops can prune via `> .tdd/runner.log` or logrotate.
mkdir -p "${PROJECT_DIR}/.tdd" 2>/dev/null
LOG="${PROJECT_DIR}/.tdd/runner.log"
{
  echo ""
  echo "==================================================================="
  echo "$(date -u +%FT%TZ) runner invocation"
  echo "  PROJECT_DIR=${PROJECT_DIR}"
  echo "==================================================================="
} >> "${LOG}" 2>/dev/null

nohup "${RUNNER}" "${PROJECT_DIR}" </dev/null >> "${LOG}" 2>&1 &
disown

exit 0
