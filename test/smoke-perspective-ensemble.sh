#!/usr/bin/env bash
# test/smoke-perspective-ensemble.sh
#
# v2.1 PR 9 — perspective-diverse infrastructure (spec §6 consensus).
# Tests the consumer side: tier1 detector + Rail D singleton-demotion
# in inject-findings.sh. The producer (real parallel codex invocation)
# is PR 9b.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${PROJECT_ROOT}/hooks/inject-findings.sh"
TIER1_LIB="${PROJECT_ROOT}/runner/lib/tier1.sh"

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

# Sandbox for inject-findings tests: has .tdd/reviews/<cycle>/round-1.json
# + state.json + runner/lib/config.sh + tdd-pack.toml.
make_inject_sandbox() {
  local cycle_id="$1" findings_json="$2"
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.tdd/reviews/$cycle_id" "$d/runner/lib"
  cp "${PROJECT_ROOT}/runner/lib/config.sh" "$d/runner/lib/"
  cat > "$d/tdd-pack.toml" <<'TOML'
[severity]
min_surface = "nit"
confidence_floor = 1
TOML
  cat > "$d/.tdd/reviews/state.json" <<JSON
{"cycle_id":"$cycle_id","status":"request_changes","round":1,"updated_at":"2026-06-03T00:00:00Z","started_at_epoch":1748908800,"codex_calls":1}
JSON
  cat > "$d/.tdd/reviews/$cycle_id/round-1.json" <<JSON
{
  "verdict": "request_changes",
  "summary_one_sentence": "test fixture",
  "summary_one_paragraph": "test fixture",
  "findings": $findings_json,
  "files_read": [],
  "questions_for_human": []
}
JSON
  echo "$d"
}

# Build a finding tagged with a specific angle.
mk_finding_angle() {
  local severity="$1" category="$2" title="$3" angle="$4" file="${5:-x.go}" line="${6:-1}"
  jq -nc \
    --arg s "$severity" --arg c "$category" --arg t "$title" \
    --arg a "$angle" --arg f "$file" --argjson ln "$line" \
    '{severity:$s, category:$c, title:$t, body:"…",
      file:$f, line:$ln, confidence:5,
      contradicts_grounding:false, line_scope:"changed_line",
      raised_by_angle:$a}'
}

# Build a single-reviewer finding (no angle tag).
mk_finding_default() {
  local severity="$1" category="$2" title="$3"
  jq -nc \
    --arg s "$severity" --arg c "$category" --arg t "$title" \
    '{severity:$s, category:$c, title:$t, body:"…",
      file:"x.go", line:1, confidence:5,
      contradicts_grounding:false, line_scope:"changed_line"}'
}

run_hook_get_context() {
  local sandbox="$1"
  CLAUDE_PROJECT_DIR="$sandbox" bash "$HOOK" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
}

# ============================================================
# tier1 detector
# ============================================================

info "[1] tier1_config_present: false when tiers.toml absent"
SANDBOX=$(mktemp -d); CLEANUP_PATHS+=("$SANDBOX")
(
  # shellcheck source=/dev/null
  . "$TIER1_LIB"
  tier1_config_present "$SANDBOX" && exit 1
  exit 0
) || fail "case 1: should return 1 when tiers.toml absent"
pass "tier1_config_present: false without tiers.toml"
PASS_COUNT=$((PASS_COUNT+1))

info "[2] tier1_match_path: matches path_globs"
SANDBOX=$(mktemp -d); CLEANUP_PATHS+=("$SANDBOX")
mkdir -p "$SANDBOX/.tdd"
cat > "$SANDBOX/.tdd/tiers.toml" <<'TOML'
[tier1]
path_globs = [
  "internal/security/**",
  "migrations/**",
  "internal/auth/*.go",
]
TOML
(
  # shellcheck source=/dev/null
  . "$TIER1_LIB"
  tier1_match_path "internal/security/auth.go" "$SANDBOX"     || { echo "case 2a fail"; exit 1; }
  tier1_match_path "internal/security/foo/bar.go" "$SANDBOX"  || { echo "case 2b fail"; exit 1; }
  tier1_match_path "migrations/0001.sql" "$SANDBOX"           || { echo "case 2c fail"; exit 1; }
  tier1_match_path "internal/auth/login.go" "$SANDBOX"        || { echo "case 2d fail"; exit 1; }
  tier1_match_path "internal/auth/sub/x.go" "$SANDBOX"        && { echo "case 2e: nested under single-* should NOT match"; exit 1; }
  tier1_match_path "README.md" "$SANDBOX"                     && { echo "case 2f: README should not match"; exit 1; }
  tier1_match_path "cmd/main.go" "$SANDBOX"                   && { echo "case 2g: cmd/ should not match"; exit 1; }
  exit 0
) || fail "case 2: glob matching broken"
pass "tier1_match_path: ** matches recursively, * matches single component, non-matching paths excluded"
PASS_COUNT=$((PASS_COUNT+1))

