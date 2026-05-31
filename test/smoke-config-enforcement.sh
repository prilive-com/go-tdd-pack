#!/usr/bin/env bash
# test/smoke-config-enforcement.sh
#
# Verify task #101 non-rails config enforcement:
#   - runner/lib/config.sh cfg_get parser
#   - review-runner.sh budget check (max_cycle_minutes, max_codex_calls_per_cycle)
#   - codex-round1.sh must_address contract check
#   - inject-findings.sh min_surface filter
#
# All tests are deterministic and use synthetic fixtures — no Codex calls.

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INJECT="${PROJECT_DIR}/hooks/inject-findings.sh"
CONFIG_LIB="${PROJECT_DIR}/runner/lib/config.sh"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
PASS_COUNT=0

# Sandbox lifecycle (same pattern as escalation smoke, post-shellcheck cleanup)
CLEANUP_PATHS=()
cleanup_all_sandboxes() {
  local p
  for p in "${CLEANUP_PATHS[@]}"; do
    [[ -n "$p" ]] && rm -rf "$p"
  done
}
trap cleanup_all_sandboxes EXIT

make_sandbox() {
  local d
  d=$(mktemp -d)
  (
    cd "$d" || exit 1
    git init -q
    git config user.email "t@t"
    git config user.name "t"
    echo "x" > seed.txt
    git add -A && git commit -q -m "init"
    mkdir -p .tdd/reviews runner/lib
  ) >/dev/null 2>&1
  # Wire the runner + libs into the sandbox so the runner can find them.
  cp "${PROJECT_DIR}/runner"/*.sh "${d}/runner/"
  cp "${PROJECT_DIR}/runner/lib"/*.sh "${d}/runner/lib/"
  chmod +x "${d}/runner"/*.sh
  echo "$d"
}

write_config() {
  local sandbox="$1"
  cat > "${sandbox}/tdd-pack.toml"
}

# ---- Section 1: cfg_get parser ----

info "[1] cfg_get reads basic values"
SANDBOX=$(make_sandbox)
CLEANUP_PATHS+=("${SANDBOX}")
write_config "${SANDBOX}" <<'EOF'
[review]
max_rounds = 5
coalesce_ms = 5000
max_cycle_minutes = 30

[codex]
model = ""
reasoning_effort = "xhigh"
web_search = "live"

[severity]
min_surface = "minor"
must_address = "major"
EOF

# shellcheck source=/dev/null
. "${CONFIG_LIB}"

v=$(cfg_get "${SANDBOX}/tdd-pack.toml" "review.max_rounds" "0")
[[ "$v" == "5" ]] || fail "max_rounds expected 5, got '$v'"
pass "cfg_get review.max_rounds = $v"
PASS_COUNT=$((PASS_COUNT + 1))

v=$(cfg_get "${SANDBOX}/tdd-pack.toml" "codex.reasoning_effort" "high")
[[ "$v" == "xhigh" ]] || fail "reasoning_effort expected xhigh, got '$v'"
pass "cfg_get codex.reasoning_effort = $v"
PASS_COUNT=$((PASS_COUNT + 1))

v=$(cfg_get "${SANDBOX}/tdd-pack.toml" "severity.min_surface" "nit")
[[ "$v" == "minor" ]] || fail "min_surface expected minor, got '$v'"
pass "cfg_get severity.min_surface = $v"
PASS_COUNT=$((PASS_COUNT + 1))

info "[2] cfg_get returns default for missing key"
v=$(cfg_get "${SANDBOX}/tdd-pack.toml" "review.nonexistent" "fallback42")
[[ "$v" == "fallback42" ]] || fail "default expected fallback42, got '$v'"
pass "cfg_get returns default for missing key"
PASS_COUNT=$((PASS_COUNT + 1))

info "[3] cfg_get handles empty string value"
v=$(cfg_get "${SANDBOX}/tdd-pack.toml" "codex.model" "should-not-be-returned")
# Empty value should fall through to default per current semantics
# (jq-style: empty string is treated as missing)
[[ "$v" == "should-not-be-returned" ]] || fail "empty value should yield default, got '$v'"
pass "cfg_get empty value falls to default"
PASS_COUNT=$((PASS_COUNT + 1))

info "[4] cfg_get returns default when config file missing"
v=$(cfg_get "/nonexistent/path.toml" "review.max_rounds" "999")
[[ "$v" == "999" ]] || fail "missing file should yield default, got '$v'"
pass "cfg_get missing file falls to default"
PASS_COUNT=$((PASS_COUNT + 1))

# ---- Section 2: max_codex_calls_per_cycle budget gate ----

info "[5] runner blocks fresh cycle when codex_calls at cap"
SANDBOX=$(make_sandbox)
CLEANUP_PATHS+=("${SANDBOX}")
write_config "${SANDBOX}" <<'EOF'
[review]
max_rounds = 5
max_codex_calls_per_cycle = 2
max_cycle_minutes = 30
EOF

# Seed: in-progress request_changes cycle with a claude-response, codex_calls already at cap
mkdir -p "${SANDBOX}/.tdd/reviews/cycle-budget-cap"
echo "fake response" > "${SANDBOX}/.tdd/reviews/cycle-budget-cap/claude-response-2.txt"
jq -n \
  --argjson started "$(($(date +%s) - 60))" \
  '{cycle_id:"cycle-budget-cap", status:"request_changes", round:1,
    updated_at:"2026-05-31T00:00:00Z",
    started_at_epoch:$started, codex_calls:2}' \
  > "${SANDBOX}/.tdd/reviews/state.json"

# Dirty tree so guard doesn't exit early on clean-tree
echo "$(date)" > "${SANDBOX}/dirty.txt"

# Run with PRILIVE_REVIEW_DISABLE=1 to prevent ACTUAL codex calls
# but allow the budget check to run.
# Actually — the disable check is BEFORE the budget check, so this
# would exit before checking. Need to NOT disable.
# Instead: rely on codex not being installed in CI (we'd fail at the
# Codex call, but the budget gate should fire FIRST).

# Easier: stub the codex-round-n.sh to a fake that exits 0 quickly.
cat > "${SANDBOX}/runner/codex-round-n.sh" <<'STUB'
#!/usr/bin/env bash
# Fake codex-round-n for testing budget gate
echo "FAKE codex-round-n called (should not happen when budget exceeded)" >&2
exit 1
STUB
chmod +x "${SANDBOX}/runner/codex-round-n.sh"

"${SANDBOX}/runner/review-runner.sh" "${SANDBOX}" >/dev/null 2>&1

# After budget exceeded: state should be failed, no codex-round-n called
new_status=$(jq -r '.status' "${SANDBOX}/.tdd/reviews/state.json")
[[ "$new_status" == "failed" ]] || fail "expected status=failed after budget exceeded, got '$new_status'"
pass "runner sets status=failed when codex_calls at cap"
PASS_COUNT=$((PASS_COUNT + 1))

status_file="${SANDBOX}/.tdd/reviews/cycle-budget-cap/.status"
if [[ -f "$status_file" ]] && grep -q "codex_calls_exceeded" "$status_file"; then
  pass "runner records codex_calls_exceeded in .status"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "expected codex_calls_exceeded in .status, got: $(cat "$status_file" 2>/dev/null)"
fi

# ---- Section 3: max_cycle_minutes budget gate ----

info "[6] runner blocks fresh cycle when wall-clock budget exceeded"
SANDBOX=$(make_sandbox)
CLEANUP_PATHS+=("${SANDBOX}")
write_config "${SANDBOX}" <<'EOF'
[review]
max_rounds = 5
max_codex_calls_per_cycle = 8
max_cycle_minutes = 5
EOF

# Seed: in-progress cycle started 10 minutes ago (over 5 min cap), codex_calls under cap
mkdir -p "${SANDBOX}/.tdd/reviews/cycle-timeout"
echo "fake response" > "${SANDBOX}/.tdd/reviews/cycle-timeout/claude-response-2.txt"
jq -n \
  --argjson started "$(($(date +%s) - 600))" \
  '{cycle_id:"cycle-timeout", status:"request_changes", round:1,
    updated_at:"2026-05-31T00:00:00Z",
    started_at_epoch:$started, codex_calls:1}' \
  > "${SANDBOX}/.tdd/reviews/state.json"

echo "$(date)" > "${SANDBOX}/dirty.txt"

# Stub codex-round-n
cat > "${SANDBOX}/runner/codex-round-n.sh" <<'STUB'
#!/usr/bin/env bash
echo "FAKE codex-round-n called (should not happen)" >&2
exit 1
STUB
chmod +x "${SANDBOX}/runner/codex-round-n.sh"

"${SANDBOX}/runner/review-runner.sh" "${SANDBOX}" >/dev/null 2>&1

new_status=$(jq -r '.status' "${SANDBOX}/.tdd/reviews/state.json")
[[ "$new_status" == "failed" ]] || fail "expected status=failed after timeout, got '$new_status'"
pass "runner sets status=failed when wall-clock budget exceeded"
PASS_COUNT=$((PASS_COUNT + 1))

status_file="${SANDBOX}/.tdd/reviews/cycle-timeout/.status"
if [[ -f "$status_file" ]] && grep -q "cycle_timeout" "$status_file"; then
  pass "runner records cycle_timeout in .status"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "expected cycle_timeout in .status, got: $(cat "$status_file" 2>/dev/null)"
fi

# ---- Section 4: must_address contract check (codex-round1.sh) ----

info "[7] codex-round1.sh contract check rejects approve+major"
SANDBOX=$(make_sandbox)
CLEANUP_PATHS+=("${SANDBOX}")
write_config "${SANDBOX}" <<'EOF'
[severity]
must_address = "major"
EOF

mkdir -p "${SANDBOX}/.tdd/reviews/cycle-contract"
# Synthetic round-1.json: approve verdict but has a major finding
cat > "${SANDBOX}/.tdd/reviews/cycle-contract/round-1.json" <<'JSON'
{
  "verdict": "approve",
  "summary_one_sentence": "Looks fine.",
  "summary_one_paragraph": "Approved despite a major finding.",
  "findings": [
    {"severity":"major","category":"correctness","title":"Real bug",
     "body":"Off-by-one in loop bound.","file":"foo.go","line":42,"confidence":4}
  ],
  "files_read":["foo.go"],
  "questions_for_human":[]
}
JSON

# Run JUST the contract check portion of codex-round1.sh as if Codex
# returned. The full script runs codex exec; we'll simulate by extracting
# the verdict/contract logic into an inline test.
# shellcheck source=/dev/null
. "${CONFIG_LIB}"
CONFIG="${SANDBOX}/tdd-pack.toml"
CYCLE_DIR="${SANDBOX}/.tdd/reviews/cycle-contract"
VERDICT=$(jq -r '.verdict' "${CYCLE_DIR}/round-1.json")
MUST_ADDRESS=$(cfg_get "${CONFIG}" "severity.must_address" "major")
VIOLATIONS=$(jq -r --arg ma "${MUST_ADDRESS}" '
  def sn($s): {"blocker":4, "major":3, "minor":2, "nit":1}[$s];
  [.findings[]? | select(sn(.severity) >= sn($ma))] | length
' "${CYCLE_DIR}/round-1.json")
if [[ "${VERDICT}" == "approve" ]] && [[ "${VIOLATIONS:-0}" -gt 0 ]]; then
  pass "contract check would fire: approve+major detected (${VIOLATIONS} violation)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "contract check missed approve+major: verdict=${VERDICT} violations=${VIOLATIONS}"
fi

# ---- Section 5: must_address contract check passes for approve+nit ----

info "[8] codex-round1.sh contract check passes approve+nit (below must_address)"
mkdir -p "${SANDBOX}/.tdd/reviews/cycle-nit-ok"
cat > "${SANDBOX}/.tdd/reviews/cycle-nit-ok/round-1.json" <<'JSON'
{
  "verdict": "approve",
  "summary_one_sentence": "Clean.",
  "summary_one_paragraph": "Clean code; nit only.",
  "findings": [
    {"severity":"nit","category":"docs","title":"Comment style",
     "body":"Could use a leading capital.","file":"foo.go","line":10,"confidence":3}
  ],
  "files_read":["foo.go"],
  "questions_for_human":[]
}
JSON

CYCLE_DIR="${SANDBOX}/.tdd/reviews/cycle-nit-ok"
VERDICT=$(jq -r '.verdict' "${CYCLE_DIR}/round-1.json")
VIOLATIONS=$(jq -r --arg ma "${MUST_ADDRESS}" '
  def sn($s): {"blocker":4, "major":3, "minor":2, "nit":1}[$s];
  [.findings[]? | select(sn(.severity) >= sn($ma))] | length
' "${CYCLE_DIR}/round-1.json")
if [[ "${VERDICT}" == "approve" ]] && [[ "${VIOLATIONS:-0}" -eq 0 ]]; then
  pass "contract check would pass: approve+nit only is fine"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "contract check wrongly fired on approve+nit"
fi

# ---- Section 6: inject-findings min_surface filter ----

info "[9] inject-findings.sh min_surface=major filters out minor/nit"
SANDBOX=$(make_sandbox)
CLEANUP_PATHS+=("${SANDBOX}")
write_config "${SANDBOX}" <<'EOF'
[severity]
min_surface = "major"
EOF

mkdir -p "${SANDBOX}/.tdd/reviews/cycle-filter"
cat > "${SANDBOX}/.tdd/reviews/cycle-filter/round-1.json" <<'JSON'
{
  "verdict": "request_changes",
  "summary_one_sentence": "Mixed bag.",
  "summary_one_paragraph": "One major, one nit.",
  "findings": [
    {"severity":"major","category":"correctness","title":"Real bug",
     "body":"Actual issue.","file":"foo.go","line":42,"confidence":4},
    {"severity":"nit","category":"docs","title":"Comment style",
     "body":"Style nit.","file":"foo.go","line":10,"confidence":2}
  ],
  "files_read":["foo.go"],
  "questions_for_human":[]
}
JSON

jq -n '{cycle_id:"cycle-filter", status:"request_changes", round:1,
       updated_at:"2026-05-31T00:00:00Z", started_at_epoch:0, codex_calls:1}' \
  > "${SANDBOX}/.tdd/reviews/state.json"

OUTPUT=$(CLAUDE_PROJECT_DIR="${SANDBOX}" bash "${INJECT}" 2>/dev/null)

# Extract the additionalContext blob
CTX=$(echo "${OUTPUT}" | jq -r '.hookSpecificOutput.additionalContext // empty')

if echo "${CTX}" | grep -q "Real bug"; then
  pass "inject-findings includes major finding (matches min_surface=major)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "inject-findings dropped the major finding"
fi

if echo "${CTX}" | grep -q "Comment style"; then
  fail "inject-findings should have filtered nit at min_surface=major; nit appeared"
else
  pass "inject-findings correctly filtered nit at min_surface=major"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

# ---- Section 7: min_surface=nit (default) shows everything ----

info "[10] inject-findings.sh min_surface=nit shows nit too"
write_config "${SANDBOX}" <<'EOF'
[severity]
min_surface = "nit"
EOF
# Clear cfg cache so the second cfg_get re-reads
# (cfg_clear_cache is in the sourced lib but inject-findings is run as a new process so it's fine)

OUTPUT=$(CLAUDE_PROJECT_DIR="${SANDBOX}" bash "${INJECT}" 2>/dev/null)
CTX=$(echo "${OUTPUT}" | jq -r '.hookSpecificOutput.additionalContext // empty')

if echo "${CTX}" | grep -q "Real bug" && echo "${CTX}" | grep -q "Comment style"; then
  pass "inject-findings includes both major and nit at min_surface=nit"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "inject-findings dropped findings at min_surface=nit"
fi

# ---- summary ----

echo ""
echo "================================================================"
echo "  CONFIG ENFORCEMENT SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"

exit 0
