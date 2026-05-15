#!/usr/bin/env bash
# .claude/hooks/second-opinion-bash-pretrigger.sh
#
# v1.9.0 round-8 F1 — PreToolUse Bash classifier. Blocks mutating
# Bash commands that target gated production .go paths BEFORE the
# write lands. Defense-in-depth layer for the cases where the AI
# would otherwise bypass the Edit/Write triggers by using a
# heredoc / redirect / tee / sed -i.
#
# Conservative-by-design: blocks broadly when ambiguous, and only
# fires when `second_opinion.no_discretion.enabled: true`.

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "[second-opinion-bash-pretrigger] BLOCKED: jq required." >&2
  exit 2
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CONFIG="$PROJECT_DIR/.tdd/tdd-config.json"
PLAN="$PROJECT_DIR/.tdd/current-plan.md"

[[ ! -f "$CONFIG" ]] && exit 0
enabled="$(jq -r '.second_opinion.no_discretion.enabled // false' "$CONFIG" 2>/dev/null || echo false)"
[[ "$enabled" != "true" ]] && exit 0

PAYLOAD="$(cat)"
if ! printf '%s' "$PAYLOAD" | jq -e . >/dev/null 2>&1; then
  echo "[second-opinion-bash-pretrigger] BLOCKED: malformed JSON input." >&2
  exit 2
fi

tool_name="$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""')"
[[ "$tool_name" != "Bash" ]] && exit 0

command_str="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""')"
[[ -z "$command_str" ]] && exit 0

# Detect mutating Bash patterns:
#   - redirection ('> path', '>> path', '| tee path')
#   - in-place edits ('sed -i', 'awk -i inplace')
#   - heredoc to file ('cat <<EOF > path', 'cat <<EOF | tee path')
#   - file creation ('cp foo path', 'mv foo path', 'touch path')
mutating_kw='(>|>>|tee|sed -i|sed --in-place|awk -i inplace|cp |mv |rm |touch )'
if ! printf '%s' "$command_str" | grep -qE "$mutating_kw"; then
  exit 0
fi

# Now check if the command targets a gated production path.
# Heuristic: scan the command for path-like tokens ending in .go
# OR for .tdd/exceptions/, .tdd/audit/, .tdd/CYCLE_ABANDONED.txt.
gated_paths=""
# v1.9.0 round-9 F1: cover the SAME path universe as PreToolUse
# Edit/Write triggers. Plan paths, test paths, and production paths
# are all gated. Operator's job is to use Edit/Write so the primary
# triggers run; Bash mutations to these paths bypass primary gates.
# Production .go (NOT in test/scripts/etc dirs).
gated_paths+="$(printf '%s\n' "$command_str" | grep -oE '\S+\.go\b' | grep -vE 'scripts/|\.claude/|\.tdd/|docs/|specs/|vendor/|archive/' || true)"
# Audit + exception artifacts.
gated_paths+="$(printf '\n%s\n' "$command_str" | grep -oE '\.tdd/(exceptions|audit)/\S+' || true)"
gated_paths+="$(printf '\n%s\n' "$command_str" | grep -oE '\.tdd/CYCLE_ABANDONED\.txt' || true)"
# Plan paths.
gated_paths+="$(printf '\n%s\n' "$command_str" | grep -oE '\.tdd/current-plan\.md|\.tdd/plans/\S+|docs/specs/\S+\.md' || true)"
# Test paths (separated because *_test.go was excluded from
# production .go above; F1 round-9: test paths ARE gated for Bash).
gated_paths+="$(printf '\n%s\n' "$command_str" | grep -oE '\S+_test\.go\b' | grep -vE 'scripts/|\.claude/|\.tdd/|docs/|specs/|vendor/|archive/' || true)"

if [[ -z "${gated_paths// /}" ]]; then
  exit 0
fi

cycle_id="$( { grep -E '^Cycle ID:' "$PLAN" 2>/dev/null || true; } | head -1 | sed -E 's/^Cycle ID:[[:space:]]*//')"
[[ -z "$cycle_id" ]] && cycle_id="unknown-cycle"

# Block with stable error code.
target_summary="$(printf '%s' "$gated_paths" | tr '\n' ' ' | head -c 200)"
jq -n --arg cmd "$(printf '%s' "$command_str" | head -c 200)" --arg targets "$target_summary" --arg cid "$cycle_id" '
  {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("PRODUCTION_EDIT_REVIEW_REQUIRED (Bash classifier). Mutating Bash command targets gated path(s): " + $targets + ". Mutating production files or audit/exception artifacts via Bash bypasses the Edit/Write trigger. Run: scripts/tdd/run-second-opinion.sh production_edit " + $cid + " after using Edit/Write for the file change. NOTE if target is .tdd/CYCLE_ABANDONED.txt: this gate is intentional — the operator must abandon from a real shell outside Claude Code; the agent has no path to do it. Tell the operator to run: echo \"APPROVED CYCLE ABANDONMENT\" > .tdd/CYCLE_ABANDONED.txt")
    }
  }'
exit 0
