#!/usr/bin/env bash
# test/smoke-grounding-demotion.sh
#
# v2.1 PR 2 — verify the tool-grounding demotion logic in
# hooks/inject-findings.sh (spec §5.1).
#
# Covers:
#   1. contradicts_grounding=false → finding shows in the must-address
#      section as expected.
#   2. contradicts_grounding=true on a demotable category (style,
#      maintainability, docs) → finding moves to the speculative section,
#      NOT must-address.
#   3. CARVE-OUT: contradicts_grounding=true on a never-demote category
#      (correctness, design, test_quality, security, safety, data_loss,
#      blast_radius) → finding STAYS in must-address regardless.
#   4. Multiple findings mix: some promoted, some demoted, sections
#      rendered correctly.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${PROJECT_ROOT}/hooks/inject-findings.sh"

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

# Build a sandbox with .tdd/reviews/<cycle>/round-1.json + state.json,
# plus the runner/lib/config.sh symlinked so the hook can read its
# severity.min_surface knob.
make_sandbox() {
  local cycle_id="$1" findings_json="$2"
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.tdd/reviews/$cycle_id" "$d/runner/lib"
  cp "${PROJECT_ROOT}/runner/lib/config.sh" "$d/runner/lib/"
  # Default sandbox config: low floors so demotions only fire when
  # explicitly triggered by the rails being tested.
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

# Helper: build a finding JSON object.
mk_finding() {
  local severity="$1" category="$2" title="$3" contradicts="$4" confidence="${5:-4}"
  jq -nc \
    --arg s "$severity" --arg c "$category" --arg t "$title" \
    --argjson cg "$contradicts" --argjson conf "$confidence" \
    '{severity:$s, category:$c, title:$t, body:"…",
      file:"x.go", line:1, confidence:$conf,
      contradicts_grounding:$cg}'
}

# Run the hook and return the rendered additionalContext text.
run_hook_get_context() {
  local sandbox="$1"
  CLAUDE_PROJECT_DIR="$sandbox" bash "$HOOK" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
}

# ---- case 1: vanilla finding (contradicts_grounding=false) → promoted ----

info "[1] contradicts_grounding=false → finding lands in must-address section"
FIND=$(mk_finding "major" "correctness" "real bug" "false")
SANDBOX=$(make_sandbox "cycle-1" "[$FIND]"); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_hook_get_context "$SANDBOX")
[[ "$OUT" == *"Findings:"* ]]                || fail "case 1: missing Findings: section"
[[ "$OUT" == *"real bug"* ]]                 || fail "case 1: finding title not rendered"
[[ "$OUT" != *"Speculative (demoted;"* ]]     || fail "case 1: should not have demoted section"
pass "vanilla finding: rendered in main Findings section"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 2: demotable category + grounding=true → demoted ----

info "[2] contradicts_grounding=true on maintainability → demoted section"
FIND=$(mk_finding "major" "maintainability" "style nit on clean file" "true")
SANDBOX=$(make_sandbox "cycle-2" "[$FIND]"); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_hook_get_context "$SANDBOX")
[[ "$OUT" == *"Speculative (demoted;"* ]]     || fail "case 2: missing Speculative section"
[[ "$OUT" == *"style nit on clean file"* ]]  || fail "case 2: finding not rendered in any section"
# Confirm it's NOT in the must-address section.
PROMOTED_SECTION=$(echo "$OUT" | awk '/^Findings:/,/^Speculative/{print}')
[[ "$PROMOTED_SECTION" == *"(no findings at or above"* ]] || fail "case 2: must-address section should report empty; got: $PROMOTED_SECTION"
pass "maintainability + grounding=true: demoted to Speculative section, not blocking"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 3: CARVE-OUT — never-demote category stays promoted ----

