#!/usr/bin/env bash
# test/smoke-prompt-content.sh
#
# Mechanical content checks for the reviewer prompts. Prevents
# accidental removal of the load-bearing rules added in sub-piece #5:
#   - "No issues found" / concede / valued outcome  (anti-sycophancy)
#   - tool-grounding-evidence / demote               (anti-speculation)
#   - max_rounds default value                       (config coupling)
#
# Failure here means a maintainer removed a sub-piece-#5 rule without
# replacing it. Re-add the rule or update this test, but don't silently
# drop it.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
PASS_COUNT=0

require_phrase() {
  local file="$1" pattern="$2" label="$3"
  # Flatten the file to one line + squeeze runs of whitespace so phrases
  # split across wrapped paragraphs (with leading indent on the next
  # line) match regexes that expect a single space.
  if tr -s '[:space:]' ' ' < "${file}" | grep -qE "${pattern}"; then
    pass "${label}: '${pattern}'"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    fail "${label}: missing pattern '${pattern}' in ${file}"
  fi
}

info "[1] prompts/codex-system.md — anti-sycophancy + evidence rules"
SYS="${PROJECT_ROOT}/prompts/codex-system.md"

# v2.1 PR 4: line_scope rule documented in system prompt
require_phrase "${SYS}" 'line_scope' "codex-system mentions line_scope field"
require_phrase "${SYS}" 'pre_existing_unrelated|pre-existing.*unrelated' "codex-system enumerates the pre_existing_unrelated value"
require_phrase "${SYS}" 'change_triggered_context' "codex-system enumerates change_triggered_context value"
require_phrase "${SYS}" 'NEVER drive must-address' "codex-system spells out the never-blocks rule for pre_existing_unrelated"

# v2.1 PR 4: round-1 user template has the CHANGED/CONTEXT delimiters
info "[1b] prompts/codex-round1-user.md — CHANGED / CONTEXT delimiters"
ROUND1="${PROJECT_ROOT}/prompts/codex-round1-user.md"
require_phrase "${ROUND1}" 'CHANGED.*review and flag' "round1 user prompt has CHANGED block"
require_phrase "${ROUND1}" 'CONTEXT.*do not flag pre-existing' "round1 user prompt has CONTEXT block"
require_phrase "${ROUND1}" 'line_scope' "round1 user prompt references line_scope"

# v2.1 PR 5: round-N user template is verify-only
info "[1c] prompts/codex-round-n-user.md — verify-only mode"
ROUNDN="${PROJECT_ROOT}/prompts/codex-round-n-user.md"
require_phrase "${ROUNDN}" 'VERIFY-ONLY MODE' "round-n user prompt declares verify-only mode"
require_phrase "${ROUNDN}" 'verify_disposition' "round-n user prompt uses verify_disposition vocabulary"
require_phrase "${ROUNDN}" 'resolved.*not_resolved.*regressed.*new_fix_introduced_issue|new_fix_introduced_issue' "round-n enumerates the four dispositions"
require_phrase "${ROUNDN}" 'You may open a NEW finding.*ONLY when all three hold|confirmed regression.*caused by Claude.s fix' "round-n new-finding gate (three conditions)"
require_phrase "${ROUNDN}" 'sycophancy theatre|sycophancy-theatre' "round-n preserves the concession framing"
require_phrase "${SYS}"    'Round N>1 verify-only' "codex-system documents the round-N rail"
require_phrase "${SYS}" 'no issues found.*correct.*valued outcome|valued outcome.*no issues found' "codex-system 'no issues found is valued'"
require_phrase "${SYS}" 'Concede when the code is correct' "codex-system concession rule"
require_phrase "${SYS}" 'Demote findings without tool-grounding evidence' "codex-system demote-without-evidence rule"
require_phrase "${SYS}" 'sycophancy theatre|sycophancy-theatre' "codex-system sycophancy-theatre call-out"

info "[2] prompts/codex-pre-review-system.md — same rules, pre-review path"
PRE="${PROJECT_ROOT}/prompts/codex-pre-review-system.md"
require_phrase "${PRE}" 'No issues found.*correct' "pre-review 'no issues found is correct'"
require_phrase "${PRE}" 'Concede when the change is correct' "pre-review concession rule"
require_phrase "${PRE}" 'Demote findings without tool-grounding evidence' "pre-review demote-without-evidence rule"
# v2.1: confirm the system prompt is scoped to file_change only — the bash
# classification rules ("read-only vs state-changing") were removed when the
# Bash matcher was retired from the starter pack.
require_phrase "${PRE}" 'file_change.*only.*runtime command safety|runtime command safety.*out of scope' "pre-review scope is file_change only (Bash removed)"

