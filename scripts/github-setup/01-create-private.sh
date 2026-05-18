#!/usr/bin/env bash
# 01-create-private.sh — Create the repo as PRIVATE first.
# Idempotent: if the repo already exists, just prints "exists" and returns.
#
# Usage: ./01-create-private.sh
#        REPO_NAME=other-repo ./01-create-private.sh
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gh-curl.sh
. "$SCRIPT_DIR/lib/gh-curl.sh"
load_config "${CONFIG_FILE:-$SCRIPT_DIR/repo-config.env}"

echo "==> Step 01: Create repository $ORG/$REPO_NAME as private"

# Check if it already exists
if gh_api GET "/repos/$ORG/$REPO_NAME" >/dev/null 2>&1; then
  echo "  Repository $ORG/$REPO_NAME already exists. Skipping create."
  exit 0
fi

# Create as private
body=$(jq -n \
  --arg name "$REPO_NAME" \
  --arg desc "$REPO_DESCRIPTION" \
  --arg home "$REPO_HOMEPAGE" \
  '{
    name: $name,
    description: $desc,
    homepage: $home,
    private: true,
    visibility: "private",
    has_issues: true,
    has_projects: false,
    has_wiki: false,
    has_discussions: false,
    auto_init: false,
    license_template: "apache-2.0"
  }')

gh_api POST "/orgs/$ORG/repos" "$body" > /dev/null
echo "  Created $ORG/$REPO_NAME as private."
echo "  Next: run ./02-set-metadata.sh"
