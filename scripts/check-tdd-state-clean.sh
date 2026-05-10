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

# C5 (v1.6.1): read commit-time markers from .tdd/tdd-config.json
# (with marker_aliases support). Hardcoded "Human approved
# implementation: yes" was the pre-migration name; post-migration
# plans use "Green phase authorized: yes" + a new "Implementation
# reviewed: yes" — this script then false-failed every legitimate
# cycle. Latent because the CI job runs only on PRs.
CONFIG=".tdd/tdd-config.json"
required_markers=()
alias_pairs=""
if [[ -f "$CONFIG" ]] && command -v jq >/dev/null 2>&1; then
  while IFS= read -r m; do
    [[ -n "$m" ]] && required_markers+=("$m")
  done < <(jq -r '
    if (.required_markers_commit_time | type) == "array"
    then .required_markers_commit_time[]?
    elif (.required_markers | type) == "array"
    then .required_markers[]?
    else empty
    end
  ' "$CONFIG" 2>/dev/null || true)
  alias_pairs="$(jq -r '.marker_aliases // {} | to_entries[] | "\(.key)\t\(.value)"' "$CONFIG" 2>/dev/null || true)"
fi
if [[ ${#required_markers[@]} -eq 0 ]]; then
  required_markers=(
    "Human approved spec: yes"
    "Red phase confirmed: yes"
    "Green phase authorized: yes"
    "Implementation reviewed: yes"
  )
fi

# Active. Check that all required commit-time markers are set
# (= cycle complete, just hasn't been reset to idle).
MISSING=()
for marker in "${required_markers[@]}"; do
  grep -q "^${marker}$" "$PLAN" && continue
  # Try alias (old marker name); accept with deprecation warning.
  alias_old=""
  if [[ -n "$alias_pairs" ]]; then
    while IFS=$'\t' read -r k v; do
      [[ "$k" == "$marker" ]] && alias_old="$v"
    done <<< "$alias_pairs"
  fi
  if [[ -n "$alias_old" ]] && grep -q "^${alias_old}$" "$PLAN"; then
    echo "WARNING: plan uses old marker '$alias_old' (renamed to '$marker'); run scripts/migrate-tdd-markers.sh." >&2
    continue
  fi
  MISSING+=("$marker")
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