# v2.1 PR 2: contradicts_grounding rule + carve-out
info "[2b] prompts have the contradicts_grounding rule (v2.1 PR 2)"
require_phrase "${SYS}" 'contradicts_grounding' "codex-system mentions contradicts_grounding flag"
require_phrase "${SYS}" 'NEVER set .*contradicts_grounding.*true.*correctness|correctness.*NEVER' "codex-system carve-out for correctness"
require_phrase "${SYS}" 'compiled or generated artifact|resolved artifact' "codex-system verify-override-claims rule"
require_phrase "${PRE}" 'contradicts_grounding' "pre-review mentions contradicts_grounding flag"
require_phrase "${PRE}" 'NEVER set .*contradicts_grounding.*true.*safety|safety.*correctness.*data_loss' "pre-review carve-out enumerated"

info "[3] tdd-pack.toml — max_rounds default = 4"
TOML="${PROJECT_ROOT}/tdd-pack.toml"
ACTUAL=$(awk -F' = ' '/^max_rounds =/ {gsub(/ /,"",$2); print $2; exit}' "${TOML}")
[[ "${ACTUAL}" == "4" ]] || fail "tdd-pack.toml max_rounds expected 4, got '${ACTUAL}'"
pass "tdd-pack.toml max_rounds = 4"
PASS_COUNT=$((PASS_COUNT + 1))

require_phrase "${TOML}" '\[pre_review\]'        "tdd-pack.toml has [pre_review] section"
require_phrase "${TOML}" 'enabled = (true|false)' "tdd-pack.toml [pre_review] has enabled field"
require_phrase "${TOML}" 'Off by default'        "tdd-pack.toml documents the shipped default is off (intent, not current value)"
require_phrase "${TOML}" 'Activation precedence' "tdd-pack.toml documents precedence order"

# v2.1 PR 3: confidence_floor knob in [severity]
require_phrase "${TOML}" 'confidence_floor = [0-9]'    "tdd-pack.toml [severity] has confidence_floor knob"
require_phrase "${TOML}" 'SECOND axis after severity|second axis after severity'  "tdd-pack.toml documents confidence as the second axis"

info "[4] runner fallback defaults match shipped config"
for f in "${PROJECT_ROOT}/runner/review-runner.sh" "${PROJECT_ROOT}/runner/codex-round-n.sh"; do
  if grep -qE 'cfg_get.*review.max_rounds.*"4"' "${f}"; then
    pass "$(basename "${f}") cfg_get fallback = 4"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    fail "$(basename "${f}") cfg_get fallback does not match tdd-pack.toml (expected \"4\")"
  fi
done

info "[5] README.md — pre-write gate ceiling section (scope: file changes only post-v2.1)"
README="${PROJECT_ROOT}/README.md"
require_phrase "${README}" 'What the gate does NOT cover'      "README ceiling heading"
require_phrase "${README}" 'code changes, not commands'        "README scope-is-file-changes message"
require_phrase "${README}" 'v2.1 removed the Bash matcher'     "README documents Bash matcher removal"
require_phrase "${README}" 'devopspoint|runtime-safety|sibling plugin' "README points to a sibling runtime-safety tool"
require_phrase "${README}" 'OS-level audit|seccomp|eBPF|auditd' "README OS-level mitigation"
require_phrase "${README}" 'Out-of-band|out-of-band|bypasses Claude.s tool API' "README out-of-band changes class"

info "[6] docs/ADOPTION_GUIDE.md — extended ceiling discussion"
GUIDE="${PROJECT_ROOT}/docs/ADOPTION_GUIDE.md"
require_phrase "${GUIDE}" 'Architectural ceiling'              "GUIDE ceiling heading"
require_phrase "${GUIDE}" 'file changes, not commands'         "GUIDE scope statement"
require_phrase "${GUIDE}" 'v2.1 removed the Bash matcher'      "GUIDE documents Bash matcher removal"
require_phrase "${GUIDE}" 'devopspoint|sibling plugin'         "GUIDE points to sibling runtime-safety tool"
require_phrase "${GUIDE}" 'outside Claude.s tool API'          "GUIDE out-of-band class"
require_phrase "${GUIDE}" 'seccomp|eBPF|auditd'                "GUIDE OS-level mitigation"

echo ""
echo "================================================================"
echo "  PROMPT CONTENT SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
exit 0
