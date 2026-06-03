#!/usr/bin/env bash
# runner/lib/codex-capabilities.sh — detect what the installed `codex` CLI
# supports. Caches results per-version in .tdd/.codex-capabilities.json so
# subsequent invocations don't re-run `codex --help`.
#
# Sourced (not exec'd) by codex-round1.sh and codex-round-n.sh. Exposes:
#
#   codex_detect_capabilities <project_dir>
#     → populates the cache. Idempotent. Returns 0 even if codex isn't
#       installed (writes an explicit "unavailable" marker).
#
#   codex_cap_supports <flag>
#     → echoes "true" or "false". Defaults to "false" if no cache or
#       codex unavailable.
#
# Supported capability flags (each is a JSON bool in the cache file):
#   supports_json                — codex exec emits JSONL events on stdout
#   supports_output_last_message — -o flag captures the final message
#   supports_output_schema_exec  — --output-schema on round 1
#   supports_output_schema_resume— --output-schema survives `codex exec resume`
#                                  (openai/codex#14343 — false on 0.125-0.129;
#                                  detected dynamically because future
#                                  releases may fix it)
#   supports_ignore_user_config  — --ignore-user-config skips $CODEX_HOME/
#                                  config.toml on a per-invocation basis
#                                  (v2.1 PR 7: MCP-detachment mechanism for
#                                  openai/codex#15451; --output-schema is
#                                  silently dropped when MCP servers are
#                                  active in user config)

if [[ -z "${__PRILIVE_CODEX_CAP_LIB_LOADED:-}" ]]; then
  __PRILIVE_CODEX_CAP_LIB_LOADED=1
fi

codex_detect_capabilities() {
  local project_dir="${1:-${PROJECT_DIR:-$(pwd)}}"
  local cache_path="${project_dir}/.tdd/.codex-capabilities.json"
  mkdir -p "$(dirname "${cache_path}")" 2>/dev/null

  if ! command -v codex >/dev/null 2>&1; then
    jq -n \
      --arg ts "$(date -u +%FT%TZ)" \
      '{available:false, detected_at:$ts, version:"", reason:"codex CLI not in PATH"}' \
      > "${cache_path}.tmp" 2>/dev/null && mv "${cache_path}.tmp" "${cache_path}"
    return 0
  fi

  local version
  version=$(codex --version 2>/dev/null | head -1 | tr -d '\n')
  if [[ -z "${version}" ]]; then
    jq -n \
      --arg ts "$(date -u +%FT%TZ)" \
      '{available:false, detected_at:$ts, version:"", reason:"codex --version failed"}' \
      > "${cache_path}.tmp" 2>/dev/null && mv "${cache_path}.tmp" "${cache_path}"
    return 0
  fi

  # Cache hit on same version?
  if [[ -f "${cache_path}" ]]; then
    local cached_version
    cached_version=$(jq -r '.version // empty' "${cache_path}" 2>/dev/null)
    if [[ "${cached_version}" == "${version}" ]]; then
      return 0
    fi
  fi

  # Re-detect. Run --help once per surface area.
  local exec_help resume_help
  exec_help=$(codex exec --help 2>&1 || true)
  resume_help=$(codex exec resume --help 2>&1 || true)

  local sj=false slm=false sse=false ssr=false siuc=false

  echo "${exec_help}"   | grep -q -- '--json'                 && sj=true
  echo "${exec_help}"   | grep -q -- '--output-last-message'  && slm=true
  echo "${exec_help}"   | grep -q -- '--output-schema'        && sse=true
  echo "${resume_help}" | grep -q -- '--output-schema'        && ssr=true
  echo "${exec_help}"   | grep -q -- '--ignore-user-config'   && siuc=true

  jq -n \
    --arg version "${version}" \
    --arg ts "$(date -u +%FT%TZ)" \
    --argjson sj "${sj}" \
    --argjson slm "${slm}" \
    --argjson sse "${sse}" \
    --argjson ssr "${ssr}" \
    --argjson siuc "${siuc}" \
    '{available:true,
      version:$version,
      detected_at:$ts,
      supports_json:$sj,
      supports_output_last_message:$slm,
      supports_output_schema_exec:$sse,
      supports_output_schema_resume:$ssr,
      supports_ignore_user_config:$siuc}' \
    > "${cache_path}.tmp" 2>/dev/null && mv "${cache_path}.tmp" "${cache_path}"
}

codex_cap_supports() {
  local cap="$1"
  local project_dir="${2:-${PROJECT_DIR:-$(pwd)}}"
  local cache_path="${project_dir}/.tdd/.codex-capabilities.json"
  if [[ ! -f "${cache_path}" ]]; then
    echo "false"
    return 0
  fi
  local val
  val=$(jq -r --arg c "$cap" '.[$c] // false' "${cache_path}" 2>/dev/null)
  if [[ "${val}" == "true" ]]; then
    echo "true"
  else
    echo "false"
  fi
}