info "[3] CARVE-OUT: contradicts_grounding=true on correctness → STAYS in must-address"
FIND=$(mk_finding "major" "correctness" "semantic nil deref tools cannot see" "true")
SANDBOX=$(make_sandbox "cycle-3" "[$FIND]"); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_hook_get_context "$SANDBOX")
[[ "$OUT" == *"semantic nil deref"* ]]       || fail "case 3: finding missing"
[[ "$OUT" != *"Speculative (demoted;"* ]]     || fail "case 3: should NOT have demoted section (carve-out)"
# Confirm it's in the promoted section.
[[ "$OUT" == *"Findings:"*"semantic nil deref"* ]] || fail "case 3: finding not in Findings: section"
pass "correctness carve-out: contradicts_grounding ignored, finding stays in must-address"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 4: carve-out covers ALL never-demote categories ----

info "[4] CARVE-OUT: all never-demote categories stay promoted under grounding=true"
for cat in correctness design test_quality security; do
  FIND=$(mk_finding "major" "$cat" "semantic finding in $cat" "true")
  SANDBOX=$(make_sandbox "cycle-4-$cat" "[$FIND]"); CLEANUP_PATHS+=("$SANDBOX")
  OUT=$(run_hook_get_context "$SANDBOX")
  [[ "$OUT" != *"Speculative (demoted;"* ]] || fail "case 4 ($cat): carve-out failed — finding was demoted"
  [[ "$OUT" == *"semantic finding in $cat"* ]] || fail "case 4 ($cat): finding missing"
done
pass "carve-out works for correctness, design, test_quality, security"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 5: mixed — promoted + demoted in same review ----

info "[5] mixed findings: one promoted, one demoted → both sections rendered"
F1=$(mk_finding "major" "correctness" "real bug" "false")
F2=$(mk_finding "major" "maintainability" "tool-clean style nit" "true")
SANDBOX=$(make_sandbox "cycle-5" "[$F1, $F2]"); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_hook_get_context "$SANDBOX")
[[ "$OUT" == *"real bug"* ]]                 || fail "case 5: promoted finding missing"
[[ "$OUT" == *"tool-clean style nit"* ]]     || fail "case 5: demoted finding missing"
[[ "$OUT" == *"Speculative (demoted;"* ]]     || fail "case 5: demoted section missing"
# The promoted finding should appear in the main Findings: block (before Speculative).
ORDER=$(echo "$OUT" | awk '/real bug/{print "real"; exit} /tool-clean/{print "tool"; exit}')
[[ "$ORDER" == "real" ]] || fail "case 5: promoted finding should appear before demoted; got order: $ORDER"
pass "mixed: promoted in must-address, demoted in Speculative, ordering correct"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 6: demotable category + grounding=true + grounding=false → only demoted is filtered ----

info "[6] mixed grounding on same category: false stays promoted, true gets demoted"
F1=$(mk_finding "major" "maintainability" "kept as real" "false")
F2=$(mk_finding "major" "maintainability" "speculative one" "true")
SANDBOX=$(make_sandbox "cycle-6" "[$F1, $F2]"); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_hook_get_context "$SANDBOX")
[[ "$OUT" == *"kept as real"* ]]             || fail "case 6: false-grounding finding missing from main"
[[ "$OUT" == *"speculative one"* ]]          || fail "case 6: true-grounding finding missing from demoted"
[[ "$OUT" == *"Speculative (demoted;"* ]]     || fail "case 6: missing Speculative section"
# 'kept as real' must NOT appear in the Speculative section.
DEMOTED_SECTION=$(echo "$OUT" | awk '/Speculative/,/What to do next/{print}')
[[ "$DEMOTED_SECTION" != *"kept as real"* ]] || fail "case 6: false-grounding finding leaked into Speculative"
pass "same category, different grounding: each routed correctly"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# v2.1 PR 3 — confidence axis (Rail B)
# ============================================================
#
# Helper: a sandbox with a specific confidence_floor set.
make_sandbox_with_floor() {
  local cycle_id="$1" findings_json="$2" floor="$3"
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.tdd/reviews/$cycle_id" "$d/runner/lib"
  cp "${PROJECT_ROOT}/runner/lib/config.sh" "$d/runner/lib/"
  cat > "$d/tdd-pack.toml" <<TOML
[severity]
min_surface = "nit"
confidence_floor = ${floor}
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

# ---- case 7: confidence=4 at floor=4 → promoted ----

info "[7] confidence=4 == floor → promoted (at the boundary)"
FIND=$(mk_finding "major" "correctness" "boundary case" "false" 4)
SANDBOX=$(make_sandbox_with_floor "cycle-7" "[$FIND]" 4); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_hook_get_context "$SANDBOX")
[[ "$OUT" == *"boundary case"* ]]            || fail "case 7: finding missing"
[[ "$OUT" != *"Speculative (demoted;"* ]]    || fail "case 7: should not be demoted at floor"
pass "confidence=4 at floor=4: promoted (boundary inclusive)"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 8: confidence=3 with floor=4 → demoted ----

