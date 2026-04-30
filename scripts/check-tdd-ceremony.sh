#!/usr/bin/env bash
# Check that any commit touching a Tier 1 path follows the red->green pattern.
# A green(<id>): commit must be preceded by a red(<id>): commit on the same branch.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CONFIG="$PROJECT_DIR/.tdd/tdd-config.json"

if [ ! -f "$CONFIG" ]; then
  echo "No .tdd/tdd-config.json — skipping TDD ceremony check"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required for TDD ceremony check"
  exit 1
fi

# Determine base branch
BASE="${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-${GITHUB_BASE_REF:-main}}"

# Get changed files in this PR/MR
CHANGED_FILES="$(git diff --name-only "origin/$BASE"...HEAD 2>/dev/null || git diff --name-only "$BASE"...HEAD || true)"

# Find Tier 1 files among the changed files
TIER1_CHANGED=()
while IFS= read -r file; do
  [ -z "$file" ] && continue
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    if echo "$file" | grep -qE "$pattern"; then
      TIER1_CHANGED+=("$file")
      break
    fi
  done < <(jq -r '.tier1_path_regexes[]? // empty' "$CONFIG")
done <<< "$CHANGED_FILES"

if [ ${#TIER1_CHANGED[@]} -eq 0 ]; then
  echo "No Tier 1 paths changed — skipping ceremony check"
  exit 0
fi

echo "Tier 1 paths changed in this PR:"
printf '  %s\n' "${TIER1_CHANGED[@]}"
echo

# Find green(<id>): commits in the PR range
GREEN_COMMITS="$(git log --format='%H %s' "origin/$BASE..HEAD" 2>/dev/null | grep -E 'green\([^)]+\):' || git log --format='%H %s' "$BASE..HEAD" | grep -E 'green\([^)]+\):' || true)"

if [ -z "$GREEN_COMMITS" ]; then
  echo "WARNING: Tier 1 paths changed but no green(<id>): commits found."
  echo "Expected commit pattern: red(<id>): ... followed by green(<id>): ..."
  echo "If this PR was authored without TDD ceremony, get explicit operator approval."
  exit 1
fi

# For each green(<id>):, verify there's a corresponding red(<id>): earlier
FAIL=0
while IFS= read -r line; do
  GREEN_HASH="$(echo "$line" | awk '{print $1}')"
  ID="$(echo "$line" | grep -oE 'green\([^)]+\)' | sed 's/green(//;s/)//')"

  if ! git log --format='%s' "origin/$BASE..$GREEN_HASH" 2>/dev/null | grep -qE "^red\($ID\):" \
     && ! git log --format='%s' "$BASE..$GREEN_HASH" | grep -qE "^red\($ID\):"; then
    echo "ERROR: green($ID) commit $GREEN_HASH has no preceding red($ID) commit"
    FAIL=1
  else
    echo "OK: green($ID) preceded by red($ID)"
  fi
done <<< "$GREEN_COMMITS"

if [ $FAIL -eq 1 ]; then
  echo
  echo "TDD ceremony violation. Each Tier 1 fix must have a red commit"
  echo "(failing test) BEFORE the green commit (implementation)."
  exit 1
fi

echo "TDD ceremony check passed."
