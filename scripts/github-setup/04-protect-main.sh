#!/usr/bin/env bash
# 04-protect-main.sh — Create or update the "balanced solo maintainer" ruleset
# for the default branch. Uses the modern Rulesets API (not legacy branch protection).
#
# Idempotent: looks up ruleset by name, PUT if exists, POST if not.
# Requires the default branch to exist (push at least one commit first).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/gh-curl.sh"
load_config "${CONFIG_FILE:-$SCRIPT_DIR/repo-config.env}"

echo "==> Step 04: Apply main branch ruleset for $ORG/$REPO_NAME"

# Verify default branch exists
if ! gh_api GET "/repos/$ORG/$REPO_NAME/branches/$DEFAULT_BRANCH" >/dev/null 2>&1; then
  echo "  ERROR: Default branch '$DEFAULT_BRANCH' does not exist."
  echo "  Push at least one commit to '$DEFAULT_BRANCH' before running this script."
  exit 1
fi

# Build required_status_checks array
status_checks_array='[]'
if [[ -n "${REQUIRED_STATUS_CHECKS:-}" ]]; then
  IFS=',' read -ra CHECKS <<< "$REQUIRED_STATUS_CHECKS"
  status_checks_array=$(printf '%s\n' "${CHECKS[@]}" | jq -R '{context: .}' | jq -s .)
fi

# Build bypass actors array (admin role can bypass via PR for emergencies)
bypass_actors='[]'
if [[ "$(to_bool "$RULESET_BYPASS_FOR_ADMIN")" == "true" ]]; then
  # actor_type "RepositoryRole" with actor_id 5 = Admin role
  # bypass_mode "pull_request" = can bypass only inside PRs (auditable)
  bypass_actors='[
    {
      "actor_type": "RepositoryRole",
      "actor_id": 5,
      "bypass_mode": "pull_request"
    }
  ]'
fi

# Build rules array. Order matches GitHub's expectation.
rules='[]'

# Always: prevent branch deletion and force-pushes
rules=$(echo "$rules" | jq '. + [{"type": "deletion"}, {"type": "non_fast_forward"}]')

# Optional: require signed commits (if all maintainer commits will be GPG-signed)
if [[ "$(to_bool "$RULESET_REQUIRE_SIGNATURES")" == "true" ]]; then
  rules=$(echo "$rules" | jq '. + [{"type": "required_signatures"}]')
fi

# Optional: require linear history (no merge commits)
if [[ "$(to_bool "$RULESET_REQUIRE_LINEAR_HISTORY")" == "true" ]]; then
  rules=$(echo "$rules" | jq '. + [{"type": "required_linear_history"}]')
fi

# Always: require pull request (with 0 reviewers for solo maintainer)
require_conv=$(to_bool "$RULESET_REQUIRE_CONVERSATION_RESOLUTION")
rules=$(echo "$rules" | jq \
  --argjson req_conv "$require_conv" \
  '. + [{
    "type": "pull_request",
    "parameters": {
      "required_approving_review_count": 0,
      "dismiss_stale_reviews_on_push": true,
      "require_code_owner_review": true,
      "require_last_push_approval": false,
      "required_review_thread_resolution": $req_conv,
      "allowed_merge_methods": ["squash"]
    }
  }]')

# Optional: require status checks if specified
if [[ -n "${REQUIRED_STATUS_CHECKS:-}" && "$status_checks_array" != "[]" ]]; then
  rules=$(echo "$rules" | jq \
    --argjson checks "$status_checks_array" \
    '. + [{
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": $checks
      }
    }]')
fi

# Build the full ruleset body
ruleset_body=$(jq -n \
  --arg name "$RULESET_NAME" \
  --argjson rules "$rules" \
  --argjson bypass "$bypass_actors" \
  '{
    name: $name,
    target: "branch",
    enforcement: "active",
    bypass_actors: $bypass,
    conditions: {
      ref_name: {
        include: ["~DEFAULT_BRANCH"],
        exclude: []
      }
    },
    rules: $rules
  }')

# Look up existing ruleset by name (idempotency)
existing=$(gh_api GET "/repos/$ORG/$REPO_NAME/rulesets") || existing='[]'
rid=$(echo "$existing" | jq -r --arg n "$RULESET_NAME" '.[] | select(.name==$n) | .id // empty')

if [[ -n "$rid" ]]; then
  echo "  Ruleset '$RULESET_NAME' exists (id $rid); updating..."
  gh_api PUT "/repos/$ORG/$REPO_NAME/rulesets/$rid" "$ruleset_body" > /dev/null
else
  echo "  Creating ruleset '$RULESET_NAME'..."
  gh_api POST "/repos/$ORG/$REPO_NAME/rulesets" "$ruleset_body" > /dev/null
fi

echo "  Ruleset applied."
echo "  Next: run ./05-protect-tags.sh"
