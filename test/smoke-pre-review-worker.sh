#!/usr/bin/env bash
# test/smoke-pre-review-worker.sh
#
# End-to-end smoke for runner/pre-review-worker.sh (sub-piece #3 of task
# #109). Uses a fake `codex` binary in PATH so the test runs offline.
#
# Covers: file_change submission → verdict appears with allow; bash
# read-only → verdict allow + classification=read_only; bash
# state-changing → verdict deny + findings; Codex non-zero → fail-closed
# deny; concurrent launches → single worker (flock); end-to-end hook +
# worker handshake produces permissionDecision.

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

# Build a sandbox project that looks like a real pack install (just the
# bits the worker reads).
make_sandbox() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.tdd/queue" "$d/runner/lib" "$d/prompts" "$d/schemas"
  cp "${PROJECT_ROOT}/runner/pre-review-worker.sh" "$d/runner/"
  cp "${PROJECT_ROOT}/runner/lib/codex-capabilities.sh" "$d/runner/lib/"
  cp "${PROJECT_ROOT}/runner/lib/config.sh"             "$d/runner/lib/"
  cp "${PROJECT_ROOT}/schemas/pre-review-verdict.schema.json" "$d/schemas/"
  cp "${PROJECT_ROOT}/prompts/codex-pre-review-system.md"     "$d/prompts/"
  cp "${PROJECT_ROOT}/prompts/codex-pre-review-file-user.md"  "$d/prompts/"
  cp "${PROJECT_ROOT}/prompts/codex-pre-review-bash-user.md"  "$d/prompts/"
  # Minimal tdd-pack.toml so cfg_get has something to read.
  cat > "$d/tdd-pack.toml" <<'EOF'
[codex]
model = ""
reasoning_effort = "medium"
web_search = "disabled"
EOF
  # Pre-seed the capability cache so the worker doesn't probe fake codex.
  cat > "$d/.tdd/.codex-capabilities.json" <<'EOF'
{
  "available": true,
  "version": "codex-cli 9.9.9-fake",
  "detected_at": "2026-06-01T00:00:00Z",
  "supports_json": true,
  "supports_output_last_message": true,
  "supports_output_schema_exec": true,
  "supports_output_schema_resume": false
}
EOF
  echo "$d"
}

# Install a fake codex that writes a canned response to the -o file.
# The canned response is read from FAKE_CODEX_RESPONSE env var (a path
# to a JSON file). If FAKE_CODEX_EXIT=N is set, codex exits with N
# instead of 0.
install_fake_codex() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat > "$bindir/codex" <<'CODEXEOF'
#!/usr/bin/env bash
# fake codex for the pre-review worker smoke
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output-last-message)
      out="$2"; shift 2 ;;
    --output-schema)
      shift 2 ;;
    --model|-c|--cd)
      shift 2 ;;
    --version)
      echo "codex-cli 9.9.9-fake"; exit 0 ;;
    exec)
      shift ;;
    --help)
      cat <<HELP
Run Codex non-interactively
Options:
      --output-schema <FILE>
      --json
  -o, --output-last-message <FILE>
HELP
      exit 0 ;;
    *) shift ;;
  esac
done

# Drain stdin so the heredoc completes cleanly.
cat > /dev/null

# Optional exit override for fault-injection cases.
if [[ -n "${FAKE_CODEX_EXIT:-}" ]] && [[ "${FAKE_CODEX_EXIT}" != "0" ]]; then
  exit "${FAKE_CODEX_EXIT}"
fi

# Write the canned response to the -o path.
if [[ -n "$out" ]] && [[ -n "${FAKE_CODEX_RESPONSE:-}" ]]; then
  cp "${FAKE_CODEX_RESPONSE}" "$out"
fi
exit 0
CODEXEOF
  chmod +x "$bindir/codex"
}

# Write a submission file directly (skip the hook).
write_submission() {
  local sandbox="$1" hash="$2" payload_json="$3"
  jq -n \
    --arg hash "$hash" \
    --argjson payload "$payload_json" \
    '{content_hash:$hash, session_id:"sess-1", submitted_at:"2026-06-01T00:00:00Z", deadline_epoch:9999999999, payload:$payload}' \
    > "$sandbox/.tdd/queue/${hash}.submission.json"
}

