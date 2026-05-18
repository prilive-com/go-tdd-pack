#!/usr/bin/env bash
# 07-enable-codeql.sh — Enable CodeQL default setup (no workflow file needed).
# Tolerates 422 if no Go source code exists yet (re-run after pushing code).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/gh-curl.sh"
load_config "${CONFIG_FILE:-$SCRIPT_DIR/repo-config.env}"

echo "==> Step 07: Enable CodeQL default setup for $ORG/$REPO_NAME"

if [[ "$(to_bool "$ENABLE_CODEQL")" != "true" ]]; then
  echo "  CodeQL disabled in config; skipping."
  exit 0
fi

IFS=',' read -ra LANG_ARRAY <<< "$CODEQL_LANGUAGES"
languages_json=$(printf '%s\n' "${LANG_ARRAY[@]}" | jq -R . | jq -s .)

body=$(jq -n \
  --argjson langs "$languages_json" \
  '{
    state: "configured",
    query_suite: "default",
    languages: $langs
  }')

if gh_api PATCH "/repos/$ORG/$REPO_NAME/code-scanning/default-setup" "$body" > /dev/null 2>&1; then
  echo "  CodeQL enabled for languages: $CODEQL_LANGUAGES"
else
  echo "  WARN: CodeQL enable failed (likely no code yet in supported languages)."
  echo "  Re-run this script after pushing Go code."
fi

echo "  Next: optionally run ./08-apply-org-baseline.sh for org-wide ruleset"
echo "        otherwise: push your code, then run ./99-make-public.sh when ready"
