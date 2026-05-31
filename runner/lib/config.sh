#!/usr/bin/env bash
# runner/lib/config.sh — minimal TOML reader for tdd-pack.toml
#
# Sourced (not exec'd) by runner scripts that need config values.
# Supports the subset of TOML this pack uses:
#   - [section] headers
#   - key = scalar (string with optional quotes; integer; bool)
#   - # comments (line-start or inline after value)
#
# Does NOT support: nested tables, dotted keys, arrays, inline tables,
# multi-line strings, escape sequences. Not a general-purpose parser.
#
# Usage:
#   . runner/lib/config.sh
#   value=$(cfg_get "${CONFIG}" "review.max_rounds" "5")
#
# Caches per (path, section.key) within a single shell invocation to
# avoid re-parsing the file for every lookup.

# Idempotent guard so multiple sources don't redeclare the cache.
if [[ -z "${__PRILIVE_CFG_LIB_LOADED:-}" ]]; then
  __PRILIVE_CFG_LIB_LOADED=1
  declare -gA __CFG_CACHE=()
fi

cfg_get() {
  local config_path="$1" full_key="$2" default="${3:-}"
  local section="${full_key%.*}"
  local key="${full_key##*.}"
  local cache_key="${config_path}::${section}.${key}"

  # Return cached value if we've already looked this one up.
  if [[ -n "${__CFG_CACHE[${cache_key}]+set}" ]]; then
    printf '%s\n' "${__CFG_CACHE[${cache_key}]}"
    return 0
  fi

  if [[ ! -f "${config_path}" ]]; then
    __CFG_CACHE[${cache_key}]="${default}"
    printf '%s\n' "${default}"
    return 0
  fi

  local val
  val=$(awk -v section="${section}" -v key="${key}" '
    BEGIN { in_section = 0 }
    /^\[.*\]/ { in_section = ($0 == "[" section "]"); next }
    in_section && $1 == key && $2 == "=" {
      line = $0
      sub(/^[^=]*=[ \t]*/, "", line)
      sub(/[ \t]*#.*/, "", line)
      gsub(/^"|"$/, "", line)
      sub(/[ \t]+$/, "", line)
      print line
      exit
    }
  ' "${config_path}")

  if [[ -n "${val}" ]]; then
    __CFG_CACHE[${cache_key}]="${val}"
    printf '%s\n' "${val}"
  else
    __CFG_CACHE[${cache_key}]="${default}"
    printf '%s\n' "${default}"
  fi
}

# Reset cache (for tests that need to re-read config after modification).
cfg_clear_cache() {
  __CFG_CACHE=()
}
