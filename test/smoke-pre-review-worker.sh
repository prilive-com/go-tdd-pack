#!/usr/bin/env bash
# test/smoke-pre-review-worker.sh
#
# End-to-end smoke for runner/pre-review-worker.sh.
# Uses a fake `codex` binary in PATH so the test runs offline.
#
# v2.1: Bash cases removed when the matcher was retired. Worker now
# handles file_change only; classification field dropped from the
# verdict schema.
#
# Covers: file_change submission → verdict appears with allow;
# Codex non-zero → fail-closed deny; Codex bad JSON → deny;
# idempotency (existing verdict not overwritten); end-to-end hook +
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

# Canonical file_change payload (matches what hooks/pre-review.sh emits
# in v2.1 — no bash_command/bash_description fields).
FILE_CHANGE_PAYLOAD='{"kind":"file_change","tool_name":"Write","file_path":"x.go","write_content":"package x","edit_old_string":null,"edit_new_string":null,"multi_edits":null,"notebook_source":null,"notebook_cell_id":null}'

# ---- case 1: file_change submission → verdict allow ----

info "[1] file_change submission → worker writes verdict allow"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
BINDIR="$SANDBOX/bin"; install_fake_codex "$BINDIR"
RESP="$SANDBOX/fake-response.json"
cat > "$RESP" <<'EOF'
{"decision":"allow","reason":"looks safe","findings":[]}
EOF
HASH="aaaa111111111111111111111111111111111111111111111111111111111111"
write_submission "$SANDBOX" "$HASH" "$FILE_CHANGE_PAYLOAD"

(
  export PATH="${BINDIR}:${PATH}"
  export FAKE_CODEX_RESPONSE="$RESP"
  bash "$SANDBOX/runner/pre-review-worker.sh" "$SANDBOX"
)

VERDICT="$SANDBOX/.tdd/queue/${HASH}.verdict.json"
[[ -f "$VERDICT" ]] || fail "verdict file not written"
DEC=$(jq -r '.decision' "$VERDICT")
REASON=$(jq -r '.reason' "$VERDICT")
[[ "$DEC" == "allow" ]]            || fail "expected allow, got: $DEC"
[[ "$REASON" == "looks safe" ]]    || fail "expected reason='looks safe', got: $REASON"
pass "file_change: verdict=allow with reason intact"
PASS_COUNT=$((PASS_COUNT + 1))

# ---- case 2: codex non-zero exit → fail-closed deny ----

info "[2] codex exec non-zero → fail-closed deny verdict"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
BINDIR="$SANDBOX/bin"; install_fake_codex "$BINDIR"
HASH="dddd444444444444444444444444444444444444444444444444444444444444"
write_submission "$SANDBOX" "$HASH" "$FILE_CHANGE_PAYLOAD"

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

# ---- case 3: codex output not valid JSON → deny ----

info "[3] codex output not valid JSON → deny"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
BINDIR="$SANDBOX/bin"; install_fake_codex "$BINDIR"
RESP="$SANDBOX/fake-response.json"
echo 'this is not json' > "$RESP"
HASH="eeee555555555555555555555555555555555555555555555555555555555555"
write_submission "$SANDBOX" "$HASH" "$FILE_CHANGE_PAYLOAD"

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

# ---- case 4: idempotency — verdict already present → worker skips ----

info "[4] worker is idempotent: existing verdict is not overwritten"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
BINDIR="$SANDBOX/bin"; install_fake_codex "$BINDIR"
RESP="$SANDBOX/fake-response.json"
cat > "$RESP" <<'EOF'
{"decision":"allow","reason":"fresh","findings":[]}
EOF
HASH="ffff666666666666666666666666666666666666666666666666666666666666"
write_submission "$SANDBOX" "$HASH" "$FILE_CHANGE_PAYLOAD"
PRE_EXISTING='{"decision":"deny","reason":"pre-existing — must not be overwritten","findings":[]}'
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

# ---- case 5: end-to-end hook + worker handshake ----

info "[5] end-to-end: hook writes submission, worker drains it, hook polls verdict"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
BINDIR="$SANDBOX/bin"; install_fake_codex "$BINDIR"
RESP="$SANDBOX/fake-response.json"
cat > "$RESP" <<'EOF'
{"decision":"allow","reason":"e2e ok","findings":[]}
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
