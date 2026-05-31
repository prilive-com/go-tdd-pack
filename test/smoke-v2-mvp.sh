#!/usr/bin/env bash
# test/smoke-v2-mvp.sh
#
# End-to-end smoke for the v2.0 MVP runner.
#
# What it does:
#   1. Refuses to run if your working tree has uncommitted changes (would
#      review those instead of the fixture).
#   2. Makes a small fixture edit to README.md (an HTML comment).
#   3. Snapshots hashes of all project files (for no-write verification).
#   4. Invokes the v2.0 runner directly (no Claude Code session needed).
#   5. Waits for the cycle to complete.
#   6. Validates state.json, round-1.json, and the no-write rule.
#   7. Reverts the fixture edit. Reports PASS/FAIL.
#
# Usage:
#   bash test/smoke-v2-mvp.sh
#
# Cost:
#   One real Codex call. With xhigh reasoning + tiny diff, expect
#   30-90 seconds and ~5-15K tokens. Cheap.
#
# Prerequisites:
#   - codex CLI installed and authenticated (`codex login`)
#   - jq installed
#   - clean git working tree
#   - You are inside the go-tdd-pack / go-claude-forge repo root

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PROJECT_DIR}" || exit 1

# ---- step 0: prerequisite checks ----

fail()  { echo "✗ FAIL: $*" >&2; exit 1; }
warn()  { echo "⚠ WARN: $*" >&2; }
info()  { echo "▶ $*"; }
pass()  { echo "✓ $*"; }

command -v codex >/dev/null || fail "codex CLI not in PATH (codex login first)"
command -v jq    >/dev/null || fail "jq not in PATH"
command -v git   >/dev/null || fail "git not in PATH"

[ -x "${PROJECT_DIR}/runner/review-runner.sh" ] \
  || fail "runner not found at runner/review-runner.sh — wrong directory?"

# ---- step 1: refuse on dirty working tree ----

if ! git diff --quiet HEAD 2>/dev/null; then
  DIFF_BYTES=$(git diff HEAD | wc -c)
  fail "working tree has uncommitted changes (${DIFF_BYTES} bytes)
       Test would review those instead of the fixture, burning tokens.
       Clean up first:
         git status
         git add ... && git commit -m '...'   # to keep
         git restore <files>                  # to discard"
fi

# ---- step 2: make a fixture edit ----

FIXTURE_MARKER="<!-- v2 smoke probe $(date -u +%s) -->"
info "Adding fixture comment to README.md"
echo "" >> README.md
echo "${FIXTURE_MARKER}" >> README.md

# Trap: always revert fixture on exit
revert_fixture() {
  git -C "${PROJECT_DIR}" restore README.md 2>/dev/null || true
}
trap revert_fixture EXIT

# ---- step 3: snapshot project files (for no-write verification) ----

info "Snapshotting project file hashes"
SNAP_DIR=$(mktemp -d)
# All tracked files minus the README we just modified ourselves
git ls-files | grep -v '^README\.md$' | sort > "${SNAP_DIR}/files.txt"
while IFS= read -r f; do
  [ -f "$f" ] && sha256sum "$f"
done < "${SNAP_DIR}/files.txt" > "${SNAP_DIR}/before.hashes"

BEFORE_COUNT=$(wc -l < "${SNAP_DIR}/before.hashes")
pass "snapshotted ${BEFORE_COUNT} project files"

# ---- step 4: invoke the runner ----

info "Firing runner (this is a real Codex call — please wait)"
START=$(date +%s)
RUNNER_LOG=$(mktemp)
bash runner/review-runner.sh "${PROJECT_DIR}" 2>&1 | tee "${RUNNER_LOG}" | tail -30
END=$(date +%s)
ELAPSED=$((END - START))
pass "runner completed in ${ELAPSED}s"

# ---- step 5: validate state.json ----

STATE_FILE="${PROJECT_DIR}/.tdd/reviews/state.json"
[ -f "${STATE_FILE}" ] || fail "state.json not created at ${STATE_FILE}"

