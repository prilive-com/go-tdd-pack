#!/usr/bin/env bash
# 08-apply-org-baseline.sh — Apply an org-level ruleset that protects the
# default branch of EVERY current and future repo in the org.
# Run once per org. Idempotent.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/gh-curl.sh"
load_config "${CONFIG_FILE:-$SCRIPT_DIR/repo-config.env}"

echo "==> Step 08: Apply org-level baseline ruleset to $ORG"
echo "    (protects default branch of all current and future repos)"

# Update org settings
org_body=$(jq -n \
  '{
    default_repository_permission: "read",
    members_can_create_repositories: false,
    members_can_create_public_repositories: true,
    members_can_create_private_repositories: true,
    web_commit_signoff_required: true
  }')

if gh_api PATCH "/orgs/$ORG" "$org_body" > /dev/null 2>&1; then
  echo "  Org settings updated."
else
  echo "  WARN: Org settings update failed (you may not be an org owner)."
fi

# Org-level ruleset for default branches
org_ruleset_body='{
  "name": "org-balanced-default-branches",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [
    {
      "actor_type": "OrganizationAdmin",
      "actor_id": 1,
      "bypass_mode": "pull_request"
    }
  ],
  "conditions": {
    "repository_name": {
      "include": ["~ALL"],
      "exclude": [".github"]
    },
    "ref_name": {
      "include": ["~DEFAULT_BRANCH"],
      "exclude": []
    }
  },
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "required_linear_history"},
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "require_code_owner_review": false,
        "required_review_thread_resolution": true,
        "allowed_merge_methods": ["squash"]
      }
    }
  ]
}'

existing=$(gh_api GET "/orgs/$ORG/rulesets") || existing='[]'
rid=$(echo "$existing" | jq -r '.[] | select(.name=="org-balanced-default-branches") | .id // empty')

if [[ -n "$rid" ]]; then
  echo "  Org ruleset exists (id $rid); updating..."
  gh_api PUT "/orgs/$ORG/rulesets/$rid" "$org_ruleset_body" > /dev/null
else
  echo "  Creating org-level ruleset..."
  gh_api POST "/orgs/$ORG/rulesets" "$org_ruleset_body" > /dev/null
fi

echo "  Org-level baseline applied. All current and future $ORG repos now have:"
echo "    - default branch cannot be deleted or force-pushed"
echo "    - linear history required"
echo "    - PR required (0 reviewers, squash merge)"
echo "    - conversation resolution required"
echo "  Per-repo rulesets layer on top of this (e.g., status checks)."