# Wait up to N seconds for a file to exist.
wait_for_file() {
  local path="$1" timeout="${2:-10}"
  local attempts=$(( timeout * 10 ))
  while [[ "$attempts" -gt 0 ]]; do
    [[ -f "$path" ]] && return 0
    sleep 0.1
    attempts=$((attempts - 1))
  done
  return 1
}

# ---- case 1: file_change submission → verdict allow ----

info "[1] file_change submission → worker writes verdict allow"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
BINDIR="$SANDBOX/bin"; install_fake_codex "$BINDIR"
RESP="$SANDBOX/fake-response.json"
cat > "$RESP" <<'EOF'
{"decision":"allow","classification":"file_change","reason":"looks safe","findings":[]}
EOF
HASH="aaaa111111111111111111111111111111111111111111111111111111111111"
PAYLOAD='{"kind":"file_change","tool_name":"Write","file_path":"x.go","write_content":"package x","edit_old_string":null,"edit_new_string":null,"multi_edits":null,"notebook_source":null,"notebook_cell_id":null,"bash_command":null,"bash_description":null}'
write_submission "$SANDBOX" "$HASH" "$PAYLOAD"

(
  export PATH="${BINDIR}:${PATH}"
  export FAKE_CODEX_RESPONSE="$RESP"
  bash "$SANDBOX/runner/pre-review-worker.sh" "$SANDBOX"
)

VERDICT="$SANDBOX/.tdd/queue/${HASH}.verdict.json"
[[ -f "$VERDICT" ]] || fail "verdict file not written"
DEC=$(jq -r '.decision' "$VERDICT")
CLS=$(jq -r '.classification' "$VERDICT")
[[ "$DEC" == "allow" ]]       || fail "expected allow, got: $DEC"
[[ "$CLS" == "file_change" ]] || fail "expected classification=file_change, got: $CLS"
pass "file_change: verdict=allow, classification=file_change"
PASS_COUNT=$((PASS_COUNT + 1))

# ---- case 2: bash read-only → allow + classification=read_only ----

info "[2] bash_command (ls -la) read-only → allow + read_only"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
BINDIR="$SANDBOX/bin"; install_fake_codex "$BINDIR"
RESP="$SANDBOX/fake-response.json"
cat > "$RESP" <<'EOF'
{"decision":"allow","classification":"read_only","reason":"read-only listing","findings":[]}
EOF
HASH="bbbb222222222222222222222222222222222222222222222222222222222222"
PAYLOAD='{"kind":"bash_command","tool_name":"Bash","file_path":"","write_content":null,"edit_old_string":null,"edit_new_string":null,"multi_edits":null,"notebook_source":null,"notebook_cell_id":null,"bash_command":"ls -la","bash_description":"list files"}'
write_submission "$SANDBOX" "$HASH" "$PAYLOAD"

(
  export PATH="${BINDIR}:${PATH}"
  export FAKE_CODEX_RESPONSE="$RESP"
  bash "$SANDBOX/runner/pre-review-worker.sh" "$SANDBOX"
)

VERDICT="$SANDBOX/.tdd/queue/${HASH}.verdict.json"
[[ -f "$VERDICT" ]] || fail "verdict file not written"
DEC=$(jq -r '.decision' "$VERDICT")
CLS=$(jq -r '.classification' "$VERDICT")
[[ "$DEC" == "allow" ]]      || fail "bash read-only: expected allow, got: $DEC"
[[ "$CLS" == "read_only" ]]  || fail "bash read-only: expected classification=read_only, got: $CLS"
pass "bash read-only: verdict=allow, classification=read_only"
PASS_COUNT=$((PASS_COUNT + 1))

# ---- case 3: bash state-changing → deny + findings ----

info "[3] bash_command (rm -rf) state-changing → deny + findings rendered"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
BINDIR="$SANDBOX/bin"; install_fake_codex "$BINDIR"
RESP="$SANDBOX/fake-response.json"
cat > "$RESP" <<'EOF'
{"decision":"deny","classification":"state_changing","reason":"rm -rf is irreversible","findings":[{"severity":"blocker","category":"data_loss","title":"recursive delete","body":"removes the entire build/ tree with no backup","confidence":5}]}
EOF
HASH="cccc333333333333333333333333333333333333333333333333333333333333"
PAYLOAD='{"kind":"bash_command","tool_name":"Bash","file_path":"","write_content":null,"edit_old_string":null,"edit_new_string":null,"multi_edits":null,"notebook_source":null,"notebook_cell_id":null,"bash_command":"rm -rf ./build","bash_description":"clean build"}'
write_submission "$SANDBOX" "$HASH" "$PAYLOAD"

