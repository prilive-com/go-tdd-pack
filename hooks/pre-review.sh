#!/usr/bin/env bash
# hooks/pre-review.sh
#
# v2.2.0 sub-piece #1 — PreToolUse gate for file-write tools.
#
# Protocol (sub-piece #3 will replace file-IPC with a Unix socket):
#
#   1. Read PreToolUse JSON on stdin (tool_name, tool_input, session_id).
#   2. Only act on Write | Edit | MultiEdit | NotebookEdit.
#      Bash is wired to its own matcher in sub-piece #2 — pass-through here.
#   3. Extract a canonical payload (kind, tool_name, file_path, change body).
#   4. Compute content_hash = sha256(payload).
#   5. If `.tdd/queue/<hash>.verdict.json` exists, use it (cache-by-hash).
#   6. Otherwise write `.tdd/queue/<hash>.submission.json` and poll for the
#      verdict file on a bounded deadline (default 90s, well under the
#      hook's 120s hard timeout).
#   7. On verdict: emit permissionDecision allow | deny | ask and exit 0.
#   8. On deadline: emit deny with "review pending — retry" (FAIL-CLOSED).
#
# EXPERIMENTAL — gated by PRILIVE_PRE_REVIEW_EXPERIMENTAL=1. Default
# behaviour is pass-through (empty JSON, hook is a no-op) so registering
# this hook in settings.json is safe for current adopters today: nothing
# blocks until adopters explicitly opt in AND sub-piece #3 ships the
# runner-side verdict producer.
#
# Verdict file shape (written by the runner — sub-piece #3):
#   {
#     "decision": "allow" | "deny" | "ask",
#     "reason": "<short text shown to Claude>",
#     "findings": [
#       {"severity":"...", "category":"...", "title":"...", "body":"..."}
#     ]
#   }
#
# Env knobs:
#   PRILIVE_REVIEW_DISABLE          — global kill switch (matches PostToolUse path)
#   PRILIVE_PRE_REVIEW_EXPERIMENTAL — must be "1" for the gate to activate
#   PRILIVE_PRE_REVIEW_DEADLINE_S   — poll deadline in seconds (default 90)
#   PRILIVE_PRE_REVIEW_POLL_S       — poll interval in seconds (default 0.25)

set -uo pipefail

# --- pass-through gates ---------------------------------------------------

if [[ "${PRILIVE_REVIEW_DISABLE:-0}" == "1" ]]; then
  exit 0
fi

if [[ "${PRILIVE_PRE_REVIEW_EXPERIMENTAL:-0}" != "1" ]]; then
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  # No jq → cannot parse stdin safely. Pass-through is the safer fallback
  # here: denying every action because of a tooling gap would block all
  # work on a misconfigured machine. The runner-side smoke would catch
  # this in CI before adopters see it.
  exit 0
fi

# --- sha256 wrapper (Linux sha256sum, macOS shasum -a 256) ----------------
# Inlined here to avoid blocking on task #104 (macOS portability shims).

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# --- read stdin -----------------------------------------------------------

INPUT=$(cat 2>/dev/null || true)
if [[ -z "${INPUT}" ]]; then
  exit 0
fi

TOOL_NAME=$(printf '%s' "${INPUT}" | jq -r '.tool_name // empty' 2>/dev/null)
SESSION_ID=$(printf '%s' "${INPUT}" | jq -r '.session_id // empty' 2>/dev/null)

case "${TOOL_NAME}" in
  Write|Edit|MultiEdit|NotebookEdit)
    KIND="file_change"
    ;;
  Bash)
    KIND="bash_command"
    ;;
  *)
    # Any other tool (read-only Read/Grep/Glob, MCP tools, etc.) is
    # not gated by this hook. Pass-through.
    exit 0
    ;;
esac

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QUEUE_DIR="${PROJECT_DIR}/.tdd/queue"

if ! mkdir -p "${QUEUE_DIR}" 2>/dev/null; then
  jq -nc '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "pre-review hook: cannot create .tdd/queue (filesystem error). Action blocked."
    }
  }'
  exit 0
fi

# --- build canonical payload ----------------------------------------------
# Same JSON shape for every tool the hook gates, so the runner has one
# schema to consume. The `kind` field tells the runner what fields are
# load-bearing:
#   kind=file_change  → write_content / edit_*_string / multi_edits / notebook_*
#   kind=bash_command → bash_command / bash_description
#
# Sub-piece #5 teaches the reviewer how to classify bash_command payloads
# as read-only vs state-changing. This hook only delivers the payload; it
# does not judge it.

