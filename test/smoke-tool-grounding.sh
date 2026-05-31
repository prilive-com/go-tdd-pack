#!/usr/bin/env bash
# test/smoke-tool-grounding.sh
#
# Unit-style smoke for runner/tool-grounding.sh. Builds synthetic git
# repos in tmpdirs, modifies files, runs the script, asserts on output.
#
# Cases:
#   1. single-module Go repo                 → expect 1 section for "."
#   2. monorepo with multiple modules        → expect ONLY the touched module
#   3. polyglot / non-Go change              → expect "no module-affecting files"
#   4. Go files but no enclosing go.mod      → expect "no enclosing go.mod"
#
# These cases regression-protect the universal discovery algorithm against
# the original "go.mod must live at PROJECT_DIR" bug.

set -uo pipefail

SCRIPT_PATH="$(cd "$(dirname "$0")/.." && pwd)/runner/tool-grounding.sh"
[[ -x "${SCRIPT_PATH}" ]] || { echo "✗ tool-grounding.sh not executable at ${SCRIPT_PATH}" >&2; exit 1; }

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }

PASS_COUNT=0

init_git() {
  git init -q
  git config user.email "t@t" && git config user.name "t"
}

# ---- Case 1: single-module ----

info "[1] single-module Go repo"
T1=$(mktemp -d)
(
  cd "${T1}" || exit 1
  init_git
  printf 'module test/single\n\ngo 1.22\n' > go.mod
  printf 'package main\nfunc main() {}\n' > main.go
  git add -A && git commit -q -m init
  # Modify the file
  printf 'package main\nfunc main() { _ = 42 }\n' > main.go
) >/dev/null 2>&1

OUT=$("${SCRIPT_PATH}" "${T1}" 2>/dev/null)

if echo "${OUT}" | grep -q '## Module: `\.`'; then
  pass "case 1: emits single-module section"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "case 1: expected '## Module: \`.\`' in output"
fi

if echo "${OUT}" | grep -q "Summary:.*1 affected Go module"; then
  pass "case 1: summary reports 1 affected module"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "case 1: missing or wrong summary line"
fi

rm -rf "${T1}"

# ---- Case 2: monorepo ----

info "[2] monorepo (modules at services/api and services/lib)"
T2=$(mktemp -d)
(
  cd "${T2}" || exit 1
  init_git
  mkdir -p services/api services/lib
  printf 'module test/api\n\ngo 1.22\n' > services/api/go.mod
  printf 'package main\nfunc main() {}\n' > services/api/main.go
  printf 'module test/lib\n\ngo 1.22\n' > services/lib/go.mod
  printf 'package lib\n' > services/lib/lib.go
  git add -A && git commit -q -m init
  # Modify ONLY services/api/main.go
  printf 'package main\nfunc main() { _ = 1 }\n' > services/api/main.go
) >/dev/null 2>&1

OUT=$("${SCRIPT_PATH}" "${T2}" 2>/dev/null)

if echo "${OUT}" | grep -q '## Module: `services/api`'; then
  pass "case 2: emits services/api section"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "case 2: expected '## Module: \`services/api\`' in output"
fi

if echo "${OUT}" | grep -q '## Module: `services/lib`'; then
  fail "case 2: services/lib should NOT appear (untouched module)"
else
  pass "case 2: services/lib correctly omitted"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

if echo "${OUT}" | grep -q "Summary:.*1 affected Go module"; then
  pass "case 2: summary reports 1 affected module (not 2)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "case 2: monorepo summary wrong; got: $(echo "${OUT}" | grep Summary || echo '(no Summary)')"
fi

rm -rf "${T2}"

# ---- Case 2b: monorepo, multiple modules touched ----

info "[2b] monorepo, both modules touched"
T2B=$(mktemp -d)
(
  cd "${T2B}" || exit 1
  init_git
  mkdir -p services/api services/lib
  printf 'module test/api\n\ngo 1.22\n' > services/api/go.mod
  printf 'package main\nfunc main() {}\n' > services/api/main.go
  printf 'module test/lib\n\ngo 1.22\n' > services/lib/go.mod
  printf 'package lib\n' > services/lib/lib.go
  git add -A && git commit -q -m init
  # Modify BOTH
  printf 'package main\nfunc main() { _ = 1 }\n' > services/api/main.go
  printf 'package lib\nvar X = 1\n' > services/lib/lib.go
) >/dev/null 2>&1

OUT=$("${SCRIPT_PATH}" "${T2B}" 2>/dev/null)

