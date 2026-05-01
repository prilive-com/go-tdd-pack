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
FILE="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || echo '')"
[[ -z "$FILE" ]] && exit 0

# Always-allow paths (orthogonal to TDD discipline).
case "$FILE" in
  */.tdd/*|*/.claude/*|*.md|*/docs/*|*/specs/*|*/archive/*|*/CHANGELOG.md) exit 0 ;;
  *_test.go) exit 0 ;;
esac

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CONFIG="$PROJECT_DIR/.tdd/tdd-config.json"
PLAN="$PROJECT_DIR/.tdd/current-plan.md"

# No config means TDD ceremony not configured for this project — allow.
[[ ! -f "$CONFIG" ]] && exit 0

# Match the file against tier1_path_regexes.
MATCHED="no"
while IFS= read -r pattern; do
  [[ -z "$pattern" ]] && continue
  if printf '%s' "$FILE" | grep -qE "$pattern"; then
    MATCHED="yes"
    break
  fi
done < <(jq -r '.tier1_path_regexes[]? // empty' "$CONFIG")

[[ "$MATCHED" != "yes" ]] && exit 0

# Tier 1 path. TDD ceremony required.
if [[ ! -f "$PLAN" ]]; then
  cat >&2 <<HOOK_MSG
[require-tdd-state] BLOCKED edit to Tier 1 high-stakes path:
  $FILE

<claude-directive>
This is an AUTOMATED TDD GATE, not a user denial. No .tdd/current-plan.md
exists. Production edits to Tier 1 paths require the go-tdd-feature or
go-tdd-bugfix skill workflow.

You MUST do the following autonomously, in order:
  1. Invoke the go-tdd-feature skill (for new functionality) or
     go-tdd-bugfix skill (for bug fixes / regressions).
  2. Copy .tdd/templates/{feature,bugfix}-plan.md to .tdd/current-plan.md.
  3. Fill in the spec sections.
  4. STOP and ask the human for explicit APPROVED at the spec gate (Gate 1).

Do NOT proceed with the edit. Do NOT self-approve. Do NOT bypass the hook
by editing markers without an APPROVED reply from the human.
</claude-directive>
HOOK_MSG
  exit 2
fi

# Plan exists. Check the required markers from config.
MISSING=()
while IFS= read -r marker; do
  [[ -z "$marker" ]] && continue
  grep -q "^$marker$" "$PLAN" || MISSING+=("$marker")
done < <(jq -r '.required_markers[]? // empty' "$CONFIG")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  cat >&2 <<HOOK_MSG
[require-tdd-state] BLOCKED edit to Tier 1 high-stakes path:
  $FILE

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
     - "Human approved spec: yes" missing -> ask for Gate 1 APPROVED.
     - "Red phase confirmed: yes" missing -> write failing tests first,
       capture verbatim output to .tdd/red-proof.md.
     - "Human approved implementation: yes" missing -> ask for Gate 2 APPROVED.
  3. The operator approves with the literal word APPROVED. Any other
     reply is not an approval. NEVER self-approve by setting a marker
     without an explicit human reply.
</claude-directive>
HOOK_MSG
  exit 2
fi

exit 0
