#!/usr/bin/env bash
# test/smoke-protect-tdd-artifacts.sh
#
# v2.1 PR 6 — Gate 4: verify hooks/protect-tdd-artifacts.sh denies
# direct Claude edits to engine-owned files (spec §10).

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${PROJECT_ROOT}/hooks/protect-tdd-artifacts.sh"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
PASS_COUNT=0

CLEANUP_PATHS=()
cleanup_all() {
  local p
  for p in "${CLEANUP_PATHS[@]}"; do
    [[ -n "$p" ]] && rm -rf "$p"
  done
}
trap cleanup_all EXIT

make_sandbox() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.tdd/reviews/cycle-test" "$d/.tdd/findings/R1-F1" "$d/.tdd/queue" "$d/.tdd/review"
  echo "$d"
}

# Build a PreToolUse Write JSON with a given file path.
mk_write_input() {
  local file="$1"
  jq -nc --arg t "Write" --arg f "$file" --arg c "x" \
    '{tool_name:$t, session_id:"s", tool_input:{file_path:$f, content:$c}}'
}

# Build a PreToolUse Edit JSON.
mk_edit_input() {
  local file="$1"
  jq -nc --arg t "Edit" --arg f "$file" \
    '{tool_name:$t, session_id:"s", tool_input:{file_path:$f, old_string:"a", new_string:"b"}}'
}

# Run the hook and return decision + reason from stdout.
run_hook_get_decision() {
  local sandbox="$1" input="$2"
  CLAUDE_PROJECT_DIR="$sandbox" bash "$HOOK" <<< "$input" 2>/dev/null \
    | jq -r '.hookSpecificOutput.permissionDecision // "(none)"'
}

assert_deny() {
  local sandbox="$1" file="$2" label="$3"
  local input dec
  input=$(mk_write_input "$sandbox/$file")
  dec=$(run_hook_get_decision "$sandbox" "$input")
  [[ "$dec" == "deny" ]] || fail "${label}: expected deny on ${file}, got: $dec"
  pass "${label}: blocked Write to ${file}"
  PASS_COUNT=$((PASS_COUNT+1))
}

assert_allow_or_noop() {
  local sandbox="$1" file="$2" label="$3"
  local input out
  input=$(mk_write_input "$sandbox/$file")
  # Capture raw stdout first — an empty stdout (hook exit 0 with no
  # output) is the most common pass-through case in Claude Code hooks.
  out=$(CLAUDE_PROJECT_DIR="$sandbox" bash "$HOOK" <<< "$input" 2>/dev/null)
  if [[ -z "$out" ]]; then
    pass "${label}: did NOT block ${file} (silent pass-through)"
    PASS_COUNT=$((PASS_COUNT+1))
    return
  fi
  local dec
  dec=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision // "(none)"' 2>/dev/null)
  [[ "$dec" == "(none)" || "$dec" == "allow" ]] || fail "${label}: expected pass-through on ${file}, got decision: $dec (out=$out)"
  pass "${label}: did NOT block ${file} (decision: ${dec})"
  PASS_COUNT=$((PASS_COUNT+1))
}

# ============================================================
# Each protected path → deny
# ============================================================

info "[1] writes to .tdd/findings/** are blocked"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
assert_deny "$SANDBOX" ".tdd/findings/R1-F1/red-proof.md"     "findings dir"
assert_deny "$SANDBOX" ".tdd/findings/R2-F3/finding.json"     "findings nested"

info "[2] writes to .tdd/review/ledger.jsonl blocked"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
assert_deny "$SANDBOX" ".tdd/review/ledger.jsonl" "calibration ledger"

info "[3] writes to .tdd/reviews/state.json blocked"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
assert_deny "$SANDBOX" ".tdd/reviews/state.json" "cycle state"

info "[4] writes to .tdd/reviews/debates.jsonl blocked"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
assert_deny "$SANDBOX" ".tdd/reviews/debates.jsonl" "event log"

info "[5] writes to .tdd/reviews/<cycle>/round-*.json blocked"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
assert_deny "$SANDBOX" ".tdd/reviews/cycle-test/round-1.json" "round 1 schema output"