if echo "${OUT}" | grep -q '## Module: `services/api`' && \
   echo "${OUT}" | grep -q '## Module: `services/lib`'; then
  pass "case 2b: both modules appear in output"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "case 2b: expected both services/api and services/lib sections"
fi

rm -rf "${T2B}"

# ---- Case 3: non-Go change ----

info "[3] non-Go change (README only)"
T3=$(mktemp -d)
(
  cd "${T3}" || exit 1
  init_git
  printf 'module test/x\n\ngo 1.22\n' > go.mod
  printf 'package main\nfunc main() {}\n' > main.go
  printf '# Test\n' > README.md
  git add -A && git commit -q -m init
  # Modify README only
  printf '# Test\nUpdated.\n' > README.md
) >/dev/null 2>&1

OUT=$("${SCRIPT_PATH}" "${T3}" 2>/dev/null)

if echo "${OUT}" | grep -q "no module-affecting files"; then
  pass "case 3: emits 'no module-affecting files' status"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "case 3: expected 'no module-affecting files' status; got: $(echo "${OUT}" | head -5)"
fi

if echo "${OUT}" | grep -q '## Module'; then
  fail "case 3: should NOT emit any module section for README-only diff"
else
  pass "case 3: no module sections emitted (correct for non-Go diff)"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

rm -rf "${T3}"

# ---- Case 4: orphan Go file (no go.mod anywhere) ----

info "[4] Go file with no enclosing go.mod"
T4=$(mktemp -d)
(
  cd "${T4}" || exit 1
  init_git
  # NO go.mod
  printf 'package orphan\n' > orphan.go
  git add -A && git commit -q -m init
  # Modify
  printf 'package orphan\nvar X = 1\n' > orphan.go
) >/dev/null 2>&1

OUT=$("${SCRIPT_PATH}" "${T4}" 2>/dev/null)

if echo "${OUT}" | grep -q "no enclosing go.mod"; then
  pass "case 4: emits 'no enclosing go.mod' status"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "case 4: expected 'no enclosing go.mod' status; got: $(echo "${OUT}" | head -5)"
fi

if echo "${OUT}" | grep -q "orphan.go"; then
  pass "case 4: lists orphan file by name"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "case 4: orphan file name should appear in output"
fi

rm -rf "${T4}"

# ---- Case 5: vendor/ excluded ----

info "[5] vendor/ changes excluded"
T5=$(mktemp -d)
(
  cd "${T5}" || exit 1
  init_git
  printf 'module test/v\n\ngo 1.22\n' > go.mod
  printf 'package main\nfunc main() {}\n' > main.go
  mkdir -p vendor/github.com/foo/bar
  printf 'package bar\n' > vendor/github.com/foo/bar/bar.go
  git add -A && git commit -q -m init
  # Modify vendor only
  printf 'package bar\nvar X = 1\n' > vendor/github.com/foo/bar/bar.go
) >/dev/null 2>&1

OUT=$("${SCRIPT_PATH}" "${T5}" 2>/dev/null)

if echo "${OUT}" | grep -q "no module-affecting files"; then
  pass "case 5: vendor/-only diff treated as non-module-affecting"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "case 5: expected 'no module-affecting files' for vendor/-only change"
fi

rm -rf "${T5}"

# ---- Case 6: empty go.mod (Grab exclude marker) ----

info "[6] empty go.mod blocks tool-grounding for that subtree"
T6=$(mktemp -d)
(
  cd "${T6}" || exit 1
  init_git
  printf 'module test/root\n\ngo 1.22\n' > go.mod
  printf 'package main\nfunc main() {}\n' > main.go
  mkdir -p excluded
  : > excluded/go.mod   # ZERO-byte go.mod (Grab exclusion marker)
  printf 'package excluded\n' > excluded/foo.go
  git add -A && git commit -q -m init
  # Modify the excluded-subtree file
  printf 'package excluded\nvar X = 1\n' > excluded/foo.go
) >/dev/null 2>&1

OUT=$("${SCRIPT_PATH}" "${T6}" 2>/dev/null)

# The walk-up hits excluded/go.mod (empty) and stops without registering a
# module. Since this is the only affected file, expect the "no enclosing
# go.mod" branch (the empty marker blocks further walk to root).
if echo "${OUT}" | grep -q "no enclosing go.mod\|no module-affecting"; then
  pass "case 6: empty go.mod blocks module registration"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "case 6: empty go.mod should block; got: $(echo "${OUT}" | head -3)"
fi

rm -rf "${T6}"

# ---- summary ----

echo ""
echo "================================================================"
echo "  TOOL-GROUNDING SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"

exit 0
