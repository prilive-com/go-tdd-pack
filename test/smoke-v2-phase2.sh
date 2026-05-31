#!/usr/bin/env bash
# test/smoke-v2-phase2.sh
#
# Unit-style smoke for the v2.0 Phase 2 components. Does NOT call Codex.
# Each new piece (extract-verdict, escalate, session-start, stop-fingerprint,
# inject-findings/escalated) is exercised with crafted fixtures.
#
# End-to-end multi-round needs real Codex AND a way to force a
# request_changes verdict from round 1 — neither is deterministic. We
# rely on the v1 MVP smoke (test/smoke-v2-mvp.sh) for the real-Codex
# path, and on this script for the orchestration logic that runs after.
#
# Usage:
#   bash test/smoke-v2-phase2.sh
#
# Side effects:
#   - Creates and removes a sandbox at ${TMPDIR:-/tmp}/tdd-phase2-smoke.*
#   - Does NOT touch your project's .tdd/reviews/ directory.

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PROJECT_DIR}" || exit 1

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }

PASS_COUNT=0
expect_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    pass "${label}: ${actual}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    fail "${label}: expected '${expected}', got '${actual}'"
  fi
}

# ---- 1. extract-verdict.sh ----

info "[1] extract-verdict.sh"
EV="${PROJECT_DIR}/runner/extract-verdict.sh"
[[ -x "${EV}" ]] || fail "extract-verdict.sh not executable"

TMPDIR_VERDICT=$(mktemp -d)
trap 'rm -rf "${TMPDIR_VERDICT}"' EXIT

# 1a. plain approve
cat > "${TMPDIR_VERDICT}/approve.txt" <<'EOF'
The diff is fine.

VERDICT: APPROVE
EOF
expect_eq "approve plain" "approve" "$(${EV} ${TMPDIR_VERDICT}/approve.txt)"

# 1b. markdown-wrapped approve
cat > "${TMPDIR_VERDICT}/approve-md.txt" <<'EOF'
Lots of analysis here.

**VERDICT:** approve
EOF
expect_eq "approve markdown" "approve" "$(${EV} ${TMPDIR_VERDICT}/approve-md.txt)"

# 1c. request_changes
cat > "${TMPDIR_VERDICT}/rc.txt" <<'EOF'
There's a bug.

VERDICT: REQUEST_CHANGES
EOF
expect_eq "request_changes plain" "request_changes" "$(${EV} ${TMPDIR_VERDICT}/rc.txt)"

# 1d. REQUEST CHANGES (with space, no underscore)
cat > "${TMPDIR_VERDICT}/rc2.txt" <<'EOF'
VERDICT: request changes
EOF
expect_eq "request changes (space form)" "request_changes" "$(${EV} ${TMPDIR_VERDICT}/rc2.txt)"

# 1e. unclear (no verdict line)
cat > "${TMPDIR_VERDICT}/unclear.txt" <<'EOF'
Long output without verdict sentinel.
EOF
expect_eq "unclear (missing)" "unclear" "$(${EV} ${TMPDIR_VERDICT}/unclear.txt)"

# 1f. unclear (ambiguous verdict)
cat > "${TMPDIR_VERDICT}/amb.txt" <<'EOF'
VERDICT: maybe later
EOF
expect_eq "unclear (ambiguous)" "unclear" "$(${EV} ${TMPDIR_VERDICT}/amb.txt)"

# 1g. missing file
expect_eq "missing file" "unclear" "$(${EV} ${TMPDIR_VERDICT}/nonexistent.txt)"

# 1h. takes the LAST verdict if multiple
cat > "${TMPDIR_VERDICT}/multi.txt" <<'EOF'
VERDICT: REQUEST_CHANGES (previous round)

Now after the fix:

VERDICT: APPROVE
EOF
expect_eq "last-wins" "approve" "$(${EV} ${TMPDIR_VERDICT}/multi.txt)"

# ---- 2. session-start.sh ----

info "[2] session-start.sh"
SS="${PROJECT_DIR}/hooks/session-start.sh"
[[ -x "${SS}" ]] || fail "session-start.sh not executable"

SANDBOX=$(mktemp -d)
trap 'rm -rf "${TMPDIR_VERDICT}" "${SANDBOX}"' EXIT
mkdir -p "${SANDBOX}/.tdd/reviews"

# 2a. no state file → silent (no output)
OUT=$(CLAUDE_PROJECT_DIR="${SANDBOX}" "${SS}")
expect_eq "no state → silent" "" "${OUT}"

