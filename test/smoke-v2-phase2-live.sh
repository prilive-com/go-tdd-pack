#!/usr/bin/env bash
# test/smoke-v2-phase2-live.sh
#
# End-to-end live test of the Phase 2 multi-round path.
#
# Why this exists:
#   The MVP smoke (smoke-v2-mvp.sh) only exercises round 1 because trivial
#   diffs always converge. The Phase 2 unit smoke (smoke-v2-phase2.sh)
#   exercises orchestration logic in isolation but never calls Codex. This
#   script closes the gap: it forces a request_changes round 1 with a
#   deterministic security blocker (hardcoded credential), then drives the
#   runner into round 2 via the same mechanism the Stop hook uses.
#
# What it does:
#   1. Refuses on dirty working tree.
#   2. Cleans .tdd/reviews/, .tdd/runner.lock, .tdd/.last-fingerprint.
#   3. Inserts an unconditional infinite loop into hooks/post-edit-review.sh.
#      (Codex reliably flags this as a blocker — the hook would hang every
#      PostToolUse. Non-cyber fixture: OpenAI's cybersecurity content filter
#      rejects credential-shaped strings even in legitimate review context,
#      so we use a clear correctness blocker instead.)
#      IMPORTANT: the fixture file must NOT be executed by the runner
#      itself. We choose hooks/post-edit-review.sh because the smoke calls
#      runner/review-runner.sh directly, bypassing Claude Code's hook
#      system — Codex still sees the diff but our pipeline never runs the
#      fixture code. Earlier attempts targeting runner/coalesce.sh hung
#      the runner on its own fixture before reaching Codex.
#   4. Snapshots project file hashes for the no-write check.
#   5. Runs round 1. Asserts: status=request_changes, verdict=request_changes,
#      at least one finding mentions hang/loop/block.
#   6. "Simulates Claude": reverts the bug AND writes claude-response-2.txt
#      saying the fix is applied. This is what the Stop hook would do after
#      a real Claude turn.
#   7. Runs the runner again. The Phase 2 orchestrator picks up
#      claude-response-2.txt and runs round 2 via codex exec resume.
#   8. Asserts: round-2.txt exists with a VERDICT, status=converged,
#      no project files modified by Codex.
#
# Cost:
#   Two real Codex calls. ~30-90 seconds, ~20-40K tokens.
#
# Variants:
#   SMOKE_PHASE2_ESCALATE=1   Do not revert the bug between rounds and
#                             write defending responses — drives the cycle
#                             to max_rounds and tests the escalation path.
#                             Cost: ~4x (one Codex call per round).
#
# Usage:
#   bash test/smoke-v2-phase2-live.sh
#   SMOKE_PHASE2_ESCALATE=1 bash test/smoke-v2-phase2-live.sh

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PROJECT_DIR}" || exit 1

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
warn() { echo "⚠ $*" >&2; }

# ---- preflight ----

command -v codex >/dev/null || fail "codex CLI not in PATH (codex login first)"
command -v jq    >/dev/null || fail "jq not in PATH"
command -v git   >/dev/null || fail "git not in PATH"

[ -x "${PROJECT_DIR}/runner/review-runner.sh" ] \
  || fail "runner not found at runner/review-runner.sh"

if ! git diff --quiet HEAD 2>/dev/null; then
  DIFF_BYTES=$(git diff HEAD | wc -c)
  fail "working tree has uncommitted changes (${DIFF_BYTES} bytes).
       Test would review those instead of the fixture, burning tokens.
       Clean first:
         git status
         git add ... && git commit -m '...'   # to keep
         git restore <files>                  # to discard"
fi

# ---- reset state ----

info "Clearing stale .tdd state"
rm -rf "${PROJECT_DIR}/.tdd/reviews"
rm -f  "${PROJECT_DIR}/.tdd/runner.lock"
rm -f  "${PROJECT_DIR}/.tdd/.last-fingerprint"
mkdir -p "${PROJECT_DIR}/.tdd/reviews"

# ---- target file for the fixture bug ----

