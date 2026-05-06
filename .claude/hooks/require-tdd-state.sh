#!/usr/bin/env bash
# PreToolUse hook on Edit|Write|MultiEdit. Blocks production-code edits in
# Tier 1 high-stakes paths (per .tdd/tdd-config.json) unless
# .tdd/current-plan.md has the required markers.
#
# Implementation notes:
# - Uses exit 2 + stderr for blocking. Per official Anthropic docs, this
#   takes precedence over permissions.allow rules and is the most reliable
#   blocking mechanism across Claude Code versions.
# - Adds <claude-directive> markup to the stderr message to mitigate
#   reports of Opus 4.6+ stopping on hook blocks instead of acting on
#   the feedback.
# - jq is required. The hook fails closed with a clear error if jq is missing.
#
# 2026-05-05 redesign (see docs/specs/tdd-gate-conflict-resolution-spec.md):
# - Four-marker model. Edit-time markers are M1+M2+M3 (spec, red, green-
#   authorized). M4 (Implementation reviewed) is checked at commit time
#   by gate-tier1-commit.sh, not here.
# - Backwards-compat alias: old "Human approved implementation: yes" is
#   honored as "Green phase authorized: yes" with a stderr deprecation
#   warning. Drop the alias in the next major version.
# - Phase-aware test-file policy. Tier-1 test files are no longer always
#   exempt; they are governed by .test_file_policy in the config so the
#   "don't edit tests in green phase" rule can be enforced.

set -euo pipefail

PAYLOAD="$(cat)"

# jq guard MUST come before any jq invocation. The previous version called jq
# at line 18 to extract FILE and then exited 0 on empty FILE — which fails OPEN
# (Tier 1 edits silently allowed) when jq is missing. Order matters here.
if ! command -v jq >/dev/null 2>&1; then
  cat >&2 <<'HOOK_MSG'
[require-tdd-state] BLOCKED: jq is required for the TDD gate hook.

<claude-directive>
This is an AUTOMATED ENVIRONMENT CHECK, not a user denial. The TDD
enforcement hook needs jq to parse .tdd/tdd-config.json. Suggest the
user install jq with one of:
  - Debian/Ubuntu: sudo apt-get install jq
  - macOS:         brew install jq
  - Alpine:        apk add jq

Do NOT proceed with the edit. Do NOT bypass the hook. Inform the user
of the missing dependency and wait for them to install it.
</claude-directive>
HOOK_MSG
  exit 2
fi

# Now safe to use jq.
#
# Defensive path extraction: collect every candidate path the tool might be
# touching. Current Edit/Write/MultiEdit shapes only set tool_input.file_path
# (sometimes .path), but future tool variants may use .files[].file_path or
# .edits[].file_path. Reading all four keeps the gate correct under shape drift.
PATHS="$(printf '%s' "$PAYLOAD" | jq -r '
  [
    .tool_input.file_path?,
    .tool_input.path?,
    (.tool_input.files[]?.file_path?),
    (.tool_input.edits[]?.file_path?)
  ]
  | map(select(. != null and . != ""))
  | unique
  | .[]
' 2>/dev/null || true)"
[[ -z "$PATHS" ]] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CONFIG="$PROJECT_DIR/.tdd/tdd-config.json"
PLAN="$PROJECT_DIR/.tdd/current-plan.md"

# No config means TDD ceremony not configured for this project — allow.
[[ ! -f "$CONFIG" ]] && exit 0

# Read tier1 regexes once (avoid re-reading per-file in the loop).
TIER1_REGEXES="$(jq -r '.tier1_path_regexes[]? // empty' "$CONFIG")"

# Walk every candidate path. Skip always-allow non-test paths (docs, .claude,
# CHANGELOG, archive). Test files are NOT in the always-allow list anymore —
# they go through phase-aware policy (see test_file_policy below).
TIER1_MATCHED=()
while IFS= read -r FILE; do
  [[ -z "$FILE" ]] && continue
  case "$FILE" in
    */.tdd/*|*/.claude/*|*.md|*/docs/*|*/specs/*|*/archive/*|*/CHANGELOG.md) continue ;;
  esac
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    if printf '%s' "$FILE" | grep -qE "$pattern"; then
      TIER1_MATCHED+=("$FILE")
      break
    fi
  done <<< "$TIER1_REGEXES"
