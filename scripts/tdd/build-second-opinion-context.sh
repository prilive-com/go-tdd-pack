#!/usr/bin/env bash
# scripts/tdd/build-second-opinion-context.sh
#
# Generate a schema-context-for-reviewer markdown block from
# .tdd/tdd-config.json. The /second-opinion skill embeds the block
# in its prompt template so Codex sees the canonical TDD marker
# vocabulary BEFORE producing findings.
#
# v1.6.2 origin: parasitoid trial (memo 2026-05-09) reported 3/5
# Pass B reviews returning P1 "marker name drift" findings — Codex's
# pre-v1.6.0 prior holds `Human approved implementation: yes` as the
# M3 marker; v1.6.0 renamed it to `Green phase authorized: yes` and
# moved the old name to marker_aliases. Without this generated
# context block, the marker rename is invisible to Codex and every
# Tier 1 cycle pays ~3-5 min of PUSHBACK friction.
#
# CONTRACT
#
# Inputs:
#   --config <path>   path to tdd-config.json  (default: .tdd/tdd-config.json)
#   --output <path>   path to write the markdown (default:
#                     .tdd/second-opinion/context/schema-context-for-reviewer.md)
#
# Output (markdown):
#   - "## Canonical edit-time markers" — list of required_markers_edit_time
#   - "## Canonical commit-time markers" — list of required_markers_commit_time
#   - "## Deprecated aliases" — marker_aliases (or "(none)" if missing)
#   - reviewer instruction footer
#
# Behaviour:
#   - Always exits 0 (best-effort; never breaks /second-opinion).
#   - If config missing: emits markdown with empty marker sections + a
#     "config not found" comment + a stderr warning.
#   - If marker_aliases missing: emits "Deprecated aliases" section with
#     "(none)" body.
#   - jq is a hard dep (it's already required by the rest of the skill);
#     if jq is missing, exits 0 with a warning to stderr.

set -uo pipefail

CONFIG=".tdd/tdd-config.json"
OUTPUT=".tdd/second-opinion/context/schema-context-for-reviewer.md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

mkdir -p "$(dirname -- "$OUTPUT")" 2>/dev/null

emit_marker_list() {
  local field="$1"
  if [[ ! -f "$CONFIG" ]]; then
    return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    return
  fi
  jq -r --arg f "$field" '
    if (.[$f] | type) == "array" then .[$f][]? else empty end
  ' "$CONFIG" 2>/dev/null \
    | while IFS= read -r marker; do
        [[ -z "$marker" ]] && continue
        printf -- '- `%s`\n' "$marker"
      done
}

emit_aliases() {
  if [[ ! -f "$CONFIG" ]]; then
    printf -- '(none)\n'
    return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf -- '(none)\n'
    return
  fi
  local has_any
  has_any=$(jq -r '.marker_aliases // {} | to_entries | length' "$CONFIG" 2>/dev/null || echo 0)
  if [[ "${has_any:-0}" -eq 0 ]]; then
    printf -- '(none)\n'
    return
  fi
  jq -r '
    .marker_aliases // {}
    | to_entries
    | .[]
    | "- `\(.value)` → `\(.key)` (deprecated alias)"
  ' "$CONFIG" 2>/dev/null
}

if [[ ! -f "$CONFIG" ]]; then
  echo "[build-second-opinion-context] WARN: $CONFIG not found; emitting empty context." >&2
fi

# v1.6.2 round-5 F2: when jq is missing, the generator can't read the
# config at all. Emit an explicit DEGRADED block so Codex doesn't
# interpret the empty marker sections as authoritative "no markers
# exist." The block names jq-missing as the cause and instructs the
# reader to fall back to model defaults / not infer schema.
if ! command -v jq >/dev/null 2>&1; then
  echo "[build-second-opinion-context] WARN: jq not on PATH; emitting TOOLING DEGRADED block." >&2
  _DEG_TMP="$(mktemp "${OUTPUT}.XXXXXX.tmp" 2>/dev/null \
               || mktemp 2>/dev/null \
               || echo "${OUTPUT}.partial.$$")"
  cat > "$_DEG_TMP" <<'DEGRADED'