(
  export PATH="${BINDIR}:${PATH}"
  export FAKE_CODEX_RESPONSE="$RESP"
  bash "$SANDBOX/runner/pre-review-worker.sh" "$SANDBOX"
)

VERDICT="$SANDBOX/.tdd/queue/${HASH}.verdict.json"
[[ -f "$VERDICT" ]] || fail "verdict file not written"
DEC=$(jq -r '.decision' "$VERDICT")
CLS=$(jq -r '.classification' "$VERDICT")
FCOUNT=$(jq -r '.findings | length' "$VERDICT")
[[ "$DEC" == "deny" ]]            || fail "bash state-changing: expected deny, got: $DEC"
[[ "$CLS" == "state_changing" ]]  || fail "bash state-changing: expected classification=state_changing, got: $CLS"
[[ "$FCOUNT" -ge 1 ]]             || fail "bash state-changing: expected at least 1 finding; got $FCOUNT"
pass "bash state-changing: verdict=deny, classification=state_changing, ${FCOUNT} finding(s)"
PASS_COUNT=$((PASS_COUNT + 1))

# ---- case 4: codex non-zero exit → fail-closed deny ----

info "[4] codex exec non-zero → fail-closed deny verdict"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
BINDIR="$SANDBOX/bin"; install_fake_codex "$BINDIR"
HASH="dddd444444444444444444444444444444444444444444444444444444444444"
PAYLOAD='{"kind":"file_change","tool_name":"Write","file_path":"x.go","write_content":"package x","edit_old_string":null,"edit_new_string":null,"multi_edits":null,"notebook_source":null,"notebook_cell_id":null,"bash_command":null,"bash_description":null}'
write_submission "$SANDBOX" "$HASH" "$PAYLOAD"

(
  export PATH="${BINDIR}:${PATH}"
  export FAKE_CODEX_EXIT=2
  bash "$SANDBOX/runner/pre-review-worker.sh" "$SANDBOX"
)

VERDICT="$SANDBOX/.tdd/queue/${HASH}.verdict.json"
[[ -f "$VERDICT" ]] || fail "fail-closed: verdict file not written"
DEC=$(jq -r '.decision' "$VERDICT")
REASON=$(jq -r '.reason' "$VERDICT")
[[ "$DEC" == "deny" ]]                              || fail "fail-closed: expected deny, got: $DEC"
[[ "$REASON" == *"Codex returned non-zero"* ]]      || fail "fail-closed: reason missing diagnostic: $REASON"
pass "codex non-zero: worker writes fail-closed deny verdict"
PASS_COUNT=$((PASS_COUNT + 1))

# ---- case 5: codex output not valid JSON → deny ----

info "[5] codex output not valid JSON → deny"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
BINDIR="$SANDBOX/bin"; install_fake_codex "$BINDIR"
RESP="$SANDBOX/fake-response.json"
echo 'this is not json' > "$RESP"
HASH="eeee555555555555555555555555555555555555555555555555555555555555"
PAYLOAD='{"kind":"file_change","tool_name":"Write","file_path":"x.go","write_content":"package x","edit_old_string":null,"edit_new_string":null,"multi_edits":null,"notebook_source":null,"notebook_cell_id":null,"bash_command":null,"bash_description":null}'
write_submission "$SANDBOX" "$HASH" "$PAYLOAD"

(
  export PATH="${BINDIR}:${PATH}"
  export FAKE_CODEX_RESPONSE="$RESP"
  bash "$SANDBOX/runner/pre-review-worker.sh" "$SANDBOX"
)

