#!/usr/bin/env bash
# .claude/hooks/second-opinion-posttool-backstop.sh
#
# v1.9.0 PR 5 — PostToolUse backstop for Bash. Catches mutating Bash
# commands that wrote files PreToolUse triggers couldn't classify
# in advance (e.g., `cat > internal/foo.go`). Detects mutations of
# protected paths after the fact and creates a pending obligation so
# the Stop hook and next PreToolUse block.
#
# This is defense-in-depth, NOT primary enforcement. The PreToolUse
# triggers are primary. This hook cannot undo the already-written
# file; it makes the next action visible to the gate.

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

PAYLOAD="$(cat)"
if ! printf '%s' "$PAYLOAD" | jq -e . >/dev/null 2>&1; then
  exit 0
fi

tool_name="$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""')"
if [[ "$tool_name" != "Bash" ]]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CONFIG="$PROJECT_DIR/.tdd/tdd-config.json"
PLAN="$PROJECT_DIR/.tdd/current-plan.md"
ARTIFACT="$PROJECT_DIR/.tdd/exceptions/post-red-test-edits.json"

[[ ! -f "$CONFIG" ]] && exit 0
enabled="$(jq -r '.second_opinion.no_discretion.enabled // false' "$CONFIG" 2>/dev/null || echo false)"
[[ "$enabled" != "true" ]] && exit 0

# v1.9.0 round-7 F4: inspect `git diff --name-only` post-Bash rather
# than parsing the command string. Catches any production .go file
# regardless of path prefix (main.go, service/foo.go, etc.).
cycle_id="$( { grep -E '^Cycle ID:' "$PLAN" 2>/dev/null || true; } | head -1 | sed -E 's/^Cycle ID:[[:space:]]*//')"
[[ -z "$cycle_id" ]] && exit 0

if ! command -v git >/dev/null 2>&1 || [[ ! -d "$PROJECT_DIR/.git" ]]; then
  exit 0
fi

# Find the first production .go file in the current working-tree diff.
file_path=""
while IFS= read -r changed; do
  [[ -z "$changed" ]] && continue
  case "$changed" in
    *_test.go) continue ;;
    .claude/*|*/.claude/*) continue ;;
    .tdd/*|*/.tdd/*) continue ;;
    docs/*|*/docs/*) continue ;;
    specs/*|*/specs/*) continue ;;
    scripts/*|*/scripts/*) continue ;;
    archive/*|*/archive/*) continue ;;
    vendor/*|*/vendor/*) continue ;;
  esac
  case "$changed" in
    *.go) file_path="$changed"; break ;;
  esac
done < <( cd "$PROJECT_DIR" && git diff --name-only HEAD 2>/dev/null; cd "$PROJECT_DIR" && git ls-files --others --exclude-standard 2>/dev/null )

[[ -z "$file_path" ]] && exit 0

base_git_sha=""
if command -v git >/dev/null 2>&1 && [[ -d "$PROJECT_DIR/.git" ]]; then
  base_git_sha="$( cd "$PROJECT_DIR" && git rev-parse HEAD 2>/dev/null || echo "" )"
fi
[[ -z "$base_git_sha" ]] && base_git_sha="no-git"

# Determine tier.
tier_level="tier2"
while IFS= read -r pattern; do
  [[ -z "$pattern" ]] && continue
  if printf '%s' "$file_path" | grep -qE "$pattern" 2>/dev/null; then
    tier_level="tier1"
    break
  fi
done < <(jq -r '.tier1_path_regexes[]? // empty' "$CONFIG" 2>/dev/null || true)

scope_hash="$(printf 'production_edit|%s|%s|%s' "$cycle_id" "$base_git_sha" "$tier_level" | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | awk '{print $1}')"

# Create pending obligation if not present.
mkdir -p "$(dirname "$ARTIFACT")"
[[ -f "$ARTIFACT" ]] || printf '%s\n' "{\"version\":1,\"cycle_id\":\"$cycle_id\",\"phase\":\"red_confirmed\",\"expires\":\"next_green_commit\",\"exceptions\":[]}" > "$ARTIFACT"

already_pending=$(jq -r --arg cid "$cycle_id" --arg sh "$scope_hash" '
  [.exceptions[]?
   | select(.type == "production_edit_review_completion")
   | select(.binding.cycle_id == $cid)
   | select(.binding.scope_hash == $sh)
   | select(.status == "pending")] | length > 0
' "$ARTIFACT" 2>/dev/null || echo false)

if [[ "$already_pending" != "true" ]]; then
  next_n=$(jq -r '[.exceptions[]?.id // empty | capture("R-(?<n>[0-9]+)").n | tonumber] + [0] | max + 1' "$ARTIFACT")
  new_id=$(printf 'R-%03d' "$next_n")
  ts=$(date -u +%FT%TZ)
  jq --arg id "$new_id" --arg cycle "$cycle_id" --arg sha "$base_git_sha" \
     --arg tier "$tier_level" --arg sh "$scope_hash" --arg fp "$file_path" --arg ts "$ts" \
     '.exceptions += [{
       "id": $id, "type": "production_edit_review_completion", "status": "pending",
       "created_by": "hook-posttool-backstop", "created_at": $ts,
       "scope": {"first_seen_file": $fp, "bash_detected": true},
       "binding": {"cycle_id": $cycle, "base_git_sha": $sha, "tier_level": $tier, "scope_hash": $sh}
     }]' "$ARTIFACT" > "$ARTIFACT.tmp" && mv "$ARTIFACT.tmp" "$ARTIFACT"
fi

# Block the next tool call.
jq -n --arg path "$file_path" --arg cid "$cycle_id" '
  {
    decision: "block",
    reason: ("PRODUCTION_EDIT_REVIEW_REQUIRED (PostToolUse backstop). Bash command mutated production file " + $path + ". Pending obligation created. Run: scripts/tdd/run-second-opinion.sh production_edit " + $cid)
  }'
exit 0
