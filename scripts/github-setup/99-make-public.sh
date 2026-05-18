#!/usr/bin/env bash
# 99-make-public.sh — Flip a private repo to public AFTER verification.
# Requires explicit "MAKE_PUBLIC" confirmation. Refuses to run if obvious
# blockers exist (no LICENSE, no SECURITY.md, etc.).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/gh-curl.sh"
load_config "${CONFIG_FILE:-$SCRIPT_DIR/repo-config.env}"

echo "==> Step 99: Make $ORG/$REPO_NAME PUBLIC"
echo

# Pre-flight checks
echo "Pre-flight checklist (verifying via GitHub Contents API):"

blockers=0
check_file() {
  local path="$1"
  if gh_api GET "/repos/$ORG/$REPO_NAME/contents/$path" >/dev/null 2>&1; then
    echo "  [OK]   $path exists"
  else
    echo "  [FAIL] $path MISSING"
    blockers=$((blockers + 1))
  fi
}

check_file "README.md"
check_file "LICENSE"
check_file "SECURITY.md"
check_file "CONTRIBUTING.md"
check_file "CODE_OF_CONDUCT.md"
check_file "CODEOWNERS"
check_file ".github/dependabot.yml"

# Verify the main branch ruleset exists
echo "  Checking main branch ruleset..."
existing=$(gh_api GET "/repos/$ORG/$REPO_NAME/rulesets") || existing='[]'
if echo "$existing" | jq -e --arg n "$RULESET_NAME" '.[] | select(.name==$n)' > /dev/null; then
  echo "  [OK]   Ruleset '$RULESET_NAME' is active"
else
  echo "  [FAIL] Ruleset '$RULESET_NAME' NOT FOUND. Run ./04-protect-main.sh first."
  blockers=$((blockers + 1))
fi

# Verify PVR
echo "  Checking Private Vulnerability Reporting..."
if gh_api GET "/repos/$ORG/$REPO_NAME/private-vulnerability-reporting" >/dev/null 2>&1; then
  pvr_state=$(gh_api GET "/repos/$ORG/$REPO_NAME/private-vulnerability-reporting" | jq -r '.enabled // false')
  if [[ "$pvr_state" == "true" ]]; then
    echo "  [OK]   PVR is enabled"
  else
    echo "  [FAIL] PVR is not enabled. Run ./03-enable-security.sh"
    blockers=$((blockers + 1))
  fi
else
  echo "  [WARN] Could not verify PVR state"
fi

echo

if [[ $blockers -gt 0 ]]; then
  echo "REFUSED: $blockers blocker(s) found above."
  echo "Fix them, then re-run this script."
  exit 1
fi

echo "All checks passed."
echo
echo "This will make $ORG/$REPO_NAME PUBLIC."
echo "Once public, the repo is visible to everyone on the internet."
echo "Make sure there are no secrets in the git history."
echo
echo "Recommended check before continuing:"
echo "  git log --all --full-history --source -p | grep -iE '(token|secret|api[_-]?key|password)' | head -20"
echo
read -r -p "Type MAKE_PUBLIC (uppercase) to confirm: " confirm

if [[ "$confirm" != "MAKE_PUBLIC" ]]; then
  echo "Aborted. Repo remains private."
  exit 1
fi

# Flip visibility
body='{"private": false, "visibility": "public"}'
gh_api PATCH "/repos/$ORG/$REPO_NAME" "$body" > /dev/null

echo
echo "$ORG/$REPO_NAME is now PUBLIC."
echo "Verify in the UI: https://github.com/$ORG/$REPO_NAME"
echo
echo "Suggested next steps:"
echo "  1. Submit to OpenSSF Best Practices: https://www.bestpractices.dev/projects/new"
echo "  2. Add OpenSSF Scorecard workflow to .github/workflows/scorecard.yml"
echo "  3. Submit to Claude Code plugin marketplace"
