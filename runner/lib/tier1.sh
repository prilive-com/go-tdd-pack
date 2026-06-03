#!/usr/bin/env bash
# runner/lib/tier1.sh — Tier-1 path detector.
#
# Consults .tdd/tiers.toml (shipped in v2.1 PR 8) to decide whether a
# path or a set of changed paths is "Tier 1" — high-stakes code that
# warrants the more expensive review treatment (perspective-diverse
# ensemble in PR 9b, FDTDD Gate 1 in PR 8b).
#
# tiers.toml format (per .tdd/tiers.toml.example):
#   [tier1]
#   path_globs = ["internal/security/**", "migrations/**", ...]
#   allow_globs = []   # optional override list (non-Tier-1)
#
# Match semantics:
#   - Globs match against PROJECT_DIR-relative paths.
#   - ** matches any number of path components (including zero).
#   - * matches a single path component (no slashes).
#   - A path is Tier 1 if it matches ANY pattern in path_globs AND
#     does NOT match any pattern in allow_globs.
#
# Exposed functions (sourced, not exec'd):
#
#   tier1_config_present <project_dir?>
#     → exit 0 if .tdd/tiers.toml exists, 1 otherwise.
#
#   tier1_match_path <path> <project_dir?>
#     → exit 0 if the given PROJECT_DIR-relative path is Tier 1.
#     → exit 1 otherwise (including when tiers.toml is absent).
#
#   tier1_any_match <newline-separated-paths> <project_dir?>
#     → exit 0 if ANY path in the input is Tier 1.
#     → exit 1 otherwise.

if [[ -z "${__PRILIVE_TIER1_LIB_LOADED:-}" ]]; then
  __PRILIVE_TIER1_LIB_LOADED=1
fi

# Internal: extract a TOML string-array field as newline-separated values.
# Handles simple inline-array form:
#   key = [ "a", "b" ]
# and multi-line form:
#   key = [
#     "a",
#     "b",
#   ]
# Comments (# ...) on the same line are stripped.
_tier1_extract_array() {
  local file="$1" section="$2" key="$3"
  [[ -f "$file" ]] || return 1
  awk -v section="$section" -v key="$key" '
    BEGIN {
      in_section = 0; in_array = 0; collecting = ""
      # Build the literal section-header line we are looking for.
      section_line = "[" section "]"
    }
    /^[[:space:]]*\[/ {
      # New section header — strip whitespace and compare literally.
      header = $0
      gsub(/[[:space:]]/, "", header)
      if (header == section_line) { in_section = 1; next }
      in_section = 0; next
    }
    in_section {
      # Strip trailing comment.
      sub(/[[:space:]]*#.*$/, "")
      if (in_array) {
        # Collect content until closing bracket.
        line = $0
        if (line ~ /\]/) {
          sub(/\].*$/, "", line)
          collecting = collecting " " line
          in_array = 0
        } else {
          collecting = collecting " " line
        }
        next
      }
      # Check whether the line starts the array.
      if ($0 ~ "^[[:space:]]*" key "[[:space:]]*=") {
        line = $0
        sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*\\[", "", line)
        if (line ~ /\]/) {
          # Inline array — strip up to and including the closing bracket.
          sub(/\].*$/, "", line)
          collecting = line
        } else {
          collecting = line
          in_array = 1
        }
      }
    }
    END {
      # Output one quoted value per line.
      n = split(collecting, parts, /,/)
      for (i = 1; i <= n; i++) {
        v = parts[i]
        gsub(/^[[:space:]]*"|"[[:space:]]*$/, "", v)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        if (v != "") print v
      }
    }
  ' "$file"
}

# Internal: glob match — `*` matches any single path component, `**`
# matches any number of path components. Implemented as bash extglob.
_tier1_glob_to_regex() {
  local pat="$1"
  # Escape regex specials except for the glob chars we translate.
  # NOTE: bash ${var//pat/repl} cannot safely escape `}` in the repl
  # (the first unescaped `}` closes the substitution and appends spurious
  # text). Paths don't contain `{`/`}`; outside `{n,m}` repetition the
  # braces are regex literals anyway, so skipping these escapes is safe.
  pat="${pat//./\\.}"
  pat="${pat//+/\\+}"
  pat="${pat//(/\\(}"
  pat="${pat//)/\\)}"
  pat="${pat//\[/\\[}"
  pat="${pat//\]/\\]}"
  # Translate ** → ANY (including no path components — match // → empty)
  # Use a sentinel so the single-* translation doesn't grab it.
  pat="${pat//\*\*/__DBLSTAR__}"
  # Translate single * → [^/]* (no slashes)
  pat="${pat//\*/[^/]*}"
  # Replace sentinel with .* (any chars including slashes)
  pat="${pat//__DBLSTAR__/.*}"
  printf '^%s$' "${pat}"
}

# Public: tiers.toml exists?
tier1_config_present() {
  local project_dir="${1:-${PROJECT_DIR:-$(pwd)}}"
  [[ -f "${project_dir}/.tdd/tiers.toml" ]]
}

# Public: is a single path Tier 1?
tier1_match_path() {
  local path="$1"
  local project_dir="${2:-${PROJECT_DIR:-$(pwd)}}"
  local config="${project_dir}/.tdd/tiers.toml"
  [[ -f "$config" ]] || return 1

  # First: if it matches an allow_globs pattern, it's NOT Tier 1.
  local glob regex
  while IFS= read -r glob; do
    [[ -z "$glob" ]] && continue
    regex=$(_tier1_glob_to_regex "$glob")
    if [[ "$path" =~ $regex ]]; then
      return 1
    fi
  done < <(_tier1_extract_array "$config" "tier1" "allow_globs")

  # Then: match against path_globs.
  while IFS= read -r glob; do
    [[ -z "$glob" ]] && continue
    regex=$(_tier1_glob_to_regex "$glob")
    if [[ "$path" =~ $regex ]]; then
      return 0
    fi
  done < <(_tier1_extract_array "$config" "tier1" "path_globs")

  return 1
}

# Public: does any path in the input set match Tier 1?
tier1_any_match() {
  local paths="$1"
  local project_dir="${2:-${PROJECT_DIR:-$(pwd)}}"
  local p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if tier1_match_path "$p" "$project_dir"; then
      return 0
    fi
  done <<< "$paths"
  return 1
}
