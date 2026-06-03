#!/usr/bin/env bash
# hooks/pre-review.sh
#
# v2.1 — PreToolUse gate for file-write tools.
#
# Scope: this hook reviews code changes (Write/Edit/MultiEdit/NotebookEdit)
# only. Bash command review was removed in the v2.1 cleanup — runtime
# command safety is a separate concern (devopspoint's responsibility),
# not a code-quality concern, and Codex review on every `pwd` was both
# wasteful and an architectural mismatch with the starter pack's mission.
#
# Protocol:
#
#   1. Read PreToolUse JSON on stdin (tool_name, tool_input, session_id).
#   2. Only act on Write | Edit | MultiEdit | NotebookEdit.
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
# Fail-closed contract — when the gate is ON:
#   The ONLY intentional pass-throughs are:
#     1. PRILIVE_REVIEW_DISABLE=1 (global kill switch)
#     2. TOOL_NAME is not Write|Edit|MultiEdit|NotebookEdit
#        (the hook is intentionally scoped — read-only tools, Bash, and
#         MCP tools are NOT gated; the gate covers file changes only)
#   Every other "something is wrong" path emits a deny with a specific
#   reason so the adopter sees exactly what to fix. Specifically:
#     - jq missing                  → deny ("install jq, or unset the flag")
#     - empty stdin                 → deny ("PreToolUse received no input")
#     - malformed payload           → deny ("could not extract tool payload")
#     - hash failure                → deny ("content hashing failed")
#     - mkdir .tdd/queue/ fails     → deny ("cannot create queue dir")
#     - submission write fails      → deny ("failed to write submission")
#     - deadline reached, no verdict → deny ("review pending — retry")
#     - verdict with unknown decision → deny ("unknown decision")
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
# Activation precedence (highest first):
#   1. PRILIVE_REVIEW_DISABLE=1        → gate OFF (global kill switch)
#   2. PRILIVE_PRE_REVIEW_EXPERIMENTAL=1 → gate ON (env override; power-user
#                                          temporary toggle, useful in one
#                                          shell without committing config)
#   3. tdd-pack.toml [pre_review] enabled = true → persistent project default
#   4. Otherwise                       → gate OFF (pass-through, no-op)
#
# Env knobs:
#   PRILIVE_REVIEW_DISABLE          — global kill switch
#   PRILIVE_PRE_REVIEW_EXPERIMENTAL — env override (1 = force gate on)
#   PRILIVE_PRE_REVIEW_DEADLINE_S   — poll deadline in seconds (default 90)
#   PRILIVE_PRE_REVIEW_POLL_S       — poll interval in seconds (default 0.25)

set -uo pipefail

# --- pass-through gates ---------------------------------------------------

if [[ "${PRILIVE_REVIEW_DISABLE:-0}" == "1" ]]; then
  exit 0
fi

# Resolve PROJECT_DIR early — needed for both the activation check (reads
# tdd-pack.toml) and the queue dir later on.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Activation check: env override > config > default off.
GATE_ACTIVE=0
if [[ "${PRILIVE_PRE_REVIEW_EXPERIMENTAL:-0}" == "1" ]]; then
  GATE_ACTIVE=1
elif [[ -f "${PROJECT_DIR}/runner/lib/config.sh" ]]; then
  # shellcheck source=../runner/lib/config.sh
  . "${PROJECT_DIR}/runner/lib/config.sh"
  CONFIG_ENABLED=$(cfg_get "${PROJECT_DIR}/tdd-pack.toml" "pre_review.enabled" "false")
  if [[ "${CONFIG_ENABLED}" == "true" ]]; then
    GATE_ACTIVE=1
  fi
fi

if [[ "${GATE_ACTIVE}" != "1" ]]; then
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  # Fail-closed (sub-piece #4): with experimental on, the adopter
  # explicitly opted into gating. Silently passing through would defeat
  # the point of the gate. Emit deny via plain printf (jq is the thing
  # missing) so the adopter sees exactly what to fix.
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"pre-review: jq is not installed. Install jq to use pre-write gating (apt: jq, brew: jq), or set pre_review.enabled=false in tdd-pack.toml (and unset PRILIVE_PRE_REVIEW_EXPERIMENTAL) to disable the gate."}}'
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
  # Fail-closed (sub-piece #4): PreToolUse always passes a JSON payload
  # on stdin. Empty stdin means something is wrong upstream — denying is
  # the safe move so the adopter sees the failure instead of silently
  # waving actions through.
  jq -nc '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "pre-review: PreToolUse hook received no input on stdin. Action blocked. This is unexpected — check Claude Code logs."
    }
  }'
  exit 0
fi

TOOL_NAME=$(printf '%s' "${INPUT}" | jq -r '.tool_name // empty' 2>/dev/null)
SESSION_ID=$(printf '%s' "${INPUT}" | jq -r '.session_id // empty' 2>/dev/null)

case "${TOOL_NAME}" in
  Write|Edit|MultiEdit|NotebookEdit)
    KIND="file_change"
    ;;
  *)
    # Any other tool (read-only Read/Grep/Glob, Bash, MCP tools, etc.)
    # is not gated by this hook. Pass-through. The gate covers file
    # changes only — runtime command safety is out of scope.
    exit 0
    ;;
esac

# PROJECT_DIR already resolved at top of file (activation check needs it).
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
# The `kind` is always file_change since v2.1 retired the Bash matcher.
# The shape stays per-tool to give the reviewer the exact change semantics:
#   Write        → write_content (full file replacement)
#   Edit         → edit_old_string + edit_new_string
#   MultiEdit    → multi_edits[] (array of old/new pairs)
#   NotebookEdit → notebook_source + notebook_cell_id

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
    notebook_cell_id: (.tool_input.cell_id     // null)
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

  # Fail-closed (sub-piece #4): if write/mv failed (read-only mount, disk
  # full, quota), there's no submission for the worker to pick up — the
  # hook would time out 90s later with the generic "review pending"
  # deny. Catch it now so the adopter sees a specific cause.
  if [[ ! -f "${SUBMISSION}" ]]; then
    jq -nc --arg hash "${HASH}" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: ("pre-review: failed to write submission file for hash " + $hash + " into .tdd/queue/. Likely cause: filesystem error (read-only mount, disk full, quota). Action blocked.")
      }
    }'
    exit 0
  fi
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