STATUS=$(jq -r '.status // empty' "${STATE_FILE}")
CYCLE_ID=$(jq -r '.cycle_id // empty' "${STATE_FILE}")
[ -n "${CYCLE_ID}" ] || fail "state.json missing cycle_id"
[ -n "${STATUS}" ]   || fail "state.json missing status"

info "Cycle: ${CYCLE_ID}, status: ${STATUS}"

CYCLE_DIR="${PROJECT_DIR}/.tdd/reviews/${CYCLE_ID}"

case "${STATUS}" in
  converged)
    pass "cycle converged (Codex approved silently)"
    ;;
  request_changes)
    pass "cycle in request_changes (Codex returned findings — MVP stops here, Phase 2 will iterate)"
    ;;
  failed)
    STATUS_DETAIL=$(cat "${CYCLE_DIR}/.status" 2>/dev/null || echo "unknown")
    fail "cycle failed: ${STATUS_DETAIL}
       Inspect: ${RUNNER_LOG}
       And:     ${CYCLE_DIR}/"
    ;;
  *)
    fail "unexpected status: ${STATUS}"
    ;;
esac

# ---- step 6: validate round-1.json ----

R1="${CYCLE_DIR}/round-1.json"
[ -f "${R1}" ] || fail "round-1.json missing"
jq empty "${R1}" 2>/dev/null || fail "round-1.json is not valid JSON"

VERDICT=$(jq -r '.verdict' "${R1}")
FINDINGS_COUNT=$(jq -r '.findings | length' "${R1}")
FILES_READ=$(jq -r '.files_read | length' "${R1}")
SUMMARY=$(jq -r '.summary_one_sentence' "${R1}")
PARAGRAPH=$(jq -r '.summary_one_paragraph' "${R1}")

case "${VERDICT}" in
  approve|request_changes) pass "verdict: ${VERDICT}" ;;
  *) fail "invalid verdict in round-1.json: ${VERDICT}" ;;
esac

# Required fields per schema
for field in verdict summary_one_sentence summary_one_paragraph findings files_read questions_for_human; do
  jq -e "has(\"${field}\")" "${R1}" >/dev/null \
    || fail "round-1.json missing required field: ${field}"
done
pass "round-1.json has all required schema fields"

# ---- step 7: CRITICAL — verify no-write rule ----

info "Verifying Codex did not modify any project files"
while IFS= read -r f; do
  [ -f "$f" ] && sha256sum "$f"
done < "${SNAP_DIR}/files.txt" > "${SNAP_DIR}/after.hashes"

if ! diff -q "${SNAP_DIR}/before.hashes" "${SNAP_DIR}/after.hashes" >/dev/null 2>&1; then
  echo ""
  echo "✗ FAIL: project files were modified during the review."
  echo "  THE NO-WRITE RULE WAS VIOLATED."
  echo "  Differences:"
  diff "${SNAP_DIR}/before.hashes" "${SNAP_DIR}/after.hashes" | head -20
  echo ""
  echo "  This is a critical defect. The system prompt rule in"
  echo "  prompts/codex-system.md must be strengthened, or the"
  echo "  architecture revisited to add sandbox-level enforcement."
  rm -rf "${SNAP_DIR}"
  exit 1
fi
pass "no-write rule held — Codex did not modify any project files"

# ---- step 8: final summary ----

echo ""
echo "================================================================"
echo "  v2.0 MVP SMOKE — PASS"
echo "================================================================"
echo "  cycle id:        ${CYCLE_ID}"
echo "  verdict:         ${VERDICT}"
echo "  findings count:  ${FINDINGS_COUNT}"
echo "  files Codex read: ${FILES_READ}"
echo "  elapsed:         ${ELAPSED}s"
echo ""
echo "  summary:"
echo "    ${SUMMARY}"
echo ""
echo "  paragraph:"
echo "    ${PARAGRAPH}" | fold -s -w 60 | sed 's/^/    /'
echo "================================================================"

# Cleanup tmp files (trap handles README revert)
rm -rf "${SNAP_DIR}"
rm -f "${RUNNER_LOG}"

exit 0
