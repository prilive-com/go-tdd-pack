#!/usr/bin/env bash
# runner/lib/active-finding.sh — shared accessors for the active-finding
# marker. Source this from any hook or script that needs to read or
# validate the marker.
#
# v2.1 PR 8     — ships v1 schema at .tdd/active-finding.
# v2.3 slice 1  — adds v2 schema at .tdd/findings/active.json (FDTDD
#                 Stage 1). Backward-compat reads still see the v1
#                 path; writes always go to v2.
#
# Marker schema versions:
#
#   v1 (schema_version=1):
#     { schema_version, finding_id, mode, started_at,
#       red_proof, red_proof_hash }
#
#   v2 (schema_version=2):
#     { schema_version, finding_id, started_at, tier, phase,
#       red_proof, red_proof_hash, red_proof_accepted,
#       red_proof_record, test_files, prod_files,
#       red_accepted_at, green_started_at, closed_at,
#       amendments }
#
# Contract: docs/FDTDD-MARKER-CONTRACT.md.
# Schema:   schemas/active-finding.schema.json.
#
# All accessors take an optional PROJECT_DIR arg and default to
# ${PROJECT_DIR:-$(pwd)} so callers don't have to repeat the lookup.

if [[ -z "${__PRILIVE_ACTIVE_FINDING_LIB_LOADED:-}" ]]; then
  __PRILIVE_ACTIVE_FINDING_LIB_LOADED=1
fi

# active_finding_v2_path <project_dir?> → echoes the v2 canonical path.
# This is the WRITE target. New markers always land here.
active_finding_v2_path() {
  local project_dir="${1:-${PROJECT_DIR:-$(pwd)}}"
  echo "${project_dir}/.tdd/findings/active.json"
}

# active_finding_legacy_path <project_dir?> → echoes the v1 legacy path.
# This is a READ fallback for adopters upgrading from v2.1/v2.2.
# Helpers MUST NOT write here.
active_finding_legacy_path() {
  local project_dir="${1:-${PROJECT_DIR:-$(pwd)}}"
  echo "${project_dir}/.tdd/active-finding"
}

# active_finding_path <project_dir?> → echoes the FIRST EXISTING marker
# path: v2 if present, else legacy if present, else the v2 path (for
# the absent case). Existing callers from v2.1 PR 8 keep their semantics
# because v1 markers continue to be readable through this accessor.
active_finding_path() {
  local project_dir="${1:-${PROJECT_DIR:-$(pwd)}}"
  local v2 v1
  v2=$(active_finding_v2_path "${project_dir}")
  v1=$(active_finding_legacy_path "${project_dir}")
  if [[ -f "${v2}" ]]; then echo "${v2}"; return; fi
  if [[ -f "${v1}" ]]; then echo "${v1}"; return; fi
  echo "${v2}"
}

# active_finding_kind <project_dir?> → echoes "v2", "v1", or "absent".
# Lets callers branch without re-statting both paths.
active_finding_kind() {
  local project_dir="${1:-${PROJECT_DIR:-$(pwd)}}"
  if [[ -f "$(active_finding_v2_path "${project_dir}")" ]]; then
    echo "v2"
  elif [[ -f "$(active_finding_legacy_path "${project_dir}")" ]]; then
    echo "v1"
  else
    echo "absent"
  fi
}

# active_finding_present <project_dir?> → exit 0 if marker exists (v1
# or v2), 1 otherwise.
active_finding_present() {
  local path
  path=$(active_finding_path "$@")
  [[ -f "${path}" ]]
}

# active_finding_field <key> <project_dir?> → echoes the raw field value
# from whichever marker exists. Returns empty for absent fields (v1
# markers do not have v2-only fields). Returns 1 if marker absent or
# jq missing. Use the v2-default accessors below for v2-only fields
# you need a typed default for.
active_finding_field() {
  local key="$1"
  local project_dir="${2:-${PROJECT_DIR:-$(pwd)}}"
  local path; path=$(active_finding_path "${project_dir}")
  [[ -f "${path}" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -r --arg k "$key" '.[$k] // empty' "${path}" 2>/dev/null
}

# active_finding_schema_version <project_dir?> → echoes "1", "2", or
# empty. Empty when marker absent OR schema_version field absent.
active_finding_schema_version() {
  active_finding_field schema_version "$@"
}

# active_finding_phase <project_dir?> → echoes one of red/green/refactor/
# closed. Per docs/FDTDD-MARKER-CONTRACT.md backward-compat rule, a v1
# marker reads as "red" because v2.1-era markers had no mechanical Red
# proof, so the conservative default until accept-red runs is "red".
# Returns 1 if marker absent.
active_finding_phase() {
  local project_dir="${1:-${PROJECT_DIR:-$(pwd)}}"
  local kind; kind=$(active_finding_kind "${project_dir}")
  case "${kind}" in
    v2)
      active_finding_field phase "${project_dir}"
      ;;
    v1)
      echo "red"
      ;;
    *)
      return 1
      ;;
  esac
}

