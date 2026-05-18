#!/usr/bin/env bash
# 05-protect-tags.sh — Create a ruleset that prevents release tags (v*) from
# being deleted or force-pushed. Once you tag v2.0.0, it stays immutable.
#
# Idempotent: looks up by name.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/gh-curl.sh"
load_config "${CONFIG_FILE:-$SCRIPT_DIR/repo-config.env}"

echo "==> Step 05: Apply release tag ruleset for $ORG/$REPO_NAME"

ruleset_body=$(jq -n \
  --arg name "$TAG_RULESET_NAME" \
  --arg pattern "$TAG_RULESET_PATTERN" \
  '{
    name: $name,
    target: "tag",
    enforcement: "active",
    bypass_actors: [
      {
        "actor_type": "RepositoryRole",
        "actor_id": 5,
        "bypass_mode": "always"
      }
    ],
    conditions: {
      ref_name: {
        include: [$pattern],
        exclude: []
      }
    },
    rules: [
      {"type": "deletion"},
      {"type": "non_fast_forward"}
    ]
  }')

existing=$(gh_api GET "/repos/$ORG/$REPO_NAME/rulesets") || existing='[]'
rid=$(echo "$existing" | jq -r --arg n "$TAG_RULESET_NAME" '.[] | select(.name==$n) | .id // empty')

if [[ -n "$rid" ]]; then
  echo "  Tag ruleset '$TAG_RULESET_NAME' exists (id $rid); updating..."
  gh_api PUT "/repos/$ORG/$REPO_NAME/rulesets/$rid" "$ruleset_body" > /dev/null
else
  echo "  Creating tag ruleset '$TAG_RULESET_NAME'..."
  gh_api POST "/repos/$ORG/$REPO_NAME/rulesets" "$ruleset_body" > /dev/null
fi

echo "  Tag protection applied: tags matching '$TAG_RULESET_PATTERN' cannot be deleted or force-pushed."
echo "  Next: run ./06-set-actions-permissions.sh"