# Project-local TDD marker vocabulary

<!-- TOOLING DEGRADED: jq is missing on PATH. The schema-context
generator could not read .tdd/tdd-config.json. Marker vocabulary
sections below are intentionally empty. -->

## Canonical edit-time markers

(unavailable — TOOLING DEGRADED, jq missing)

## Canonical commit-time markers

(unavailable — TOOLING DEGRADED, jq missing)

## Deprecated aliases

(unavailable — TOOLING DEGRADED, jq missing)

## Reviewer instruction

The generator could NOT read this project's marker vocabulary because
jq is not installed. Do NOT infer the schema from this block. Fall
back to your training-data prior with the standard caveat: if you
emit a finding about marker naming, the agent will verify it against
the config manually before adjudicating.
DEGRADED
  mv -f "$_DEG_TMP" "$OUTPUT" 2>/dev/null || rm -f "$_DEG_TMP"
  exit 0
fi

# v1.6.2 round-6 F3: atomic write. Without tmp + mv, a crash/SIGTERM
# mid-write would leave a partial file that the SKILL.md prompt
# template would then cat as if it were complete. tmp+mv ensures
# either the new full file lands or the old file remains intact.
_OUTPUT_TMP="$(mktemp "${OUTPUT}.XXXXXX.tmp" 2>/dev/null \
                || mktemp 2>/dev/null \
                || echo "${OUTPUT}.partial.$$")"
{
  cat <<'HEADER'
# Project-local TDD marker vocabulary

This block is generated from `.tdd/tdd-config.json` by
`scripts/tdd/build-second-opinion-context.sh`. The repo's TDD
ceremony uses the canonical markers below. The aliases section
lists deprecated names retained for backwards compatibility only.

HEADER
  if [[ ! -f "$CONFIG" ]]; then
    printf -- '<!-- config not found at %s; sections below are empty -->\n\n' "$CONFIG"
  fi
  printf -- '## Canonical edit-time markers\n\n'
  emit_marker_list 'required_markers_edit_time'
  printf -- '\n'
  printf -- '## Canonical commit-time markers\n\n'
  emit_marker_list 'required_markers_commit_time'
  printf -- '\n'
  printf -- '## Deprecated aliases\n\n'
  emit_aliases
  printf -- '\n'
  # v1.6.2 round-3 F3: footer is conditional on whether the project
  # actually has marker_aliases. Customized downstream repos without
  # the v1.6.0 rename should NOT see hardcoded claims about
  # `Human approved implementation` ↔ `Green phase authorized`.
  _has_aliases=0
  if [[ -f "$CONFIG" ]] && command -v jq >/dev/null 2>&1; then
    _has_aliases=$(jq -r '.marker_aliases // {} | to_entries | length' "$CONFIG" 2>/dev/null || echo 0)
  fi
  cat <<'FOOTER_HEADER'
## Reviewer instruction

If you think a marker is wrong, verify against `.tdd/tdd-config.json`
before producing a finding. Local config is canonical and beats your
training-data prior.
FOOTER_HEADER
  if [[ "${_has_aliases:-0}" -gt 0 ]]; then
    cat <<'FOOTER_ALIASES'
Markers listed in the `Deprecated aliases` section above are
backwards-compatibility aliases only — do NOT report the canonical
(non-deprecated) names as nonstandard or incorrect. The aliases
section is project-specific; any rename your project's
`tdd-config.json` documents takes precedence over your training-data
prior.
FOOTER_ALIASES
  fi
} > "$_OUTPUT_TMP"
# Atomic move: rename guarantees readers see either the previous full
# file or the new full file, never a half-written one.
mv -f "$_OUTPUT_TMP" "$OUTPUT" 2>/dev/null || rm -f "$_OUTPUT_TMP"

exit 0