done <<< "$PATHS"

[[ ${#TIER1_MATCHED[@]} -eq 0 ]] && exit 0

# Categorize Tier-1-matched files into test files and production files.
# They are governed by different rules:
#   - Production files: must have M1+M2+M3 set on the plan.
#   - Test files: governed by test_file_policy (phase-aware).
TIER1_TESTS=()
TIER1_PROD=()
for f in "${TIER1_MATCHED[@]}"; do
  case "$f" in
    *_test.go) TIER1_TESTS+=("$f") ;;
    *) TIER1_PROD+=("$f") ;;
  esac
done

# Helper: render a Tier-1-matched path list for deny messages.
fmt_paths() {
  local IFS=$'\n'
  printf '  %s\n' "$@"
}

# ---- Test-file policy ------------------------------------------------------
#
# Phase-aware. The default config allows test edits before/during red phase
# and denies them after red is confirmed (the documented "don't edit tests
# in green phase" rule). Operators can flip allow_after_red_confirmed: true
# in config when the spec was incomplete and a return to red phase is needed.
if [[ ${#TIER1_TESTS[@]} -gt 0 ]]; then
  ALLOW_BEFORE_SPEC="$(jq -r '.test_file_policy.allow_before_spec_approved // true' "$CONFIG")"
  ALLOW_IN_RED="$(jq -r '.test_file_policy.allow_in_red_phase // true' "$CONFIG")"
  ALLOW_AFTER_RED="$(jq -r '.test_file_policy.allow_after_red_confirmed // false' "$CONFIG")"

  M1_SET=false
  M2_SET=false
  if [[ -f "$PLAN" ]]; then
    grep -qF 'Human approved spec: yes' "$PLAN" && M1_SET=true
    grep -qF 'Red phase confirmed: yes' "$PLAN" && M2_SET=true
  fi

  if [[ "$M2_SET" == "true" && "$ALLOW_AFTER_RED" != "true" ]]; then
    test_list="$(fmt_paths "${TIER1_TESTS[@]}")"
    cat >&2 <<HOOK_MSG
[require-tdd-state] BLOCKED edit to Tier 1 test file(s) after red phase confirmed:
$test_list

<claude-directive>
This is an AUTOMATED TDD GATE. Editing tests after the red phase has been
confirmed is forbidden by default — that would let you change the test to
match the implementation, defeating the point of red-before-green. The
documented rule is: "If tests need changes, the spec was incomplete. STOP,
return to red."

You MUST do one of:
  1. STOP and tell the operator that the spec was incomplete. Ask whether
     to revert "Red phase confirmed: yes" to "no" and rewrite the spec
     and red proof. The operator must explicitly authorize a return to
     red phase.
  2. If the operator has already authorized return to red, set
     "Red phase confirmed: no" in .tdd/current-plan.md FIRST, then make
     the test edits, then re-capture .tdd/red-proof.md.
  3. EMERGENCY ONLY: the operator may flip
     test_file_policy.allow_after_red_confirmed: true in
     .tdd/tdd-config.json. Document the reason in the commit message.
     This is not for routine use.

Do NOT proceed with the edit without operator authorization.
</claude-directive>
HOOK_MSG
    exit 2
  fi

  if [[ "$M1_SET" == "false" && "$ALLOW_BEFORE_SPEC" != "true" ]]; then
    test_list="$(fmt_paths "${TIER1_TESTS[@]}")"
    cat >&2 <<HOOK_MSG
[require-tdd-state] BLOCKED edit to Tier 1 test file(s) before spec approved:
$test_list

<claude-directive>
This project's test_file_policy.allow_before_spec_approved is false. Test
edits require an approved spec first. Run the go-tdd-feature or
go-tdd-bugfix skill, draft the spec, and ask for APPROVED SPEC at gate 1
before writing tests.
</claude-directive>
HOOK_MSG
    exit 2
  fi

  # Otherwise: in spec or red phase, test edits are allowed by default.
fi

# ---- Production-file gate -------------------------------------------------
[[ ${#TIER1_PROD[@]} -eq 0 ]] && exit 0
PROD_LIST="$(fmt_paths "${TIER1_PROD[@]}")"

if [[ ! -f "$PLAN" ]]; then
  cat >&2 <<HOOK_MSG
[require-tdd-state] BLOCKED edit to Tier 1 high-stakes path(s):
$PROD_LIST

<claude-directive>
This is an AUTOMATED TDD GATE, not a user denial. No .tdd/current-plan.md
exists. Production edits to Tier 1 paths require the go-tdd-feature or
go-tdd-bugfix skill workflow.

You MUST do the following autonomously, in order:
  1. Invoke the go-tdd-feature skill (for new functionality) or
     go-tdd-bugfix skill (for bug fixes / regressions).
  2. Copy .tdd/templates/{feature,bugfix}-plan.md to .tdd/current-plan.md.
  3. Fill in the spec sections.
  4. STOP and ask the human for explicit APPROVED SPEC at gate 1.

Do NOT proceed with the edit. Do NOT self-approve. Do NOT bypass the hook
by editing markers without an APPROVED reply from the human.
</claude-directive>
HOOK_MSG
  exit 2
fi

# Plan exists. Resolve the edit-time required markers (prefer the new field
# name; fall back to legacy required_markers for older configs).
EDIT_TIME_MARKERS_RAW="$(jq -r '
  if (.required_markers_edit_time | type) == "array"
  then .required_markers_edit_time[]?
  else .required_markers[]? // empty
  end
' "$CONFIG")"

# Build the alias map (new -> old). For each required marker, if the new
# name is missing but the alias is present, accept with deprecation warning.
ALIAS_PAIRS="$(jq -r '
  .marker_aliases // {} | to_entries[] | "\(.key)\t\(.value)"
' "$CONFIG")"

# Walk required markers. Track missing (with no acceptable alias) for the deny
# message; emit a single deprecation summary if any alias was used.
MISSING=()
ALIAS_USED=()
while IFS= read -r marker; do
  [[ -z "$marker" ]] && continue
  if grep -qF "$marker" "$PLAN"; then
    continue
  fi
  # Look up alias for this marker.
  alias=""
  while IFS=$'\t' read -r k v; do
    [[ "$k" == "$marker" ]] && alias="$v"
  done <<< "$ALIAS_PAIRS"
  if [[ -n "$alias" ]] && grep -qF "$alias" "$PLAN"; then
    ALIAS_USED+=("$alias -> $marker")
    continue
  fi
  MISSING+=("$marker")
done <<< "$EDIT_TIME_MARKERS_RAW"

if [[ ${#ALIAS_USED[@]} -gt 0 ]]; then
  echo "[require-tdd-state] DEPRECATION: plan uses old marker name(s):" >&2
  for a in "${ALIAS_USED[@]}"; do echo "  $a" >&2; done
  echo "[require-tdd-state] Run scripts/migrate-tdd-markers.sh to update the plan. The alias will be removed in the next major version." >&2
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  cat >&2 <<HOOK_MSG
[require-tdd-state] BLOCKED edit to Tier 1 high-stakes path(s):
$PROD_LIST
The plan at .tdd/current-plan.md is missing required markers:
HOOK_MSG
  for m in "${MISSING[@]}"; do echo "  - $m" >&2; done
  cat >&2 <<HOOK_MSG

<claude-directive>
This is an AUTOMATED TDD GATE, not a user denial. The plan exists but
the required APPROVED markers are not all set.

You MUST:
  1. STOP. Do not edit any Tier 1 production file.
  2. Identify which gate is missing approval:
     - "Human approved spec: yes" missing       -> gate 1 not approved.
       Ask operator: "APPROVED SPEC for <cycle-id>?"
     - "Red phase confirmed: yes" missing       -> red proof not done.
       Write failing tests; capture verbatim output to .tdd/red-proof.md;
       set the marker yourself once the artifact exists.
     - "Green phase authorized: yes" missing    -> gate 2 not approved.
       Ask operator: "APPROVED GREEN for <cycle-id>?" The operator's
       APPROVED GREEN authorizes you to begin writing the implementation.
  3. The operator approves with the literal word APPROVED (or
     APPROVED SPEC / APPROVED GREEN for clarity). Any other reply is
     not an approval. NEVER self-approve by setting a marker without
     an explicit human reply.

Note: M4 "Implementation reviewed: yes" is NOT required at edit time.
That marker is checked at commit time by gate-tier1-commit.sh after the
operator says APPROVED IMPLEMENTATION at gate 3.
</claude-directive>
HOOK_MSG
  exit 2
fi

exit 0
