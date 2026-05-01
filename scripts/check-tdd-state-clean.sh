#!/usr/bin/env bash
# Pre-merge guard: refuse to merge an MR/PR if .tdd/current-plan.md is still
# in an in-flight state.
#
# Why this exists: .gitignore deliberately tracks .tdd/current-plan.md and
# .tdd/red-proof.md so the audit trail of every TDD cycle is in git history.
# Without this check, a developer mid-cycle who runs `git push` will push
# their personal WIP plan to main, including any private notes — a real
# workflow leak.
#
# This is a CI-only check (we deliberately ship no pre-commit). It runs on
# merge_request_event / pull_request and verifies the plan is either:
#   - Status: idle   (cycle complete or never started), OR
#   - All required markers ('Human approved spec/implementation: yes',
#     'Red phase confirmed: yes') are set (cycle finished but not yet
#     reset to idle).
#
# Anything else — Status: active with markers missing — fails the merge.
set -euo pipefail

PLAN=".tdd/current-plan.md"

if [[ ! -f "$PLAN" ]]; then
  echo "No $PLAN — nothing to check."
  exit 0
fi

STATUS_LINE="$(grep -E '^Status:' "$PLAN" | head -1 || echo '')"

# Idle? Always allowed.
if echo "$STATUS_LINE" | grep -qiE '^Status:[[:space:]]*idle[[:space:]]*$'; then
  echo "TDD state OK: plan is idle."
  exit 0
fi

# Active. Check that all 3 approval markers are set (= cycle complete,
# just hasn't been reset to idle yet — common when squash-merging).
MISSING=()
for marker in \
  "Human approved spec: yes" \
  "Red phase confirmed: yes" \
  "Human approved implementation: yes"; do
  grep -q "^${marker}$" "$PLAN" || MISSING+=("$marker")
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
  echo "TDD state OK: plan is active but all approval markers are set (cycle complete; reset to idle in a follow-up commit)."
  exit 0
fi

echo "ERROR: $PLAN is in an in-flight state but the cycle isn't complete." >&2
echo "" >&2
echo "Status line: $STATUS_LINE" >&2
echo "Missing markers:" >&2
for m in "${MISSING[@]}"; do echo "  - $m" >&2; done
echo "" >&2
echo "Either:" >&2
echo "  - complete the TDD cycle (set the missing markers via APPROVED), OR" >&2
echo "  - reset the plan to 'Status: idle' before merging." >&2
echo "" >&2
echo "If this is an emergency hotfix bypass, document the reason in the" >&2
echo "MR/PR description and set the markers manually (this CI check still" >&2
echo "fails so the bypass is visible)." >&2
exit 1
