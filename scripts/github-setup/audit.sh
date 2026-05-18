#!/usr/bin/env bash
# audit.sh — Check current repo state against config and report drift.
# Exit codes: 0 = in sync, 1 = drift found, 2 = error.
#
# Usage: ./audit.sh                 # uses repo-config.env
#        ./audit.sh --json          # output as JSON for CI consumption
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/gh-curl.sh"
load_config "${CONFIG_FILE:-$SCRIPT_DIR/repo-config.env}"

JSON_OUTPUT="false"
[[ "${1:-}" == "--json" ]] && JSON_OUTPUT="true"

drift_count=0
drift_items='[]'

report_drift() {
  local field="$1" expected="$2" actual="$3"
  drift_count=$((drift_count + 1))
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    drift_items=$(echo "$drift_items" | jq \
      --arg f "$field" --arg e "$expected" --arg a "$actual" \
      '. + [{field: $f, expected: $e, actual: $a}]')
  else
    printf "  DRIFT  %-50s expected=%s actual=%s\n" "$field" "$expected" "$actual"
  fi
}

report_ok() {
  local field="$1"
  if [[ "$JSON_OUTPUT" == "false" ]]; then
    printf "  OK     %s\n" "$field"
  fi
}

# Fetch current state
if [[ "$JSON_OUTPUT" == "false" ]]; then
  echo "==> Auditing $ORG/$REPO_NAME against repo-config.env"
fi

repo=$(gh_api GET "/repos/$ORG/$REPO_NAME") || {
  echo "ERROR: Repo $ORG/$REPO_NAME not found." >&2
  exit 2
}

# Check basic fields
for pair in \
  "has_issues:$HAS_ISSUES" \
  "has_wiki:$HAS_WIKI" \
  "has_discussions:$HAS_DISCUSSIONS" \
  "allow_squash_merge:$ALLOW_SQUASH_MERGE" \
  "allow_merge_commit:$ALLOW_MERGE_COMMIT" \
  "allow_rebase_merge:$ALLOW_REBASE_MERGE" \
  "allow_auto_merge:$ALLOW_AUTO_MERGE" \
  "delete_branch_on_merge:$DELETE_BRANCH_ON_MERGE" \
  "web_commit_signoff_required:$WEB_COMMIT_SIGNOFF_REQUIRED"; do
  field="${pair%%:*}"
  expected=$(to_bool "${pair##*:}")
  actual=$(echo "$repo" | jq -r ".$field")
  if [[ "$actual" != "$expected" ]]; then
    report_drift "repo.$field" "$expected" "$actual"
  else
    report_ok "repo.$field"
  fi
done

# Check default branch
db_expected="$DEFAULT_BRANCH"
db_actual=$(echo "$repo" | jq -r '.default_branch')
if [[ "$db_actual" != "$db_expected" ]]; then
  report_drift "repo.default_branch" "$db_expected" "$db_actual"
else
  report_ok "repo.default_branch"
fi

# Security & analysis
for sa_field in secret_scanning secret_scanning_push_protection; do
  sa_actual=$(echo "$repo" | jq -r ".security_and_analysis.${sa_field}.status // \"unset\"")
  config_var="ENABLE_$(echo "$sa_field" | tr '[:lower:]' '[:upper:]')"
  expected=$([ "$(to_bool "${!config_var:-true}")" == "true" ] && echo "enabled" || echo "disabled")
  if [[ "$sa_actual" != "$expected" ]]; then
    report_drift "security.$sa_field" "$expected" "$sa_actual"
  else
    report_ok "security.$sa_field"
  fi
done

# Actions workflow permissions
wf=$(gh_api GET "/repos/$ORG/$REPO_NAME/actions/permissions/workflow") || wf='{}'
wf_perms=$(echo "$wf" | jq -r '.default_workflow_permissions // "unset"')
if [[ "$wf_perms" != "$ACTIONS_DEFAULT_TOKEN_PERMISSIONS" ]]; then
  report_drift "actions.default_workflow_permissions" "$ACTIONS_DEFAULT_TOKEN_PERMISSIONS" "$wf_perms"
else
  report_ok "actions.default_workflow_permissions"
fi

# Main branch ruleset
rs=$(gh_api GET "/repos/$ORG/$REPO_NAME/rulesets") || rs='[]'
if echo "$rs" | jq -e --arg n "$RULESET_NAME" '.[] | select(.name==$n)' >/dev/null; then
  report_ok "ruleset.$RULESET_NAME exists"
  rid=$(echo "$rs" | jq -r --arg n "$RULESET_NAME" '.[] | select(.name==$n) | .id')
  detail=$(gh_api GET "/repos/$ORG/$REPO_NAME/rulesets/$rid")
  for rule_type in deletion non_fast_forward required_linear_history pull_request; do
    if echo "$detail" | jq -e --arg t "$rule_type" '.rules[] | select(.type==$t)' >/dev/null; then
      report_ok "ruleset.rules.$rule_type"
    else
      report_drift "ruleset.rules.$rule_type" "present" "missing"
    fi
  done
else
  report_drift "ruleset.$RULESET_NAME" "exists" "missing"
fi

# Tag ruleset
if echo "$rs" | jq -e --arg n "$TAG_RULESET_NAME" '.[] | select(.name==$n)' >/dev/null; then
  report_ok "tag_ruleset.$TAG_RULESET_NAME exists"
else
  report_drift "tag_ruleset.$TAG_RULESET_NAME" "exists" "missing"
fi

# Visibility (warn only, not always drift)
if [[ "$TARGET_VISIBILITY" == "public" ]]; then
  vis=$(echo "$repo" | jq -r '.visibility')
  if [[ "$vis" == "private" ]]; then
    if [[ "$JSON_OUTPUT" == "false" ]]; then
      echo "  WARN   Repo is still private (run ./99-make-public.sh when ready)"
    fi
  fi
fi

# Final output
if [[ "$JSON_OUTPUT" == "true" ]]; then
  jq -n \
    --arg repo "$ORG/$REPO_NAME" \
    --arg ts "$(date -u +%FT%TZ)" \
    --argjson drift "$drift_items" \
    --argjson count "$drift_count" \
    '{
      repo: $repo,
      audited_at: $ts,
      drift_count: $count,
      drift: $drift,
      in_sync: ($count == 0)
    }'
else
  echo
  if [[ $drift_count -eq 0 ]]; then
    echo "$ORG/$REPO_NAME in sync with config."
  else
    echo "$ORG/$REPO_NAME has $drift_count drift item(s)."
  fi
fi

exit $([ $drift_count -eq 0 ] && echo 0 || echo 1)
