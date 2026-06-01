#!/usr/bin/env bash
# test/smoke-pre-review-protocol.sh
#
# Protocol smoke test for hooks/pre-review.sh — the PreToolUse gate
# for file-write tools (sub-piece #1 of task #109).
#
# Uses a fake reviewer subshell so the test runs offline (no Codex calls).
# Covers: experimental gating off / global kill switch / Bash pass-through /
# Write allow / Edit deny + findings rendered / timeout fail-closed /
# verdict cache hit / MultiEdit payload shape / NotebookEdit payload shape.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${PROJECT_ROOT}/hooks/pre-review.sh"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
PASS_COUNT=0

CLEANUP_PATHS=()
CLEANUP_PIDS=()
cleanup_all() {
  local pid p
  for pid in "${CLEANUP_PIDS[@]}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
  done
  for p in "${CLEANUP_PATHS[@]}"; do
    [[ -n "$p" ]] && rm -rf "$p"
  done
}
trap cleanup_all EXIT

make_sandbox() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.tdd/queue"
  echo "$d"
}

# Spawn a background "reviewer" that watches QUEUE_DIR/*.submission.json
# and writes a verdict JSON with the canned decision after delay_s seconds.
# Mimics what sub-piece #3 will do for real.
spawn_reviewer() {
  local sandbox="$1" decision="$2" reason="$3" delay_s="${4:-0.05}"
  (
    while true; do
      for sub in "$sandbox"/.tdd/queue/*.submission.json; do
        [[ -f "$sub" ]] || continue
        local hash; hash=$(basename "$sub" .submission.json)
        local verdict="$sandbox/.tdd/queue/${hash}.verdict.json"
        if [[ ! -f "$verdict" ]]; then
          sleep "$delay_s"
          jq -nc \
            --arg d "$decision" \
            --arg r "$reason" \
            '{decision:$d, reason:$r, findings:[]}' \
            > "${verdict}.tmp" 2>/dev/null \
            && mv "${verdict}.tmp" "$verdict"
        fi
      done
      sleep 0.05
    done
  ) &
  local pid=$!
  CLEANUP_PIDS+=("$pid")
}

# Reviewer that writes a deny verdict with non-empty findings.
spawn_reviewer_deny_with_findings() {
  local sandbox="$1"
  (
    while true; do
      for sub in "$sandbox"/.tdd/queue/*.submission.json; do
        [[ -f "$sub" ]] || continue
        local hash; hash=$(basename "$sub" .submission.json)
        local verdict="$sandbox/.tdd/queue/${hash}.verdict.json"
        if [[ ! -f "$verdict" ]]; then
          sleep 0.1
          cat > "${verdict}.tmp" <<'EOF'
{"decision":"deny","reason":"unsafe edit","findings":[{"severity":"blocker","category":"safety","title":"deletes guarded path","body":"the new_string removes a sentinel that other code reads"}]}
EOF
          mv "${verdict}.tmp" "$verdict"
        fi
      done
      sleep 0.05
    done
  ) &
  local pid=$!
  CLEANUP_PIDS+=("$pid")
}

# Build a PreToolUse JSON for a given tool kind.
make_input() {
  local tool="$1" file="$2"
  case "$tool" in
    Write)
      jq -nc \
        --arg t "$tool" --arg f "$file" \
        --arg c "package main
func main(){}
" \
        '{tool_name:$t, session_id:"sess-1", tool_input:{file_path:$f, content:$c}}'
      ;;
    Edit)
      jq -nc \
        --arg t "$tool" --arg f "$file" \
        '{tool_name:$t, session_id:"sess-1", tool_input:{file_path:$f, old_string:"x", new_string:"y"}}'
      ;;
    MultiEdit)
      jq -nc \
        --arg t "$tool" --arg f "$file" \
        '{tool_name:$t, session_id:"sess-1", tool_input:{file_path:$f, edits:[{old_string:"a", new_string:"b"}, {old_string:"c", new_string:"d"}]}}'
      ;;
    NotebookEdit)
      jq -nc \
        --arg t "$tool" --arg f "$file" \
        '{tool_name:$t, session_id:"sess-1", tool_input:{notebook_path:$f, new_source:"print(42)", cell_id:"abc"}}'
      ;;
    Bash)
      jq -nc \
        --arg t "$tool" \
        '{tool_name:$t, session_id:"sess-1", tool_input:{command:"ls -la"}}'
      ;;
  esac
}

# ---- case 1: experimental flag OFF → pass-through ----

info "[1] experimental flag off → empty output (pass-through)"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(
  CLAUDE_PROJECT_DIR="$SANDBOX" \
  PRILIVE_PRE_REVIEW_EXPERIMENTAL=0 \
  bash "$HOOK" <<< "$(make_input Write "$SANDBOX/foo.go")"
)
if [[ -z "$OUT" ]]; then
  pass "experimental off: hook emitted no JSON"
  PASS_COUNT=$((PASS_COUNT+1))
else
  fail "experimental off: expected no output, got: $OUT"
fi

# ---- case 2: global kill switch beats experimental flag ----

info "[2] PRILIVE_REVIEW_DISABLE=1 wins even when experimental on"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(
  CLAUDE_PROJECT_DIR="$SANDBOX" \
  PRILIVE_PRE_REVIEW_EXPERIMENTAL=1 \
  PRILIVE_REVIEW_DISABLE=1 \
  bash "$HOOK" <<< "$(make_input Write "$SANDBOX/foo.go")"
)
if [[ -z "$OUT" ]]; then
  pass "global disable: hook is silent"
  PASS_COUNT=$((PASS_COUNT+1))
else
  fail "global disable: expected no output, got: $OUT"
fi

# ---- case 3: Bash + fake APPROVE → permissionDecision=allow ----

info "[3] Bash + fake APPROVE → allow + kind=bash_command in submission"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
spawn_reviewer "$SANDBOX" "allow" "read-only command"
OUT=$(
  CLAUDE_PROJECT_DIR="$SANDBOX" \
  PRILIVE_PRE_REVIEW_EXPERIMENTAL=1 \
  PRILIVE_PRE_REVIEW_DEADLINE_S=10 \
  bash "$HOOK" <<< "$(make_input Bash "")"
)
DECISION=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
[[ "$DECISION" == "allow" ]] || fail "Bash + allow: expected allow, got: $DECISION (out=$OUT)"
SUB_FILE=$(find "$SANDBOX/.tdd/queue" -maxdepth 1 -name '*.submission.json' 2>/dev/null | head -1)
[[ -n "$SUB_FILE" ]] || fail "Bash submission file not written"
KIND=$(jq -r '.payload.kind // empty' "$SUB_FILE" 2>/dev/null)
CMD=$(jq -r '.payload.bash_command // empty' "$SUB_FILE" 2>/dev/null)
[[ "$KIND" == "bash_command" ]] || fail "Bash submission kind should be bash_command; got: $KIND"
[[ "$CMD" == "ls -la" ]] || fail "Bash submission bash_command should be 'ls -la'; got: $CMD"
pass "Bash + allow: hook emitted allow + submission has kind=bash_command + command field"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 4: Write + fake APPROVE → permissionDecision=allow ----

info "[4] Write + fake APPROVE → allow"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
spawn_reviewer "$SANDBOX" "allow" "looks fine"
OUT=$(
  CLAUDE_PROJECT_DIR="$SANDBOX" \
  PRILIVE_PRE_REVIEW_EXPERIMENTAL=1 \
  PRILIVE_PRE_REVIEW_DEADLINE_S=10 \
  bash "$HOOK" <<< "$(make_input Write "$SANDBOX/foo.go")"
)
DECISION=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
EVENT=$(echo "$OUT"   | jq -r '.hookSpecificOutput.hookEventName     // empty' 2>/dev/null)
[[ "$EVENT" == "PreToolUse" ]] || fail "expected hookEventName=PreToolUse, got: $EVENT"
[[ "$DECISION" == "allow" ]]   || fail "expected allow, got: $DECISION (out=$OUT)"
pass "Write + allow: hook emitted permissionDecision=allow"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 5: Edit + fake DENY with findings → permissionDecision=deny ----

info "[5] Edit + fake DENY → deny + findings rendered into reason"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
spawn_reviewer_deny_with_findings "$SANDBOX"
OUT=$(
  CLAUDE_PROJECT_DIR="$SANDBOX" \
  PRILIVE_PRE_REVIEW_EXPERIMENTAL=1 \
  PRILIVE_PRE_REVIEW_DEADLINE_S=10 \
  bash "$HOOK" <<< "$(make_input Edit "$SANDBOX/x.go")"
)
DECISION=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision       // empty' 2>/dev/null)
REASON=$(echo "$OUT"   | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
[[ "$DECISION" == "deny" ]]               || fail "expected deny, got: $DECISION"
[[ "$REASON" == *"unsafe edit"* ]]        || fail "reason missing top-level message: $REASON"
[[ "$REASON" == *"deletes guarded path"* ]] || fail "reason missing finding title: $REASON"
pass "Edit + deny: decision + findings rendered in permissionDecisionReason"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 6: timeout (no reviewer) → fail-closed deny ----

info "[6] no reviewer running → fail-closed deny on short deadline"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(
  CLAUDE_PROJECT_DIR="$SANDBOX" \
  PRILIVE_PRE_REVIEW_EXPERIMENTAL=1 \
  PRILIVE_PRE_REVIEW_DEADLINE_S=1 \
  PRILIVE_PRE_REVIEW_POLL_S=0.1 \
  bash "$HOOK" <<< "$(make_input Write "$SANDBOX/foo.go")"
)
DECISION=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision       // empty' 2>/dev/null)
REASON=$(echo "$OUT"   | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
[[ "$DECISION" == "deny" ]]            || fail "expected deny on timeout, got: $DECISION"
[[ "$REASON" == *"review pending"* ]]  || fail "deny reason missing 'review pending': $REASON"
pass "no-reviewer timeout: hook fails closed with 'review pending — retry'"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 7: pre-existing verdict file → instant cache hit ----

info "[7] verdict file already present → instant cache hit, no submission needed"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
INPUT=$(make_input Write "$SANDBOX/cached.go")
# Compute the same canonical payload + hash the hook will compute.
# Must mirror hooks/pre-review.sh exactly — adding/removing fields here
# without matching the hook will break the cache-hit assertion.
PAYLOAD=$(echo "$INPUT" | jq -c --arg kind "file_change" '
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
')
if command -v sha256sum >/dev/null 2>&1; then
  HASH=$(printf '%s' "$PAYLOAD" | sha256sum | awk '{print $1}')
else
  HASH=$(printf '%s' "$PAYLOAD" | shasum -a 256 | awk '{print $1}')
fi
echo '{"decision":"allow","reason":"cached approve","findings":[]}' \
  > "$SANDBOX/.tdd/queue/${HASH}.verdict.json"

START=$(date +%s)
OUT=$(
  CLAUDE_PROJECT_DIR="$SANDBOX" \
  PRILIVE_PRE_REVIEW_EXPERIMENTAL=1 \
  PRILIVE_PRE_REVIEW_DEADLINE_S=10 \
  bash "$HOOK" <<< "$INPUT"
)
END=$(date +%s)
ELAPSED=$((END - START))
DECISION=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
[[ "$DECISION" == "allow" ]] || fail "cache hit: expected allow, got: $DECISION (out=$OUT)"
[[ "$ELAPSED" -lt 3 ]]       || fail "cache hit took ${ELAPSED}s; should be near-instant"
# Verify no submission file was written (hook short-circuited on cache).
SUB_COUNT=$(find "$SANDBOX/.tdd/queue" -maxdepth 1 -name '*.submission.json' 2>/dev/null | wc -l | tr -d ' ')
[[ "$SUB_COUNT" == "0" ]] || fail "cache hit: hook wrote a submission anyway ($SUB_COUNT files)"
pass "verdict cache hit: instant allow (${ELAPSED}s), no submission written"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 8: MultiEdit submission shape ----

info "[8] MultiEdit input → submission payload carries edits array"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
spawn_reviewer "$SANDBOX" "allow" "ok"
OUT=$(
  CLAUDE_PROJECT_DIR="$SANDBOX" \
  PRILIVE_PRE_REVIEW_EXPERIMENTAL=1 \
  PRILIVE_PRE_REVIEW_DEADLINE_S=10 \
  bash "$HOOK" <<< "$(make_input MultiEdit "$SANDBOX/multi.go")"
)
DECISION=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
[[ "$DECISION" == "allow" ]] || fail "MultiEdit: expected allow, got: $DECISION"
# A submission file should exist from this run; inspect it.
SUB_FILE=$(find "$SANDBOX/.tdd/queue" -maxdepth 1 -name '*.submission.json' 2>/dev/null | head -1)
[[ -n "$SUB_FILE" ]] || fail "MultiEdit: no submission file written"
EDITS_COUNT=$(jq -r '.payload.multi_edits | length' "$SUB_FILE" 2>/dev/null || echo 0)
KIND=$(jq -r '.payload.kind' "$SUB_FILE" 2>/dev/null)
[[ "$EDITS_COUNT" -eq 2 ]] || fail "MultiEdit submission should have 2 edits; got $EDITS_COUNT"
[[ "$KIND" == "file_change" ]] || fail "MultiEdit submission kind should be file_change; got: $KIND"
pass "MultiEdit: submission payload carries all edits + kind=file_change"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 9: NotebookEdit submission shape ----

info "[9] NotebookEdit input → submission payload carries notebook fields"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
spawn_reviewer "$SANDBOX" "allow" "ok"
OUT=$(
  CLAUDE_PROJECT_DIR="$SANDBOX" \
  PRILIVE_PRE_REVIEW_EXPERIMENTAL=1 \
  PRILIVE_PRE_REVIEW_DEADLINE_S=10 \
  bash "$HOOK" <<< "$(make_input NotebookEdit "$SANDBOX/notebook.ipynb")"
)
DECISION=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
[[ "$DECISION" == "allow" ]] || fail "NotebookEdit: expected allow, got: $DECISION"
SUB_FILE=$(find "$SANDBOX/.tdd/queue" -maxdepth 1 -name '*.submission.json' 2>/dev/null | head -1)
[[ -n "$SUB_FILE" ]] || fail "NotebookEdit: no submission file written"
SOURCE=$(jq -r '.payload.notebook_source // empty' "$SUB_FILE" 2>/dev/null)
CELL=$(jq -r '.payload.notebook_cell_id // empty' "$SUB_FILE" 2>/dev/null)
FILE_PATH=$(jq -r '.payload.file_path // empty' "$SUB_FILE" 2>/dev/null)
[[ "$SOURCE" == "print(42)" ]]     || fail "NotebookEdit submission missing new_source; got: $SOURCE"
[[ "$CELL" == "abc" ]]             || fail "NotebookEdit submission missing cell_id; got: $CELL"
[[ "$FILE_PATH" == *"notebook.ipynb" ]] || fail "NotebookEdit submission file_path wrong; got: $FILE_PATH"
pass "NotebookEdit: submission carries notebook source + cell_id + path"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 10: Bash + fake DENY with findings → deny + findings rendered ----

info "[10] Bash + fake DENY → deny + findings rendered into reason"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
spawn_reviewer_deny_with_findings "$SANDBOX"
OUT=$(
  CLAUDE_PROJECT_DIR="$SANDBOX" \
  PRILIVE_PRE_REVIEW_EXPERIMENTAL=1 \
  PRILIVE_PRE_REVIEW_DEADLINE_S=10 \
  bash "$HOOK" <<< "$(make_input Bash "")"
)
DECISION=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision       // empty' 2>/dev/null)
REASON=$(echo "$OUT"   | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
[[ "$DECISION" == "deny" ]]               || fail "Bash + deny: expected deny, got: $DECISION"
[[ "$REASON" == *"unsafe edit"* ]]        || fail "Bash deny: reason missing top-level message"
[[ "$REASON" == *"deletes guarded path"* ]] || fail "Bash deny: reason missing finding title"
pass "Bash + deny: decision + findings rendered in permissionDecisionReason"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 11: Bash with missing .tool_input.command → fail-closed deny ----

info "[11] Bash with no .tool_input.command → fail-closed deny"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
# Build a malformed Bash PreToolUse input: tool_input present but no command.
MALFORMED=$(jq -nc '{tool_name:"Bash", session_id:"sess-1", tool_input:{description:"sneaky"}}')
OUT=$(
  CLAUDE_PROJECT_DIR="$SANDBOX" \
  PRILIVE_PRE_REVIEW_EXPERIMENTAL=1 \
  PRILIVE_PRE_REVIEW_DEADLINE_S=10 \
  bash "$HOOK" <<< "$MALFORMED"
)
DECISION=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision       // empty' 2>/dev/null)
REASON=$(echo "$OUT"   | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
[[ "$DECISION" == "deny" ]]                    || fail "Bash missing command: expected deny, got: $DECISION"
[[ "$REASON" == *"no .tool_input.command"* ]]  || fail "Bash missing command: reason wrong: $REASON"
# Confirm we did NOT write a submission file for the empty command.
SUB_COUNT=$(find "$SANDBOX/.tdd/queue" -maxdepth 1 -name '*.submission.json' 2>/dev/null | wc -l | tr -d ' ')
[[ "$SUB_COUNT" == "0" ]] || fail "Bash missing command: hook should not submit; wrote $SUB_COUNT file(s)"
pass "Bash missing command: hook fails closed before submitting"
PASS_COUNT=$((PASS_COUNT+1))

# ---- summary ----

echo ""
echo "================================================================"
echo "  PRE-REVIEW PROTOCOL SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
exit 0