info "[8] confidence=3 < floor=4 → demoted to Speculative"
FIND=$(mk_finding "major" "correctness" "likely-but-not-verified" "false" 3)
SANDBOX=$(make_sandbox_with_floor "cycle-8" "[$FIND]" 4); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_hook_get_context "$SANDBOX")
[[ "$OUT" == *"likely-but-not-verified"* ]]  || fail "case 8: finding missing"
[[ "$OUT" == *"Speculative (demoted;"* ]]    || fail "case 8: should be in Speculative section"
[[ "$OUT" == *"low-confidence c=3"* ]]       || fail "case 8: demotion reason missing"
# Should NOT be in promoted section.
[[ "$OUT" == *"(no findings at or above"* ]] || fail "case 8: promoted section should be empty; got: $OUT"
pass "confidence=3 with floor=4: demoted with explicit reason"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 9: confidence=1 blocker → still demoted (confidence axis trumps severity) ----

info "[9] confidence=1 BLOCKER with floor=4 → demoted (confidence floor applies regardless of severity)"
FIND=$(mk_finding "blocker" "correctness" "wild guess at blocker severity" "false" 1)
SANDBOX=$(make_sandbox_with_floor "cycle-9" "[$FIND]" 4); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_hook_get_context "$SANDBOX")
[[ "$OUT" == *"wild guess"* ]]               || fail "case 9: finding missing"
[[ "$OUT" == *"Speculative (demoted;"* ]]    || fail "case 9: blocker+low-conf should still be demoted"
[[ "$OUT" == *"low-confidence c=1"* ]]       || fail "case 9: demotion reason missing"
pass "confidence floor trumps severity: blocker+c=1 demoted to Speculative"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 10: BOTH rails demote → reason shows compound tag ----

info "[10] both rails fire (low confidence AND tool-clean) → compound reason"
FIND=$(mk_finding "major" "maintainability" "double-demoted" "true" 2)
SANDBOX=$(make_sandbox_with_floor "cycle-10" "[$FIND]" 4); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_hook_get_context "$SANDBOX")
[[ "$OUT" == *"double-demoted"* ]]                 || fail "case 10: finding missing"
[[ "$OUT" == *"tool-clean + low-confidence"* ]]    || fail "case 10: compound reason missing"
pass "both rails fire: compound demotion reason rendered"
PASS_COUNT=$((PASS_COUNT+1))

# ---- case 11: high floor (5) suppresses confidence-4 findings ----

info "[11] adopter sets floor=5 (verified only) → confidence=4 findings demoted"
FIND=$(mk_finding "major" "correctness" "high-static-only" "false" 4)
SANDBOX=$(make_sandbox_with_floor "cycle-11" "[$FIND]" 5); CLEANUP_PATHS+=("$SANDBOX")
OUT=$(run_hook_get_context "$SANDBOX")
[[ "$OUT" == *"high-static-only"* ]]           || fail "case 11: finding missing"
[[ "$OUT" == *"Speculative (demoted;"* ]]      || fail "case 11: should be demoted at higher floor"
[[ "$OUT" == *"low-confidence c=4"* ]]         || fail "case 11: demotion reason missing"
pass "adopter raised floor=5: confidence=4 finding correctly demoted"
PASS_COUNT=$((PASS_COUNT+1))

# ---- summary ----

echo ""
echo "================================================================"
echo "  GROUNDING DEMOTION SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
exit 0
