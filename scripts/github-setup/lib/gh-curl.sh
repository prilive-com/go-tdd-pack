#!/usr/bin/env bash
# lib/gh-curl.sh — Shared helpers for the GitHub setup scripts.
# Source this file from each script: . "$(dirname "$0")/lib/gh-curl.sh"
#
# Requires: bash 4+, curl, jq.
# Authenticates via $GH_BASELINE_TOKEN (fine-grained PAT).
# Honors GitHub rate limits and retries 429/5xx with exponential backoff.

set -Eeuo pipefail

# ----- Configuration -----
API="${GH_API_BASE:-https://api.github.com}"
# Bump GH_API_VERSION when GitHub releases a newer stable API version with
# features you need. Older versions usually keep working under the
# deprecation window.
GH_API_VERSION="${GH_API_VERSION:-2026-03-10}"
APIVER="X-GitHub-Api-Version: ${GH_API_VERSION}"
LOG_DIR="${LOG_DIR:-./logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_FILE:-$LOG_DIR/github-setup-$(date -u +%Y-%m-%dT%H-%M-%SZ).jsonl}"

# ----- Sanity checks -----
require_token() {
  if [[ -z "${GH_BASELINE_TOKEN:-}" ]]; then
    echo "ERROR: GH_BASELINE_TOKEN is not set. See RUNBOOK.md §3 for how to create one." >&2
    exit 1
  fi
}

require_tools() {
  for tool in curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "ERROR: $tool is required but not installed." >&2
      exit 1
    fi
  done
}

# ----- Logging -----
log_event() {
  # Args: op url status body_excerpt
  local op="$1" url="$2" status="$3" body="$4"
  jq -cn \
    --arg ts "$(date -u +%FT%TZ)" \
    --arg op "$op" \
    --arg url "$url" \
    --arg status "$status" \
    --arg body "$body" \
    '{ts:$ts,op:$op,url:$url,status:$status,body:$body}' \
    >> "$LOG_FILE"
}

# ----- Core API call -----
# Usage: gh_api METHOD PATH [JSON_BODY]
# Returns: response body on stdout. Non-2xx exit code = 1.
gh_api() {
  local method="$1" path="$2" body="${3:-}"
  local tmp code retry
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' RETURN

  for try in 1 2 3 4 5; do
    if [[ -n "$body" ]]; then
      code=$(curl -sS -o "$tmp" -w '%{http_code}' \
        -X "$method" \
        -H "Authorization: Bearer $GH_BASELINE_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "$APIVER" \
        -H "Content-Type: application/json" \
        --data "$body" \
        "$API$path") || code="000"
    else
      code=$(curl -sS -o "$tmp" -w '%{http_code}' \
        -X "$method" \
        -H "Authorization: Bearer $GH_BASELINE_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "$APIVER" \
        "$API$path") || code="000"
    fi

    case "$code" in
      429)
        # Rate limited — honor Retry-After if present, else exponential backoff
        retry=$(curl -sI \
          -H "Authorization: Bearer $GH_BASELINE_TOKEN" \
          "$API$path" 2>/dev/null \
          | awk 'BEGIN{IGNORECASE=1}/^retry-after:/{print $2+0}' || echo "")
        sleep "${retry:-$((try * 5))}"
        continue
        ;;
      5[0-9][0-9])
        # Server error — retry with backoff
        sleep $((try * 2))
        continue
        ;;
      *)
        # 2xx success, or 4xx client error (don't retry 4xx)
        break
        ;;
    esac
  done

  log_event "$method" "$path" "$code" "$(head -c 400 "$tmp" | tr '\n' ' ')"

  if [[ "${code:0:1}" != "2" ]]; then
    echo "ERROR: $method $path → HTTP $code" >&2
    cat "$tmp" >&2
    cat "$tmp"
    return 1
  fi

  cat "$tmp"
}

# ----- Bool to JSON helper -----
# bash booleans → JSON booleans
to_bool() {
  case "$1" in
    true|True|TRUE|1|yes|on) echo "true" ;;
    *) echo "false" ;;
  esac
}

# ----- Config loader -----
load_config() {
  local config_file="${1:-./repo-config.env}"
  if [[ ! -f "$config_file" ]]; then
    echo "ERROR: Config file not found: $config_file" >&2
    echo "Copy repo-config.env and edit it for your repo." >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  set -a
  . "$config_file"
  set +a
}

# ----- Initial checks (always run when this file is sourced) -----
require_token
require_tools
