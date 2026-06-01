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
require_phrase "${SYS}" 'no issues found.*correct.*valued outcome|valued outcome.*no issues found' "codex-system 'no issues found is valued'"
require_phrase "${SYS}" 'Concede when the code is correct' "codex-system concession rule"
require_phrase "${SYS}" 'Demote findings without tool-grounding evidence' "codex-system demote-without-evidence rule"
require_phrase "${SYS}" 'sycophancy theatre|sycophancy-theatre' "codex-system sycophancy-theatre call-out"

info "[2] prompts/codex-pre-review-system.md — same rules, pre-review path"
PRE="${PROJECT_ROOT}/prompts/codex-pre-review-system.md"
require_phrase "${PRE}" 'No issues found.*correct' "pre-review 'no issues found is correct'"
require_phrase "${PRE}" 'Concede when the action is correct' "pre-review concession rule"
require_phrase "${PRE}" 'Demote findings without tool-grounding evidence' "pre-review demote-without-evidence rule"
require_phrase "${PRE}" 'read-only|state-changing' "pre-review classification rule still present"
require_phrase "${PRE}" 'Fail-closed rule' "pre-review fail-closed rule still present"

info "[3] tdd-pack.toml — max_rounds default = 4"
TOML="${PROJECT_ROOT}/tdd-pack.toml"
ACTUAL=$(awk -F' = ' '/^max_rounds =/ {gsub(/ /,"",$2); print $2; exit}' "${TOML}")
[[ "${ACTUAL}" == "4" ]] || fail "tdd-pack.toml max_rounds expected 4, got '${ACTUAL}'"
pass "tdd-pack.toml max_rounds = 4"
PASS_COUNT=$((PASS_COUNT + 1))

info "[4] runner fallback defaults match shipped config"
for f in "${PROJECT_ROOT}/runner/review-runner.sh" "${PROJECT_ROOT}/runner/codex-round-n.sh"; do
  if grep -qE 'cfg_get.*review.max_rounds.*"4"' "${f}"; then
    pass "$(basename "${f}") cfg_get fallback = 4"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    fail "$(basename "${f}") cfg_get fallback does not match tdd-pack.toml (expected \"4\")"
  fi
done

info "[5] README.md — pre-write gate ceiling section (sub-piece #6)"
README="${PROJECT_ROOT}/README.md"
require_phrase "${README}" 'What the gate does NOT cover'      "README ceiling heading"
require_phrase "${README}" 'Opaque payloads'                   "README opaque-payloads section"
require_phrase "${README}" 'python -c'                         "README python -c example"
require_phrase "${README}" 'node -e'                           "README node -e example"
require_phrase "${README}" 'ssh host'                          "README ssh-host example"
require_phrase "${README}" 'governed executor|OS-level'        "README mitigation options"

info "[6] docs/ADOPTION_GUIDE.md — extended ceiling discussion"
GUIDE="${PROJECT_ROOT}/docs/ADOPTION_GUIDE.md"
require_phrase "${GUIDE}" 'Architectural ceiling'              "GUIDE ceiling heading"
require_phrase "${GUIDE}" 'Opaque payloads'                    "GUIDE opaque-payloads subsection"
require_phrase "${GUIDE}" 'fail closed on opaque wrappers|fail-closed on opaque' "GUIDE fail-closed-on-opaque rule cited"
require_phrase "${GUIDE}" 'outside Claude.s tool API'          "GUIDE out-of-band class"
require_phrase "${GUIDE}" 'governed executor'                  "GUIDE governed-executor mitigation"
require_phrase "${GUIDE}" 'seccomp|eBPF|auditd'                "GUIDE OS-level mitigation"

echo ""
echo "================================================================"
echo "  PROMPT CONTENT SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
exit 0