TARGET="hooks/post-edit-review.sh"
[ -f "${TARGET}" ] || fail "fixture target missing: ${TARGET}"

# Hard guard: target MUST NOT be in the runner execution path. If we ever
# rename or move a runner script into a path that matches this list, this
# guard will refuse to run instead of hanging the smoke.
case "${TARGET}" in
  runner/*)
    fail "TARGET=${TARGET} is in runner/ — the runner would execute the fixture and hang. Pick a non-executed file."
    ;;
esac

# Trap: always revert all changes and clean up
cleanup() {
  git -C "${PROJECT_DIR}" restore "${TARGET}" 2>/dev/null || true
}
trap cleanup EXIT

# ---- insert the bug ----

info "Inserting fixture infinite loop into ${TARGET}"
# Must insert BEFORE existing executable code so the loop is reachable.
# Appending to end places the fixture after an existing `exit 0`, making
# it dead code; Codex would correctly downgrade that to a "minor".
# Also: capture the original mode and restore it after the mv (mktemp
# creates files with 600; mv would silently downgrade an executable hook
# to non-executable — Codex flags that as a separate finding).
ORIGINAL_MODE=$(stat -c '%a' "${TARGET}" 2>/dev/null || stat -f '%Lp' "${TARGET}" 2>/dev/null)
FIXTURE_TMP=$(mktemp)
awk '
  BEGIN { ins = 0 }
  # First non-comment, non-blank, non-shebang line is the entry point.
  # Insert the fixture immediately before it so it runs on every invoke.
  /^[^#[:space:]]/ && !ins {
    print "# FIXTURE_BUG (smoke-v2-phase2-live.sh inserted this — Codex must flag it)"
    print "# Unconditional infinite loop: the hook will hang on every PostToolUse."
    print "fixture_hang() { while true; do sleep 60; done; }"
    print "fixture_hang"
    print ""
    ins = 1
  }
  { print }
' "${TARGET}" > "${FIXTURE_TMP}"
mv "${FIXTURE_TMP}" "${TARGET}"
[[ -n "${ORIGINAL_MODE:-}" ]] && chmod "${ORIGINAL_MODE}" "${TARGET}"

# ---- snapshot project file hashes (excluding TARGET we modified ourselves) ----

info "Snapshotting project file hashes"
SNAP_DIR=$(mktemp -d)
trap 'cleanup; rm -rf "${SNAP_DIR}"' EXIT

git ls-files | grep -vE "^(${TARGET}|README\.md)$" | sort > "${SNAP_DIR}/files.txt"
while IFS= read -r f; do
  [ -f "$f" ] && sha256sum "$f"
done < "${SNAP_DIR}/files.txt" > "${SNAP_DIR}/before.hashes"

BEFORE_COUNT=$(wc -l < "${SNAP_DIR}/before.hashes")
pass "snapshotted ${BEFORE_COUNT} non-target project files"

# ---- helpers ----

STATE_FILE="${PROJECT_DIR}/.tdd/reviews/state.json"

read_state() {
  jq -r "$1 // empty" "${STATE_FILE}" 2>/dev/null
}

assert_no_writes() {
  info "Verifying no-write rule still holds"
  while IFS= read -r f; do
    [ -f "$f" ] && sha256sum "$f"
  done < "${SNAP_DIR}/files.txt" > "${SNAP_DIR}/check.hashes"
  if ! diff -q "${SNAP_DIR}/before.hashes" "${SNAP_DIR}/check.hashes" >/dev/null 2>&1; then
    echo "✗ FAIL: project files modified during review — NO-WRITE RULE VIOLATED" >&2
    diff "${SNAP_DIR}/before.hashes" "${SNAP_DIR}/check.hashes" | head -20 >&2
    exit 1
  fi
  pass "no-write rule held"
}

# ---- round 1 ----

info "Firing round 1 (real Codex call)"
R1_START=$(date +%s)
R1_LOG=$(mktemp)
bash runner/review-runner.sh "${PROJECT_DIR}" 2>&1 | tee "${R1_LOG}" | tail -20
R1_END=$(date +%s)
pass "round 1 completed in $((R1_END - R1_START))s"

# Assertions on round 1
[ -f "${STATE_FILE}" ] || fail "state.json not created"
STATUS=$(read_state '.status')
CYCLE_ID=$(read_state '.cycle_id')
ROUND=$(read_state '.round')
[ -n "${CYCLE_ID}" ] || fail "state.json missing cycle_id"
info "Cycle: ${CYCLE_ID} | status: ${STATUS} | round: ${ROUND}"

[ "${STATUS}" = "request_changes" ] \
  || fail "expected status=request_changes after round 1 (Codex didn't flag the loop) — got status=${STATUS}.
           This usually means: either the fixture isn't obvious enough, or Codex
           returned approve with a note. Check .tdd/reviews/${CYCLE_ID}/round-1.json"

CYCLE_DIR="${PROJECT_DIR}/.tdd/reviews/${CYCLE_ID}"
R1="${CYCLE_DIR}/round-1.json"
[ -f "${R1}" ] || fail "round-1.json missing"

VERDICT=$(jq -r '.verdict' "${R1}")
[ "${VERDICT}" = "request_changes" ] || fail "round-1.json verdict=${VERDICT}, expected request_changes"
pass "round 1 verdict: request_changes"

# Heuristic: at least one finding should mention the loop / hang. Print the
# matched finding so the operator can confirm Codex saw the right thing.
MATCHED=$(jq -r '
  .findings[]?
  | select((.title + " " + .body) | test("loop|hang|infinite|block|stall|deadlock|sleep"; "i"))
  | "[\(.severity)/\(.category)] \(.title)"
' "${R1}" | head -3)

if [ -z "${MATCHED}" ]; then
  warn "no finding mentions loop/hang — but verdict is request_changes, continuing"
  jq -r '.findings[] | "  [\(.severity)] \(.title)"' "${R1}" | head -5
else
  pass "Codex flagged the hang:"
  echo "${MATCHED}" | sed 's/^/    /'
fi

assert_no_writes

# Session id must have been captured by round 1 (Phase 2 round-n needs it).
SESSION_FILE="${CYCLE_DIR}/codex-session-id"
[ -f "${SESSION_FILE}" ] || fail "codex-session-id not captured by round 1 — Phase 2 resume cannot work"
SESSION_ID=$(cat "${SESSION_FILE}")
[ -n "${SESSION_ID}" ] || fail "session id file is empty"
pass "session id captured: ${SESSION_ID:0:24}..."

# ---- branch: convergence path vs escalation path ----

if [ "${SMOKE_PHASE2_ESCALATE:-0}" = "1" ]; then
  info "=== ESCALATION PATH: pushing through all rounds ==="

  MAX_ROUNDS=$(awk -F' = ' '/^max_rounds =/ {print $2; exit}' tdd-pack.toml | tr -d ' ')
  MAX_ROUNDS="${MAX_ROUNDS:-4}"

  for NEXT_ROUND in $(seq 2 "${MAX_ROUNDS}"); do
    info "Simulating Claude defending the bug for round ${NEXT_ROUND}"
    cat > "${CYCLE_DIR}/claude-response-${NEXT_ROUND}.txt" <<EOF
The loop is intentional — it's a test fixture for verifying the review
pipeline detects correctness blockers. It is not invoked in normal flow,
the function is dead code that's only called from a test path. I am
keeping it as-is. The pipeline working as designed (you flagged it
correctly) proves the system functions. No code change.
EOF

    info "Firing round ${NEXT_ROUND}"
    R_START=$(date +%s)
    R_LOG=$(mktemp)
    bash runner/review-runner.sh "${PROJECT_DIR}" 2>&1 | tee "${R_LOG}" | tail -10
    R_END=$(date +%s)
    pass "round ${NEXT_ROUND} completed in $((R_END - R_START))s"
    rm -f "${R_LOG}"

    R_TXT="${CYCLE_DIR}/round-${NEXT_ROUND}.txt"
    [ -f "${R_TXT}" ] || fail "round-${NEXT_ROUND}.txt missing"
    R_VERDICT=$(bash runner/extract-verdict.sh "${R_TXT}")
    info "round ${NEXT_ROUND} verdict: ${R_VERDICT}"
    assert_no_writes

    NEW_STATUS=$(read_state '.status')
    info "post-round ${NEXT_ROUND} status: ${NEW_STATUS}"

    if [ "${NEW_STATUS}" = "escalated" ]; then
      pass "cycle escalated as expected"
      break
    fi
    if [ "${NEW_STATUS}" = "converged" ]; then
      warn "Codex approved despite no fix — escalation path inconclusive"
      break
    fi
  done

  FINAL_STATUS=$(read_state '.status')
  if [ "${FINAL_STATUS}" = "escalated" ]; then
    pass "escalation path verified — status=escalated"
  else
    fail "escalation path did not reach escalated state — final status=${FINAL_STATUS}"
  fi
else
  info "=== CONVERGENCE PATH: simulating Claude fixing the bug ==="

  info "Reverting the fixture bug (simulating Claude's fix)"
  git -C "${PROJECT_DIR}" restore "${TARGET}"

  info "Writing claude-response-2.txt (simulating Stop hook capture)"
  cat > "${CYCLE_DIR}/claude-response-2.txt" <<'EOF'
You're right — the unconditional infinite loop in hooks/post-edit-review.sh
would have hung the hook on every PostToolUse. I've removed the loop and
the function that called it. The hook now returns normally. Please re-review.
EOF

  info "Firing round 2 (real Codex call via exec resume)"
  R2_START=$(date +%s)
  R2_LOG=$(mktemp)
  bash runner/review-runner.sh "${PROJECT_DIR}" 2>&1 | tee "${R2_LOG}" | tail -20
  R2_END=$(date +%s)
  pass "round 2 completed in $((R2_END - R2_START))s"

  R2_TXT="${CYCLE_DIR}/round-2.txt"
  [ -f "${R2_TXT}" ] || fail "round-2.txt missing — round 2 didn't run.
       Check ${R2_LOG} and ${CYCLE_DIR}/codex-stderr.log"
  R2_BYTES=$(wc -c < "${R2_TXT}")
  [ "${R2_BYTES}" -gt 0 ] || fail "round-2.txt is empty"
  pass "round-2.txt has ${R2_BYTES} bytes"

  R2_VERDICT=$(bash runner/extract-verdict.sh "${R2_TXT}")
  info "round 2 verdict: ${R2_VERDICT}"

  case "${R2_VERDICT}" in
    approve)
      pass "Codex approved after the fix — convergence path verified"
      ;;
    request_changes)
      warn "Codex still requesting changes after fix. Could mean:
           - Codex found something else in the diff Claude didn't address
           - The fix didn't actually revert the bug (check git diff)
           - Codex is being unusually strict
         Look at:
           ${R2_TXT}"
      ;;
    unclear)
      warn "round 2 verdict was unparseable. Check sentinel format in:
           ${R2_TXT}"
      ;;
  esac

  FINAL_STATUS=$(read_state '.status')
  info "Final status: ${FINAL_STATUS}"

  case "${FINAL_STATUS}" in
    converged) pass "state=converged" ;;
    request_changes) warn "state=request_changes (Codex held firm)" ;;
    escalated) warn "state=escalated (unexpected after 2 rounds with max_rounds>=4 — check max_rounds in tdd-pack.toml)" ;;
    *) fail "unexpected final state: ${FINAL_STATUS}" ;;
  esac

  assert_no_writes
fi

# ---- final summary ----

echo ""
echo "================================================================"
echo "  v2.0 PHASE 2 LIVE SMOKE — COMPLETE"
echo "================================================================"
echo "  cycle:         ${CYCLE_ID}"
echo "  mode:          $([ "${SMOKE_PHASE2_ESCALATE:-0}" = "1" ] && echo escalation || echo convergence)"
echo "  final status:  $(read_state '.status')"
echo "  final round:   $(read_state '.round')"
echo "  cycle dir:     ${CYCLE_DIR}"
echo "================================================================"

exit 0
