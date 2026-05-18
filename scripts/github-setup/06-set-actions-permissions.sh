#!/usr/bin/env bash
# 06-set-actions-permissions.sh — Set default workflow permissions for GITHUB_TOKEN
# to read-only and disallow Actions from approving PRs.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/gh-curl.sh"
load_config "${CONFIG_FILE:-$SCRIPT_DIR/repo-config.env}"

echo "==> Step 06: Set Actions workflow permissions for $ORG/$REPO_NAME"

body=$(jq -n \
  --arg perms "$ACTIONS_DEFAULT_TOKEN_PERMISSIONS" \
  --argjson can_approve "$(to_bool "$ACTIONS_CAN_APPROVE_PULL_REQUESTS")" \
  '{
    default_workflow_permissions: $perms,
    can_approve_pull_request_reviews: $can_approve
  }')

gh_api PUT "/repos/$ORG/$REPO_NAME/actions/permissions/workflow" "$body" > /dev/null

echo "  GITHUB_TOKEN default: $ACTIONS_DEFAULT_TOKEN_PERMISSIONS"
echo "  Actions can approve PRs: $(to_bool "$ACTIONS_CAN_APPROVE_PULL_REQUESTS")"
echo "  Next: run ./07-enable-codeql.sh"
