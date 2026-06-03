#!/usr/bin/env bash
# runner/lib/active-finding.sh — shared accessors for the
# .tdd/active-finding marker file. Source this from any hook or script
# that needs to read or validate the marker.
#
# v2.1 PR 8 ships this library + the helper scripts (finding-start /
# finish). v2.1 PR 8b adds Gate 1 which reads the marker via these
# accessors. v2.1 PR 8c adds Gate 3 which reads locked_test_paths
# from the marker.
#
# Marker file shape:
#   {
#     "schema_version": 1,
#     "finding_id": "R<n>-F<n>",
#     "mode": "green_fix",
#     "started_at": "<RFC3339Z timestamp>",
#     "red_proof": "<project-relative path to red-proof.md>",
#     "red_proof_hash": "sha256:<hex>"
#   }
#
# All accessors take an optional PROJECT_DIR arg and default to
# ${PROJECT_DIR:-$(pwd)} so callers don't have to repeat the lookup.

if [[ -z "${__PRILIVE_ACTIVE_FINDING_LIB_LOADED:-}" ]]; then
  __PRILIVE_ACTIVE_FINDING_LIB_LOADED=1
fi

# active_finding_path <project_dir?> → echoes the absolute marker path.
active_finding_path() {
  local project_dir="${1:-${PROJECT_DIR:-$(pwd)}}"
  echo "${project_dir}/.tdd/active-finding"
}

# active_finding_present <project_dir?> → exit 0 if marker exists, 1 otherwise.
active_finding_present() {
  local path
  path=$(active_finding_path "$@")
  [[ -f "${path}" ]]
}

# active_finding_field <key> <project_dir?> → echoes the field value or empty.
# Returns 1 if marker absent or jq missing.
active_finding_field() {
  local key="$1"
  local project_dir="${2:-${PROJECT_DIR:-$(pwd)}}"
  local path; path=$(active_finding_path "${project_dir}")
  [[ -f "${path}" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -r --arg k "$key" '.[$k] // empty' "${path}" 2>/dev/null
}

# active_finding_red_proof_hash_matches <expected_hash> <project_dir?>
# → exit 0 if marker exists AND red_proof_hash equals expected; 1 otherwise.
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