# active_finding_red_proof_accepted <project_dir?> → echoes "true" or
# "false". v1 markers default to "false" (no mechanical Red proof in
# v2.1 era → conservative default for Gate 1).
# Returns 1 if marker absent.
active_finding_red_proof_accepted() {
  local project_dir="${1:-${PROJECT_DIR:-$(pwd)}}"
  local kind; kind=$(active_finding_kind "${project_dir}")
  case "${kind}" in
    v2)
      local val; val=$(active_finding_field red_proof_accepted "${project_dir}")
      [[ "${val}" == "true" ]] && echo "true" || echo "false"
      ;;
    v1)
      echo "false"
      ;;
    *)
      return 1
      ;;
  esac
}

# active_finding_test_files <project_dir?> → echoes the test_files JSON
# array (one element per line, jq -r). v1 markers default to empty.
# Returns 1 if marker absent.
active_finding_test_files() {
  local project_dir="${1:-${PROJECT_DIR:-$(pwd)}}"
  local kind; kind=$(active_finding_kind "${project_dir}")
  case "${kind}" in
    v2)
      local path; path=$(active_finding_v2_path "${project_dir}")
      command -v jq >/dev/null 2>&1 || return 1
      jq -r '.test_files[]? // empty' "${path}" 2>/dev/null
      ;;
    v1)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# active_finding_prod_files <project_dir?> → echoes the prod_files JSON
# array (one element per line). v1 markers default to empty.
active_finding_prod_files() {
  local project_dir="${1:-${PROJECT_DIR:-$(pwd)}}"
  local kind; kind=$(active_finding_kind "${project_dir}")
  case "${kind}" in
    v2)
      local path; path=$(active_finding_v2_path "${project_dir}")
      command -v jq >/dev/null 2>&1 || return 1
      jq -r '.prod_files[]? // empty' "${path}" 2>/dev/null
      ;;
    v1)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# active_finding_red_proof_hash_matches <expected_hash> <project_dir?>
# → exit 0 if marker exists AND red_proof_hash equals expected; 1 otherwise.
# Works for both v1 and v2 — both schemas carry red_proof_hash.
active_finding_red_proof_hash_matches() {
  local expected="$1"
  local project_dir="${2:-${PROJECT_DIR:-$(pwd)}}"
  local actual
  actual=$(active_finding_field red_proof_hash "${project_dir}") || return 1
  [[ -n "${actual}" ]] || return 1
  [[ "${actual}" == "${expected}" ]]
}

# active_finding_compute_red_proof_hash <red_proof_path>
# → echoes "sha256:<hex>" of the file. Returns 1 on error.
active_finding_compute_red_proof_hash() {
  local file="$1"
  [[ -f "${file}" ]] || return 1
  local hex
  if command -v sha256sum >/dev/null 2>&1; then
    hex=$(sha256sum "${file}" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    hex=$(shasum -a 256 "${file}" | awk '{print $1}')
  else
    return 1
  fi
  [[ -n "${hex}" ]] || return 1
  echo "sha256:${hex}"
}

# active_finding_validate_id <finding_id>
# → exit 0 if id matches R<n>-F<n> format, 1 otherwise.
active_finding_validate_id() {
  local id="$1"
  [[ "${id}" =~ ^R[0-9]+-F[0-9]+$ ]]
}

# active_finding_validate_tier <tier>
# → exit 0 if tier matches the v2 schema enum, 1 otherwise.
active_finding_validate_tier() {
  local t="$1"
  case "${t}" in
    tier1|tier2|tier3|untiered) return 0 ;;
    *) return 1 ;;
  esac
}
