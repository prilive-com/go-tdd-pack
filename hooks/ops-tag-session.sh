#!/usr/bin/env bash
# hooks/ops-tag-session.sh
#
# v2.2 slice 6 — PostToolUse Bash hook. Detects auth / container_uid /
# config-changing commands and appends matching tags to
# .tdd/ops-triage/session-tags.txt. The triage hook (Layer 2) reads that
# file and (a) feeds it to the classifier as `recent_operation_tags`,
# (b) escalates `infra_mutation` to `destructive` when auth/UID tags
# are present (engine-side safety net for the LLM classifier).
#
# This is the specific fix for the original v2.2-motivating outage:
# a `chown -R 1000:1000` clobbered a container's required UID 1001,
# then a `docker compose --build` re-baked the broken state into the
# image. Each command alone was R2-ish; the combination was R3.
# After this hook fires on the chown (tagging the session
# "container_uid"), the triage hook escalates the subsequent build
# to destructive automatically.
#
# Patterns live in config/ops-session-tags.txt (user-owned). The pack
# itself ships zero opinionated patterns — only the .example file.
#
# Disabled-safe: PRILIVE_REVIEW_DISABLE=1 or [ops_triage] enabled=false
# → exit 0 immediately, no tag written.
#
# Tags are append-only within a session. No TTL in slice 6 — keeping
# the design simple. If stale tags cause unwanted escalations, future
# slices can add TTL or SessionStart-based clearing.

set -uo pipefail

[[ "${PRILIVE_REVIEW_DISABLE:-}" == "1" ]] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
TOML="${PROJECT_DIR}/tdd-pack.toml"
LIB="${CLAUDE_PLUGIN_ROOT:-${PROJECT_DIR}}/runner/lib"

if [[ -f "${LIB}/config.sh" ]]; then
  # shellcheck source=../runner/lib/config.sh
  . "${LIB}/config.sh"
else
  cfg_get() { echo "$3"; }
fi

ENABLED=$(cfg_get "${TOML}" "ops_triage.enabled" "false")
[[ "${ENABLED}" != "true" && "${PRILIVE_OPS_TRIAGE:-}" != "1" ]] && exit 0

MODE=$(cfg_get "${TOML}" "ops_triage.mode" "ask")
[[ "${MODE}" == "off" ]] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null || true)
[[ -z "${INPUT}" ]] && exit 0

TOOL=$(printf '%s' "${INPUT}" | jq -r '.tool_name // empty' 2>/dev/null)
[[ "${TOOL}" != "Bash" ]] && exit 0

CMD=$(printf '%s' "${INPUT}" | jq -r '.tool_input.command // empty' 2>/dev/null)
[[ -z "${CMD}" ]] && exit 0

PATTERNS="${PROJECT_DIR}/config/ops-session-tags.txt"
[[ -f "${PATTERNS}" ]] || exit 0   # no patterns file → no tagging

TAGS_DIR="${PROJECT_DIR}/.tdd/ops-triage"
TAGS_FILE="${TAGS_DIR}/session-tags.txt"
mkdir -p "${TAGS_DIR}" 2>/dev/null

# Walk the patterns file. Each non-comment line is `tag: regex`. Match
# the regex against the command; if it matches, append the tag to
# session-tags.txt (one tag per line). Same tag can be appended multiple
# times — the classifier deduplicates on its end.
while IFS= read -r line; do
  # skip blanks + comments (allow leading whitespace)
  [[ "${line}" =~ ^[[:space:]]*$ ]] && continue
  [[ "${line}" =~ ^[[:space:]]*# ]] && continue

  # split on the FIRST `:` to allow regexes that contain colons
  tag="${line%%:*}"
  rest="${line#*:}"
  # strip leading/trailing whitespace from tag + pattern
  tag="${tag#"${tag%%[![:space:]]*}"}"
  tag="${tag%"${tag##*[![:space:]]}"}"
  pat="${rest#"${rest%%[![:space:]]*}"}"
  pat="${pat%"${pat##*[![:space:]]}"}"

  [[ -z "${tag}" || -z "${pat}" ]] && continue

  if grep -Eq -- "${pat}" <<<"${CMD}" 2>/dev/null; then
    printf '%s\n' "${tag}" >> "${TAGS_FILE}" 2>/dev/null || true
  fi
done < "${PATTERNS}"

exit 0