info "[6] writes to .tdd/reviews/<cycle>/round-N.txt blocked"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
assert_deny "$SANDBOX" ".tdd/reviews/cycle-test/round-2.txt" "round N free-form output"

info "[7] writes to .tdd/reviews/<cycle>/.status blocked"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
assert_deny "$SANDBOX" ".tdd/reviews/cycle-test/.status" "cycle status file"

info "[8] writes to .tdd/reviews/<cycle>/codex-session-id blocked"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
assert_deny "$SANDBOX" ".tdd/reviews/cycle-test/codex-session-id" "session pointer"

info "[9] writes to .tdd/reviews/<cycle>/claude-response-N.txt blocked"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
assert_deny "$SANDBOX" ".tdd/reviews/cycle-test/claude-response-3.txt" "captured Claude response"

info "[10] writes to .tdd/queue/** blocked"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
assert_deny "$SANDBOX" ".tdd/queue/abc123.submission.json" "queue submission"
assert_deny "$SANDBOX" ".tdd/queue/abc123.verdict.json"    "queue verdict"

info "[11] writes to .tdd/.codex-capabilities.json blocked"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
assert_deny "$SANDBOX" ".tdd/.codex-capabilities.json" "capability cache"

# ============================================================
# Unrelated paths → pass-through
# ============================================================

info "[12] writes to unrelated paths pass through"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
assert_allow_or_noop "$SANDBOX" "internal/foo/bar.go"        "project source"
assert_allow_or_noop "$SANDBOX" "README.md"                  "docs"
assert_allow_or_noop "$SANDBOX" "tdd-pack.toml"              "shipped config (NOT protected — adopter edits this)"
assert_allow_or_noop "$SANDBOX" ".tdd/notes.md"              "free-form notes under .tdd/ (not in protected list)"

# ============================================================
# Bypass + non-file tools
# ============================================================

info "[13] PRILIVE_REVIEW_DISABLE=1 bypasses the gate"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
INPUT=$(mk_write_input "$SANDBOX/.tdd/reviews/state.json")
OUT=$(CLAUDE_PROJECT_DIR="$SANDBOX" PRILIVE_REVIEW_DISABLE=1 bash "$HOOK" <<< "$INPUT" 2>/dev/null)
[[ -z "$OUT" ]] || fail "kill switch: expected no output, got: $OUT"
pass "kill switch: PRILIVE_REVIEW_DISABLE=1 passes through even for protected paths"
PASS_COUNT=$((PASS_COUNT+1))

info "[14] non-file tools (Bash, Read) pass through"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
BASH_INPUT=$(jq -nc '{tool_name:"Bash", session_id:"s", tool_input:{command:"ls"}}')
OUT=$(CLAUDE_PROJECT_DIR="$SANDBOX" bash "$HOOK" <<< "$BASH_INPUT" 2>/dev/null)
[[ -z "$OUT" ]] || fail "Bash: expected no output, got: $OUT"
pass "Bash tool: no-op (gate covers file writes only)"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# Edit + MultiEdit + NotebookEdit also covered
# ============================================================

info "[15] Edit tool on protected path also blocked"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
INPUT=$(mk_edit_input "$SANDBOX/.tdd/reviews/state.json")
DEC=$(run_hook_get_decision "$SANDBOX" "$INPUT")
[[ "$DEC" == "deny" ]] || fail "Edit: expected deny, got: $DEC"
pass "Edit tool: protected paths also blocked"
PASS_COUNT=$((PASS_COUNT+1))

info "[16] NotebookEdit on protected notebook_path also blocked"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("$SANDBOX")
INPUT=$(jq -nc --arg t "NotebookEdit" --arg f "$SANDBOX/.tdd/findings/R1/note.ipynb" \
  '{tool_name:$t, session_id:"s", tool_input:{notebook_path:$f, new_source:"x", cell_id:"c"}}')
DEC=$(run_hook_get_decision "$SANDBOX" "$INPUT")
[[ "$DEC" == "deny" ]] || fail "NotebookEdit: expected deny, got: $DEC"
pass "NotebookEdit tool: protected notebook_path also blocked"
PASS_COUNT=$((PASS_COUNT+1))

# ---- summary ----

echo ""
echo "================================================================"
echo "  PROTECT TDD ARTIFACTS SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
exit 0