info "[3] tier1_match_path: allow_globs overrides path_globs"
SANDBOX=$(mktemp -d); CLEANUP_PATHS+=("$SANDBOX")
mkdir -p "$SANDBOX/.tdd"
cat > "$SANDBOX/.tdd/tiers.toml" <<'TOML'
[tier1]
path_globs = ["internal/security/**"]
allow_globs = ["internal/security/internal_tooling/**"]
TOML
(
  # shellcheck source=/dev/null
  . "$TIER1_LIB"
  tier1_match_path "internal/security/auth.go" "$SANDBOX"                          || { echo "case 3a fail"; exit 1; }
  tier1_match_path "internal/security/internal_tooling/build.go" "$SANDBOX"        && { echo "case 3b: allow override should exclude"; exit 1; }
  exit 0
) || fail "case 3: allow override broken"
pass "tier1_match_path: allow_globs excludes matched paths from Tier 1"
PASS_COUNT=$((PASS_COUNT+1))

info "[4] tier1_any_match: ≥1 path in set triggers Tier-1"
SANDBOX=$(mktemp -d); CLEANUP_PATHS+=("$SANDBOX")
mkdir -p "$SANDBOX/.tdd"
cat > "$SANDBOX/.tdd/tiers.toml" <<'TOML'
[tier1]
path_globs = ["internal/security/**"]
TOML
(
  # shellcheck source=/dev/null
  . "$TIER1_LIB"
  paths="README.md
cmd/main.go
internal/security/auth.go"
  tier1_any_match "$paths" "$SANDBOX" || { echo "case 4a: should match"; exit 1; }
  paths="README.md
cmd/main.go"
  tier1_any_match "$paths" "$SANDBOX" && { echo "case 4b: should NOT match"; exit 1; }
  exit 0
) || fail "case 4: any-match logic broken"
pass "tier1_any_match: detects ≥1 Tier-1 path in a set"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# Rail D — singleton demotion in inject-findings.sh
# ============================================================

info "[5] consensus (2 angles same file:line) → both findings promoted"
F1=$(mk_finding_angle "major" "security" "auth bypass — security view"   "security"    "auth.go" 42)
F2=$(mk_finding_angle "major" "correctness" "auth bypass — logic view"   "correctness" "auth.go" 42)
SANDBOX=$(make_inject_sandbox "cycle-5" "[$F1, $F2]"); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_hook_get_context "$SANDBOX")
[[ "$OUT" == *"auth bypass — security view"* ]]   || fail "case 5: security finding missing"
[[ "$OUT" == *"auth bypass — logic view"* ]]      || fail "case 5: correctness finding missing"
[[ "$OUT" != *"Speculative (demoted;"* ]]         || fail "case 5: consensus should not demote anything"
pass "consensus: 2 angles same file:line → both findings stay in Findings:"
PASS_COUNT=$((PASS_COUNT+1))

info "[6] singleton (security only, no correctness echo) → demoted"
F1=$(mk_finding_angle "major" "security" "security-only concern" "security" "x.go" 99)
SANDBOX=$(make_inject_sandbox "cycle-6" "[$F1]"); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_hook_get_context "$SANDBOX")
[[ "$OUT" == *"security-only concern"* ]]              || fail "case 6: finding missing entirely"
[[ "$OUT" == *"Speculative (demoted;"* ]]              || fail "case 6: singleton should be demoted"
[[ "$OUT" == *"single-angle (security, no consensus)"* ]] || fail "case 6: demotion reason missing"
pass "singleton: security-only at unique file:line → demoted with explicit reason"
PASS_COUNT=$((PASS_COUNT+1))

