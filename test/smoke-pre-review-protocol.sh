#!/usr/bin/env bash
# test/smoke-pre-review-protocol.sh
#
# Protocol smoke test for hooks/pre-review.sh — the PreToolUse gate
# for file-write tools.
#
# v2.1: Bash cases removed when the matcher was retired from the
# starter pack. The hook now covers Write|Edit|MultiEdit|NotebookEdit
# only; runtime command safety is out of scope.
#
# Uses a fake reviewer subshell so the test runs offline (no Codex calls).
# Covers: experimental gating off / global kill switch / Write allow /
# Edit deny + findings rendered / timeout fail-closed / verdict cache hit /
# MultiEdit payload shape / NotebookEdit payload shape / fail-closed
# audit cases / config-based activation.

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
# Mimics what the worker does for real.
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

# Build a PreToolUse JSON for a given tool kind (file-writers only).
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

# ---- case 3: Bash tool → pass-through (v2.1 removed the Bash matcher) ----

info "[3] Bash tool → pass-through (v2.1 retired Bash matcher)"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
# Build a Bash PreToolUse input by hand (make_input no longer supports Bash).
BASH_INPUT=$(jq -nc '{tool_name:"Bash", session_id:"sess-1", tool_input:{command:"ls -la"}}')
OUT=$(
  CLAUDE_PROJECT_DIR="$SANDBOX" \
  PRILIVE_PRE_REVIEW_EXPERIMENTAL=1 \
  bash "$HOOK" <<< "$BASH_INPUT"
)
if [[ -z "$OUT" ]]; then
  pass "Bash tool with gate ON: hook is silent (pass-through; gate covers file changes only)"
  PASS_COUNT=$((PASS_COUNT+1))
else
  fail "Bash pass-through: expected no output, got: $OUT"
