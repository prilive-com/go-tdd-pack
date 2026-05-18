#!/usr/bin/env bash
# 03-enable-security.sh — Enable Dependabot alerts, security updates, secret
# scanning, push protection, and Private Vulnerability Reporting.
# Each endpoint is separate (no single body); idempotent.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/gh-curl.sh"
load_config "${CONFIG_FILE:-$SCRIPT_DIR/repo-config.env}"

echo "==> Step 03: Enable security features for $ORG/$REPO_NAME"

if [[ "$(to_bool "$ENABLE_DEPENDABOT_ALERTS")" == "true" ]]; then
  # PUT with empty body to enable; 204 No Content on success
  gh_api PUT "/repos/$ORG/$REPO_NAME/vulnerability-alerts" > /dev/null || \
    echo "  WARN: Dependabot alerts enable failed (may need GitHub Advanced Security)"
  echo "  Dependabot alerts: enabled"
fi

if [[ "$(to_bool "$ENABLE_DEPENDABOT_SECURITY_UPDATES")" == "true" ]]; then
  gh_api PUT "/repos/$ORG/$REPO_NAME/automated-security-fixes" > /dev/null || \
    echo "  WARN: Dependabot security updates enable failed"
  echo "  Dependabot security updates: enabled"
fi

if [[ "$(to_bool "$ENABLE_PVR")" == "true" ]]; then
  gh_api PUT "/repos/$ORG/$REPO_NAME/private-vulnerability-reporting" > /dev/null || \
    echo "  WARN: PVR enable failed (verify org allows PVR)"
  echo "  Private Vulnerability Reporting: enabled"
fi

# Secret scanning + push protection live under security_and_analysis on PATCH /repos
sec_body='{}'

if [[ "$(to_bool "$ENABLE_SECRET_SCANNING")" == "true" ]]; then
  sec_body=$(echo "$sec_body" | jq '. + {security_and_analysis: ((.security_and_analysis // {}) + {secret_scanning: {status: "enabled"}})}')
fi

if [[ "$(to_bool "$ENABLE_SECRET_SCANNING_PUSH_PROTECTION")" == "true" ]]; then
  sec_body=$(echo "$sec_body" | jq '. + {security_and_analysis: ((.security_and_analysis // {}) + {secret_scanning_push_protection: {status: "enabled"}})}')
fi

if [[ "$sec_body" != "{}" ]]; then
  gh_api PATCH "/repos/$ORG/$REPO_NAME" "$sec_body" > /dev/null || \
    echo "  WARN: secret scanning enable failed (may need GitHub Advanced Security for private repos)"
  echo "  Secret scanning + push protection: enabled (where supported)"
fi

# Verify final state
echo "  Verifying final security state:"
gh_api GET "/repos/$ORG/$REPO_NAME" | jq -r '.security_and_analysis // {} | to_entries[] | "    \(.key): \(.value.status // "unknown")"'

echo "  Next: run ./04-protect-main.sh (push code first if branch doesn't exist yet)"