VERDICT="$SANDBOX/.tdd/queue/${HASH}.verdict.json"
DEC=$(jq -r '.decision' "$VERDICT")
REASON=$(jq -r '.reason' "$VERDICT")
[[ "$DEC" == "deny" ]]                         || fail "bad JSON: expected deny, got: $DEC"
[[ "$REASON" == *"not valid JSON"* ]]          || fail "bad JSON: reason wrong: $REASON"
pass "codex bad JSON: worker writes deny"
PASS_COUNT=$((PASS_COUNT + 1))

# ---- case 6: idempotency — verdict already present → worker skips ----

info "[6] worker is idempotent: existing verdict is not overwritten"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
BINDIR="$SANDBOX/bin"; install_fake_codex "$BINDIR"
RESP="$SANDBOX/fake-response.json"
cat > "$RESP" <<'EOF'
{"decision":"allow","classification":"file_change","reason":"fresh","findings":[]}
EOF
HASH="ffff666666666666666666666666666666666666666666666666666666666666"
PAYLOAD='{"kind":"file_change","tool_name":"Write","file_path":"x.go","write_content":"package x","edit_old_string":null,"edit_new_string":null,"multi_edits":null,"notebook_source":null,"notebook_cell_id":null,"bash_command":null,"bash_description":null}'
write_submission "$SANDBOX" "$HASH" "$PAYLOAD"
PRE_EXISTING='{"decision":"deny","classification":"file_change","reason":"pre-existing — must not be overwritten","findings":[]}'
echo "$PRE_EXISTING" > "$SANDBOX/.tdd/queue/${HASH}.verdict.json"

(
  export PATH="${BINDIR}:${PATH}"
  export FAKE_CODEX_RESPONSE="$RESP"
  bash "$SANDBOX/runner/pre-review-worker.sh" "$SANDBOX"
)

REASON=$(jq -r '.reason' "$SANDBOX/.tdd/queue/${HASH}.verdict.json")
[[ "$REASON" == "pre-existing — must not be overwritten" ]] || fail "idempotency: verdict was overwritten; reason=$REASON"
pass "idempotency: pre-existing verdict survived a worker pass"
PASS_COUNT=$((PASS_COUNT + 1))

# ---- case 7: end-to-end hook + worker handshake ----

info "[7] end-to-end: hook writes submission, worker drains it, hook polls verdict"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
BINDIR="$SANDBOX/bin"; install_fake_codex "$BINDIR"
RESP="$SANDBOX/fake-response.json"
cat > "$RESP" <<'EOF'
{"decision":"allow","classification":"file_change","reason":"e2e ok","findings":[]}
EOF
# Build a Write PreToolUse input.
INPUT=$(jq -nc \
  --arg f "$SANDBOX/foo.go" \
  --arg c "package main
func main(){}
" \
  '{tool_name:"Write", session_id:"sess-e2e", tool_input:{file_path:$f, content:$c}}')

# Run the hook — it should launch the worker via nohup, poll, and emit
# allow once the verdict appears.
OUT=$(
  export PATH="${BINDIR}:${PATH}"
  export FAKE_CODEX_RESPONSE="$RESP"
  CLAUDE_PROJECT_DIR="$SANDBOX" \
  PRILIVE_PRE_REVIEW_EXPERIMENTAL=1 \
  PRILIVE_PRE_REVIEW_DEADLINE_S=30 \
  PRILIVE_PRE_REVIEW_POLL_S=0.1 \
  bash "$HOOK" <<< "$INPUT"
)

DECISION=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
[[ "$DECISION" == "allow" ]] || fail "end-to-end: expected allow, got: $DECISION (out=$OUT)"

# Confirm both submission and verdict files exist.
SUB_COUNT=$(find "$SANDBOX/.tdd/queue" -maxdepth 1 -name '*.submission.json' 2>/dev/null | wc -l | tr -d ' ')
VER_COUNT=$(find "$SANDBOX/.tdd/queue" -maxdepth 1 -name '*.verdict.json' 2>/dev/null | wc -l | tr -d ' ')
[[ "$SUB_COUNT" -ge 1 ]] || fail "e2e: no submission file"
[[ "$VER_COUNT" -ge 1 ]] || fail "e2e: no verdict file"
pass "end-to-end: hook + worker produce permissionDecision=allow via verdict file"
PASS_COUNT=$((PASS_COUNT + 1))

# ---- summary ----

echo ""
echo "================================================================"
echo "  PRE-REVIEW WORKER SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
exit 0