# 2b. state=reviewing → emits SessionStart context
echo '{"cycle_id":"cycle-test-1","status":"reviewing","round":1}' \
  > "${SANDBOX}/.tdd/reviews/state.json"
OUT=$(CLAUDE_PROJECT_DIR="${SANDBOX}" "${SS}")
HAS_EVENT=$(echo "${OUT}" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)
expect_eq "reviewing → SessionStart event" "SessionStart" "${HAS_EVENT}"

CTX=$(echo "${OUT}" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
if echo "${CTX}" | grep -q "cycle-test-1"; then
  pass "reviewing context mentions cycle id"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "reviewing context missing cycle id"
fi

# 2c. status=converged → silent (no notification needed)
echo '{"cycle_id":"cycle-test-2","status":"converged","round":2}' \
  > "${SANDBOX}/.tdd/reviews/state.json"
OUT=$(CLAUDE_PROJECT_DIR="${SANDBOX}" "${SS}")
expect_eq "converged → silent" "" "${OUT}"

# 2d. status=escalated → emits context
echo '{"cycle_id":"cycle-test-3","status":"escalated","round":4}' \
  > "${SANDBOX}/.tdd/reviews/state.json"
OUT=$(CLAUDE_PROJECT_DIR="${SANDBOX}" "${SS}")
HAS_EVENT=$(echo "${OUT}" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)
expect_eq "escalated → SessionStart event" "SessionStart" "${HAS_EVENT}"

# 2e. emergency disable
OUT=$(PRILIVE_REVIEW_DISABLE=1 CLAUDE_PROJECT_DIR="${SANDBOX}" "${SS}")
expect_eq "PRILIVE_REVIEW_DISABLE=1 → silent" "" "${OUT}"

# ---- 3. escalate.sh ----

info "[3] escalate.sh"
ES="${PROJECT_DIR}/runner/escalate.sh"
[[ -x "${ES}" ]] || fail "escalate.sh not executable"

# Build a fake cycle dir
CYCLE_ID="cycle-test-esc"
CYCLE_DIR="${SANDBOX}/.tdd/reviews/${CYCLE_ID}"
mkdir -p "${CYCLE_DIR}"

cat > "${CYCLE_DIR}/round-1.json" <<'EOF'
{
  "verdict": "request_changes",
  "summary_one_sentence": "Disagreement over whether the timeout should be configurable.",
  "summary_one_paragraph": "Test paragraph.",
  "findings": [],
  "files_read": ["x.go"],
  "questions_for_human": []
}
EOF

echo "Codex's final position: timeout MUST be configurable." \
  > "${CYCLE_DIR}/round-4.txt"
echo "Claude's final position: 30s default is fine; YAGNI." \
  > "${CYCLE_DIR}/claude-response-4.txt"

# Need a tdd-pack.toml with max_rounds for escalate to read.
cat > "${SANDBOX}/tdd-pack.toml" <<'EOF'
max_rounds = 4
EOF

OUT=$(${ES} "${CYCLE_ID}" "${SANDBOX}")
HAS_EVENT=$(echo "${OUT}" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)
expect_eq "escalate emits PostToolUse" "PostToolUse" "${HAS_EVENT}"

CTX=$(echo "${OUT}" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
if echo "${CTX}" | grep -q "REVIEW ESCALATION"; then
  pass "escalation context has REVIEW ESCALATION header"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "escalation context missing REVIEW ESCALATION header"
fi
if echo "${CTX}" | grep -q "configurable"; then
  pass "escalation context contains Codex's view"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "escalation context missing Codex's view"
fi
if echo "${CTX}" | grep -q "YAGNI"; then
  pass "escalation context contains Claude's view"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "escalation context missing Claude's view"
fi
if echo "${CTX}" | grep -q '\[A\]' \
   && echo "${CTX}" | grep -q '\[B\]' \
   && echo "${CTX}" | grep -q '\[V\]'; then
  pass "escalation context offers A/B/V choices"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "escalation context missing A/B/V choices"
fi

# ---- 4. inject-findings.sh delegates to escalate.sh on escalated state ----

info "[4] inject-findings.sh → escalate on escalated state"
IF="${PROJECT_DIR}/hooks/inject-findings.sh"
[[ -x "${IF}" ]] || fail "inject-findings.sh not executable"

# Sandbox must symlink to real runner/ so escalate.sh resolves.
mkdir -p "${SANDBOX}/runner"
ln -sf "${PROJECT_DIR}/runner/escalate.sh" "${SANDBOX}/runner/escalate.sh"

# Point state.json at the cycle we already built
cat > "${SANDBOX}/.tdd/reviews/state.json" <<EOF
{"cycle_id":"${CYCLE_ID}","status":"escalated","round":4}
EOF

OUT=$(CLAUDE_PROJECT_DIR="${SANDBOX}" "${IF}")
HAS_EVENT=$(echo "${OUT}" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)
expect_eq "inject-findings escalated → PostToolUse" "PostToolUse" "${HAS_EVENT}"

CTX=$(echo "${OUT}" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
if echo "${CTX}" | grep -q "REVIEW ESCALATION"; then
  pass "inject-findings delegates to escalate.sh"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "inject-findings did not delegate to escalate.sh — output: ${OUT:0:200}"
fi

# ---- 5. stop-fingerprint.sh ----

info "[5] stop-fingerprint.sh"
SF="${PROJECT_DIR}/hooks/stop-fingerprint.sh"
[[ -x "${SF}" ]] || fail "stop-fingerprint.sh not executable"

# 5a. emergency disable → silent
OUT=$(PRILIVE_REVIEW_DISABLE=1 CLAUDE_PROJECT_DIR="${SANDBOX}" \
        bash "${SF}" <<<'{}')
expect_eq "stop disable → silent" "" "${OUT}"

# 5b. with request_changes state + a transcript, captures last assistant message.
# Build a minimal JSONL transcript: one user message, one assistant message.
TRANSCRIPT="${SANDBOX}/transcript.jsonl"
cat > "${TRANSCRIPT}" <<'EOF'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I am Claude's response, please capture me."}]}}
EOF

# Set state to request_changes round 1 → stop hook should capture into claude-response-2.txt
CYCLE_ID2="cycle-stop-test"
mkdir -p "${SANDBOX}/.tdd/reviews/${CYCLE_ID2}"
cat > "${SANDBOX}/.tdd/reviews/state.json" <<EOF
{"cycle_id":"${CYCLE_ID2}","status":"request_changes","round":1}
EOF

# Need a runner symlink for stop-fingerprint to find (won't actually fire — but
# the script tries to nohup it; harmless background no-op).
ln -sf "${PROJECT_DIR}/runner/review-runner.sh" "${SANDBOX}/runner/review-runner.sh" 2>/dev/null
ln -sf "${PROJECT_DIR}/runner/coalesce.sh" "${SANDBOX}/runner/coalesce.sh" 2>/dev/null
ln -sf "${PROJECT_DIR}/runner/codex-round1.sh" "${SANDBOX}/runner/codex-round1.sh" 2>/dev/null
ln -sf "${PROJECT_DIR}/runner/codex-round-n.sh" "${SANDBOX}/runner/codex-round-n.sh" 2>/dev/null
ln -sf "${PROJECT_DIR}/runner/extract-verdict.sh" "${SANDBOX}/runner/extract-verdict.sh" 2>/dev/null

# Fire stop hook with a JSON payload that includes transcript_path.
# Make sandbox a git repo first so fingerprint check doesn't error.
( cd "${SANDBOX}" && git init -q && git config user.email t@t && git config user.name t && \
  git add -A 2>/dev/null && git commit -q -m init --allow-empty ) >/dev/null 2>&1

PAYLOAD=$(jq -nc --arg t "${TRANSCRIPT}" '{transcript_path:$t}')
echo "${PAYLOAD}" | CLAUDE_PROJECT_DIR="${SANDBOX}" bash "${SF}" >/dev/null 2>&1

# Give the backgrounded runner a moment to settle (it'll exit fast — no diff).
sleep 1

CAPTURED="${SANDBOX}/.tdd/reviews/${CYCLE_ID2}/claude-response-2.txt"
if [[ -f "${CAPTURED}" ]]; then
  if grep -q "please capture me" "${CAPTURED}"; then
    pass "stop hook captured Claude's last assistant message"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    fail "claude-response-2.txt exists but content wrong: $(cat ${CAPTURED})"
  fi
else
  fail "stop hook did not write claude-response-2.txt"
fi

# ---- 6. settings.json registers Stop + SessionStart ----

info "[6] settings.json registers Phase 2 hooks"
SETTINGS="${PROJECT_DIR}/.claude/settings.json"
STOP_COUNT=$(jq -r '.hooks.Stop | length' "${SETTINGS}")
SS_COUNT=$(jq -r '.hooks.SessionStart | length' "${SETTINGS}")
expect_eq "Stop registration count" "1" "${STOP_COUNT}"
expect_eq "SessionStart registration count" "1" "${SS_COUNT}"

# ---- final summary ----

echo ""
echo "================================================================"
echo "  v2.0 PHASE 2 SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"

exit 0