fi

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
    notebook_cell_id: (.tool_input.cell_id     // null)
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

# ============================================================
# Fail-closed audit
# ============================================================

# ---- case 10: jq missing on PATH → deny (fail-closed) ----

info "[10] jq missing from PATH + experimental on → fail-closed deny"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
# Strip jq from PATH in a subshell. Keep coreutils so the hook can still
# run (sha256sum, awk, date, sleep).
JQ_REAL=$(command -v jq)
BIN_NO_JQ="$SANDBOX/bin-no-jq"
mkdir -p "$BIN_NO_JQ"
# Symlink every coreutil we care about, but NOT jq.
for tool in sha256sum shasum awk date sleep cat printf mv basename find dirname rm bash; do
  realp=$(command -v "$tool" 2>/dev/null) && ln -sf "$realp" "$BIN_NO_JQ/$tool"
done
OUT=$(
  PATH="$BIN_NO_JQ" \
  CLAUDE_PROJECT_DIR="$SANDBOX" \
  PRILIVE_PRE_REVIEW_EXPERIMENTAL=1 \
  bash "$HOOK" <<< "$(make_input Write "$SANDBOX/foo.go")"
)
# Re-enter parent shell context for parsing (jq is back on PATH).
DECISION=$(echo "$OUT" | "$JQ_REAL" -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
REASON=$(echo "$OUT"   | "$JQ_REAL" -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
[[ "$DECISION" == "deny" ]]              || fail "jq-missing: expected deny, got: $DECISION (out=$OUT)"
[[ "$REASON" == *"jq is not installed"* ]] || fail "jq-missing: reason wrong: $REASON"
pass "jq missing: hook emits deny with explicit 'install jq' hint"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 11: empty stdin → deny (fail-closed) ----

info "[11] empty stdin + experimental on → fail-closed deny"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(
  CLAUDE_PROJECT_DIR="$SANDBOX" \
  PRILIVE_PRE_REVIEW_EXPERIMENTAL=1 \
  bash "$HOOK" < /dev/null
)
DECISION=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
REASON=$(echo "$OUT"   | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
[[ "$DECISION" == "deny" ]]                  || fail "empty stdin: expected deny, got: $DECISION"
[[ "$REASON" == *"no input on stdin"* ]]     || fail "empty stdin: reason wrong: $REASON"
pass "empty stdin: hook emits deny with explicit reason"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 12: submission write fails (read-only queue dir) → deny ----

info "[12] submission write fails (read-only queue dir) → fail-closed deny"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
# Make .tdd/queue read-only so the jq tmp-write and mv both fail. The
# hook can still mkdir -p (mkdir is a no-op when the dir exists with any
# mode), but cannot create files inside it.
chmod a-w "$SANDBOX/.tdd/queue"
OUT=$(
  CLAUDE_PROJECT_DIR="$SANDBOX" \
  PRILIVE_PRE_REVIEW_EXPERIMENTAL=1 \
  PRILIVE_PRE_REVIEW_DEADLINE_S=2 \
  bash "$HOOK" <<< "$(make_input Write "$SANDBOX/foo.go")"
)
# Re-enable write so trap cleanup_all works.
chmod u+w "$SANDBOX/.tdd/queue"
DECISION=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
REASON=$(echo "$OUT"   | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
[[ "$DECISION" == "deny" ]]                       || fail "write-fail: expected deny, got: $DECISION"
[[ "$REASON" == *"failed to write submission"* ]] || fail "write-fail: reason wrong: $REASON"
pass "submission write fails: hook emits deny with specific cause (not the generic deadline message)"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# Config-based activation (tdd-pack.toml [pre_review] enabled)
# ============================================================

# Helper: a sandbox that includes runner/lib/config.sh so the hook can
# read tdd-pack.toml. The other tests don't need this because they use
# the env override path.
make_sandbox_with_config_libs() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.tdd/queue" "$d/runner/lib"
  cp "${PROJECT_ROOT}/runner/lib/config.sh" "$d/runner/lib/"
  echo "$d"
}

# ---- case 13: config enabled=true → gate active ----

info "[13] tdd-pack.toml pre_review.enabled = true → gate ON"
SANDBOX=$(make_sandbox_with_config_libs); CLEANUP_PATHS+=("$SANDBOX")
cat > "$SANDBOX/tdd-pack.toml" <<'EOF'
[pre_review]
enabled = true
EOF
spawn_reviewer "$SANDBOX" "allow" "config-gated review"
OUT=$(
  CLAUDE_PROJECT_DIR="$SANDBOX" \
  PRILIVE_PRE_REVIEW_DEADLINE_S=10 \
  bash "$HOOK" <<< "$(make_input Write "$SANDBOX/foo.go")"
)
DECISION=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
[[ "$DECISION" == "allow" ]] || fail "config enabled=true: expected allow, got: $DECISION (out=$OUT)"
pass "config enabled=true: gate active without env var, hook emitted allow"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 14: config enabled=false + no env → pass-through ----

info "[14] tdd-pack.toml pre_review.enabled = false + no env → pass-through"
SANDBOX=$(make_sandbox_with_config_libs); CLEANUP_PATHS+=("$SANDBOX")
cat > "$SANDBOX/tdd-pack.toml" <<'EOF'
[pre_review]
enabled = false
EOF
OUT=$(
  CLAUDE_PROJECT_DIR="$SANDBOX" \
  bash "$HOOK" <<< "$(make_input Write "$SANDBOX/foo.go")"
)
if [[ -z "$OUT" ]]; then
  pass "config enabled=false + no env: pass-through (no JSON)"
  PASS_COUNT=$((PASS_COUNT+1))
else
  fail "config enabled=false: expected no output, got: $OUT"
fi

# ---- case 15: env override wins over config=false ----

info "[15] env PRILIVE_PRE_REVIEW_EXPERIMENTAL=1 wins over config enabled=false"
SANDBOX=$(make_sandbox_with_config_libs); CLEANUP_PATHS+=("$SANDBOX")
cat > "$SANDBOX/tdd-pack.toml" <<'EOF'
[pre_review]
enabled = false
EOF
spawn_reviewer "$SANDBOX" "allow" "env-overridden"
OUT=$(
  CLAUDE_PROJECT_DIR="$SANDBOX" \
  PRILIVE_PRE_REVIEW_EXPERIMENTAL=1 \
  PRILIVE_PRE_REVIEW_DEADLINE_S=10 \
  bash "$HOOK" <<< "$(make_input Write "$SANDBOX/foo.go")"
)
DECISION=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
[[ "$DECISION" == "allow" ]] || fail "env override: expected allow, got: $DECISION (out=$OUT)"
pass "env override wins over config=false: gate active"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 16: global kill switch wins over BOTH env override and config=true ----

info "[16] PRILIVE_REVIEW_DISABLE=1 wins over config=true and env override"
SANDBOX=$(make_sandbox_with_config_libs); CLEANUP_PATHS+=("$SANDBOX")
cat > "$SANDBOX/tdd-pack.toml" <<'EOF'
[pre_review]
enabled = true
EOF
OUT=$(
  CLAUDE_PROJECT_DIR="$SANDBOX" \
  PRILIVE_PRE_REVIEW_EXPERIMENTAL=1 \
  PRILIVE_REVIEW_DISABLE=1 \
  bash "$HOOK" <<< "$(make_input Write "$SANDBOX/foo.go")"
)
if [[ -z "$OUT" ]]; then
  pass "global disable wins: hook silent even with config=true + env=1"
  PASS_COUNT=$((PASS_COUNT+1))
else
  fail "global disable: expected no output, got: $OUT"
fi

# ---- summary ----

echo ""
echo "================================================================"
echo "  PRE-REVIEW PROTOCOL SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
exit 0