info "[7] singleton (correctness only, different file:line from security) → demoted"
F1=$(mk_finding_angle "major" "security" "security at A"    "security"    "a.go" 1)
F2=$(mk_finding_angle "major" "correctness" "correctness at B" "correctness" "b.go" 2)
SANDBOX=$(make_inject_sandbox "cycle-7" "[$F1, $F2]"); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_hook_get_context "$SANDBOX")
[[ "$OUT" == *"Speculative (demoted;"* ]]                       || fail "case 7: should demote both singletons"
[[ "$OUT" == *"single-angle (security, no consensus)"* ]]       || fail "case 7: security singleton reason missing"
[[ "$OUT" == *"single-angle (correctness, no consensus)"* ]]    || fail "case 7: correctness singleton reason missing"
pass "both singletons (different file:line): each demoted with own reason"
PASS_COUNT=$((PASS_COUNT+1))

info "[8] default (no raised_by_angle) → NOT subject to Rail D"
# Single-reviewer cycle. Finding has no angle tag. Should be promoted
# regardless of how many other findings exist.
F1=$(mk_finding_default "major" "correctness" "single-reviewer finding")
SANDBOX=$(make_inject_sandbox "cycle-8" "[$F1]"); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_hook_get_context "$SANDBOX")
[[ "$OUT" == *"single-reviewer finding"* ]] || fail "case 8: finding missing"
[[ "$OUT" != *"Speculative (demoted;"* ]]   || fail "case 8: default-angle finding should NOT be demoted by Rail D"
pass "default angle: single-reviewer findings bypass Rail D entirely"
PASS_COUNT=$((PASS_COUNT+1))

info "[9] mix: consensus pair + singleton + default"
F1=$(mk_finding_angle "major" "security" "consensus A"        "security"    "a.go" 1)
F2=$(mk_finding_angle "major" "correctness" "consensus A echo" "correctness" "a.go" 1)
F3=$(mk_finding_angle "major" "security" "lone security"       "security"    "b.go" 2)
F4=$(mk_finding_default "major" "design" "old single-reviewer finding")
SANDBOX=$(make_inject_sandbox "cycle-9" "[$F1, $F2, $F3, $F4]"); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_hook_get_context "$SANDBOX")
# Promoted section should have consensus pair + default finding.
[[ "$OUT" == *"consensus A"* ]]              || fail "case 9: consensus pair missing"
[[ "$OUT" == *"consensus A echo"* ]]         || fail "case 9: consensus echo missing"
[[ "$OUT" == *"old single-reviewer finding"* ]] || fail "case 9: default-angle finding missing"
# Demoted section should have lone security finding.
[[ "$OUT" == *"Speculative (demoted;"* ]]    || fail "case 9: demoted section missing"
[[ "$OUT" == *"lone security"* ]]            || fail "case 9: singleton missing from demoted"
[[ "$OUT" == *"single-angle (security, no consensus)"* ]] || fail "case 9: singleton reason missing"
pass "mixed: consensus pair + default in promoted; singleton in demoted"
PASS_COUNT=$((PASS_COUNT+1))

info "[10] Rail D OVERRIDES the never-demote carve-out (rationale: consensus IS the protection)"
# A correctness (never-demote category) singleton from the security
# lens should still be demoted — the carve-out protects against Rail A
# (tool-grounding), not Rail D (consensus).
F1=$(mk_finding_angle "blocker" "correctness" "lone correctness signal" "security" "x.go" 10)
SANDBOX=$(make_inject_sandbox "cycle-10" "[$F1]"); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_hook_get_context "$SANDBOX")
[[ "$OUT" == *"Speculative (demoted;"* ]]                 || fail "case 10: singleton on correctness should still demote"
[[ "$OUT" == *"single-angle (security, no consensus)"* ]] || fail "case 10: demotion reason missing"
pass "Rail D overrides never-demote carve-out: singleton on correctness still demoted"
PASS_COUNT=$((PASS_COUNT+1))

# ---- summary ----

echo ""
echo "================================================================"
echo "  PERSPECTIVE ENSEMBLE SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
exit 0
