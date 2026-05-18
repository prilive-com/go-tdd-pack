#!/usr/bin/env bash
# 02-set-metadata.sh — Set repo description, homepage, topics, merge policy,
# features (issues/projects/wiki/discussions). Idempotent.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/gh-curl.sh"
load_config "${CONFIG_FILE:-$SCRIPT_DIR/repo-config.env}"

echo "==> Step 02: Set metadata for $ORG/$REPO_NAME"

# Update repo settings (PATCH is idempotent)
body=$(jq -n \
  --arg desc "$REPO_DESCRIPTION" \
  --arg home "$REPO_HOMEPAGE" \
  --arg branch "$DEFAULT_BRANCH" \
  --arg sqtitle "$SQUASH_MERGE_COMMIT_TITLE" \
  --arg sqmsg "$SQUASH_MERGE_COMMIT_MESSAGE" \
  --argjson has_issues "$(to_bool "$HAS_ISSUES")" \
  --argjson has_projects "$(to_bool "$HAS_PROJECTS")" \
  --argjson has_wiki "$(to_bool "$HAS_WIKI")" \
  --argjson has_discussions "$(to_bool "$HAS_DISCUSSIONS")" \
  --argjson allow_squash "$(to_bool "$ALLOW_SQUASH_MERGE")" \
  --argjson allow_merge "$(to_bool "$ALLOW_MERGE_COMMIT")" \
  --argjson allow_rebase "$(to_bool "$ALLOW_REBASE_MERGE")" \
  --argjson allow_auto "$(to_bool "$ALLOW_AUTO_MERGE")" \
  --argjson delete_branch "$(to_bool "$DELETE_BRANCH_ON_MERGE")" \
  --argjson web_signoff "$(to_bool "$WEB_COMMIT_SIGNOFF_REQUIRED")" \
  '{
    description: $desc,
    homepage: $home,
    default_branch: $branch,
    has_issues: $has_issues,
    has_projects: $has_projects,
    has_wiki: $has_wiki,
    has_discussions: $has_discussions,
    allow_squash_merge: $allow_squash,
    allow_merge_commit: $allow_merge,
    allow_rebase_merge: $allow_rebase,
    allow_auto_merge: $allow_auto,
    delete_branch_on_merge: $delete_branch,
    allow_update_branch: true,
    web_commit_signoff_required: $web_signoff,
    squash_merge_commit_title: $sqtitle,
    squash_merge_commit_message: $sqmsg
  }')

gh_api PATCH "/repos/$ORG/$REPO_NAME" "$body" > /dev/null
echo "  Updated general settings."

# Set topics (PUT replaces full list, so order matters in IFS split)
IFS=',' read -ra TOPIC_ARRAY <<< "$REPO_TOPICS"
topics_json=$(printf '%s\n' "${TOPIC_ARRAY[@]}" | jq -R . | jq -s .)
topics_body=$(jq -n --argjson names "$topics_json" '{names: $names}')
gh_api PUT "/repos/$ORG/$REPO_NAME/topics" "$topics_body" > /dev/null
echo "  Set ${#TOPIC_ARRAY[@]} topics."

echo "  Next: run ./03-enable-security.sh"