PAYLOAD=$(printf '%s' "${INPUT}" | jq -c --arg kind "${KIND}" '
  def file_path: .tool_input.file_path // .tool_input.notebook_path // "";
  {
    kind: $kind,
    tool_name: .tool_name,
    file_path: file_path,
    write_content:    (.tool_input.content     // null),
    edit_old_string:  (.tool_input.old_string  // null),
    edit_new_string:  (.tool_input.new_string  // null),
    multi_edits:      (.tool_input.edits       // null),
    notebook_source:  (.tool_input.new_source  // null),
    notebook_cell_id: (.tool_input.cell_id     // null),
    bash_command:     (.tool_input.command     // null),
    bash_description: (.tool_input.description // null)
  }
' 2>/dev/null)

if [[ -z "${PAYLOAD}" ]] || [[ "${PAYLOAD}" == "null" ]]; then
  jq -nc '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "pre-review hook: could not extract tool payload from PreToolUse input. Action blocked."
    }
  }'
  exit 0
fi

# Defensive: a bash_command payload with no command field is malformed input.
# Fail closed rather than submit an empty command for review.
if [[ "${KIND}" == "bash_command" ]]; then
  BASH_CMD=$(printf '%s' "${PAYLOAD}" | jq -r '.bash_command // empty' 2>/dev/null)
  if [[ -z "${BASH_CMD}" ]]; then
    jq -nc '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "pre-review hook: Bash PreToolUse input had no .tool_input.command. Action blocked."
      }
    }'
    exit 0
  fi
fi

HASH=$(printf '%s' "${PAYLOAD}" | sha256_of)
if [[ -z "${HASH}" ]] || [[ ${#HASH} -ne 64 ]]; then
  jq -nc '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "pre-review hook: content hashing failed. Action blocked."
    }
  }'
  exit 0
fi

SUBMISSION="${QUEUE_DIR}/${HASH}.submission.json"
VERDICT="${QUEUE_DIR}/${HASH}.verdict.json"

# --- write submission only if no verdict already cached -------------------

if [[ ! -f "${VERDICT}" ]] && [[ ! -f "${SUBMISSION}" ]]; then
  SUBMITTED_AT=$(date -u +%FT%TZ 2>/dev/null || echo unknown)
  DEADLINE_EPOCH=$(( $(date +%s) + ${PRILIVE_PRE_REVIEW_DEADLINE_S:-90} ))
  jq -n \
    --arg hash      "${HASH}" \
    --arg session   "${SESSION_ID}" \
    --arg submitted "${SUBMITTED_AT}" \
    --argjson deadline "${DEADLINE_EPOCH}" \
    --argjson payload  "${PAYLOAD}" \
    '{
      content_hash: $hash,
      session_id:   $session,
      submitted_at: $submitted,
      deadline_epoch: $deadline,
      payload: $payload
    }' \
    > "${SUBMISSION}.tmp" 2>/dev/null \
    && mv "${SUBMISSION}.tmp" "${SUBMISSION}"
fi

# --- launch the worker (detached, single-flight) --------------------------
# Sub-piece #3: pre-review-worker.sh drains the queue and writes verdict
# files. Single-instance is guarded by flock inside the worker, so
# concurrent launches from parallel hook fires are no-ops. Hook returns
# immediately after the launch; it does not wait for the worker.

WORKER="${PROJECT_DIR}/runner/pre-review-worker.sh"
if [[ -x "${WORKER}" ]] && [[ ! -f "${VERDICT}" ]]; then
  nohup "${WORKER}" "${PROJECT_DIR}" </dev/null \
    >>"${PROJECT_DIR}/.tdd/pre-review-worker.log" 2>&1 &
  disown 2>/dev/null || true
fi

# --- poll for verdict on bounded deadline ---------------------------------

DEADLINE_S="${PRILIVE_PRE_REVIEW_DEADLINE_S:-90}"
POLL_INTERVAL_S="${PRILIVE_PRE_REVIEW_POLL_S:-0.25}"
# attempts = deadline / interval (integer floor)
ATTEMPTS=$(awk -v d="${DEADLINE_S}" -v i="${POLL_INTERVAL_S}" 'BEGIN{printf "%d", d/i}')
if [[ "${ATTEMPTS}" -lt 1 ]]; then
  ATTEMPTS=1
fi

while [[ "${ATTEMPTS}" -gt 0 ]]; do
  if [[ -f "${VERDICT}" ]]; then
    break
  fi
  sleep "${POLL_INTERVAL_S}"
  ATTEMPTS=$(( ATTEMPTS - 1 ))
done

# --- consume verdict ------------------------------------------------------

if [[ ! -f "${VERDICT}" ]]; then
  jq -nc \
    --arg hash "${HASH}" \
    --arg deadline "${DEADLINE_S}" \
    '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: ("pre-review: review pending after " + $deadline + "s — retry. Submission hash " + $hash + ". If this keeps happening, check .tdd/runner.log and `codex login`.")
      }
    }'
  exit 0
fi

DECISION=$(jq -r '.decision // "deny"' "${VERDICT}" 2>/dev/null)
REASON=$(jq -r '.reason // "(no reason provided)"' "${VERDICT}" 2>/dev/null)
FINDINGS_TEXT=$(jq -r '
  if (.findings // []) | length == 0 then ""
  else
    "\n\nFindings:\n" + (
      [.findings[]? |
        "- [\(.severity // "?")/\(.category // "?")] \(.title // "")\n  \(.body // "")"
      ] | join("\n")
    )
  end
' "${VERDICT}" 2>/dev/null)

case "${DECISION}" in
  allow|deny|ask) ;;
  *)
    DECISION="deny"
    REASON="pre-review: verdict file had unknown decision; treating as deny. Hash ${HASH}."
    ;;
esac

jq -nc \
  --arg decision "${DECISION}" \
  --arg reason   "${REASON}${FINDINGS_TEXT}" \
  '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: $decision,
      permissionDecisionReason: $reason
    }
  }'

exit 0
