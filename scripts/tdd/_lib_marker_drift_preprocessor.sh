#!/usr/bin/env bash
# scripts/tdd/_lib_marker_drift_preprocessor.sh
#
# Reads a /second-opinion JSON response from stdin; annotates each
# finding that matches a known reviewer-drift pattern with two
# fields: `auto_pushback_eligible: true` + a `canonical_citation`
# string. Emits the (possibly-modified) JSON to stdout.
#
# Sourced by .claude/skills/second-opinion/SKILL.md Step 5 — runs
# AFTER Codex returns a response, BEFORE the agent reads findings.
#
# v1.6.2 origin: parasitoid trial (memo 2026-05-09). Codex's
# pre-v1.6.0 prior holds `Human approved implementation: yes` as the
# canonical M3 marker; v1.6.0 renamed to `Green phase authorized: yes`.
# Without this preprocessor, the agent must write a full-essay
# PUSHBACK every time Codex emits one of these drift findings (~3-5
# minutes per cycle of friction on a non-issue).
#
# CONTRACT
#
# Stdin: JSON with shape {"summary": ..., "findings": [...]}.
# Stdout: same JSON, with each matching finding gaining:
#   - "auto_pushback_eligible": true
#   - "canonical_citation": <string>
#
# Findings that DO NOT match a known drift pattern pass through
# unchanged (no annotation, no deletion). Invalid JSON passes through
# unchanged (silent — preprocessor must not break the skill on
# unexpected input).
#
# Patterns currently recognised:
#   marker_name_drift_v1.6.0 — NARROW matcher (refined across 19
#     rounds of /second-opinion in the v1.6.2 cycle). Conservative
#     by design: false negatives → full PUSHBACK essay (acceptable);
#     false positives → suppress real signal (NOT acceptable).
#
#     Match conditions (all must be true):
#       1. Body contains `Human approved implementation`.
#       2. Body contains an explicit GATE/CONFIG-as-subject demand
#          phrase (NOT bare `required` / `canonical` / `should be` /
#          `hook requires` / `gate requires` — those false-positive
#          on plan-as-subject and file-as-subject findings).
#          Accepted phrases (CURRENT — keep in sync with the jq
#          test() call below; do NOT add to this list without also
#          adding to the matcher; do NOT keep removed phrases here):
#            - `repo instructions require`
#            - `tdd config requires`
#            - `config requires`
#            - `gate vocabulary requires`
#            - `demanding the marker`
#          Phrases REMOVED across iterations (each round Codex found
#          a false-positive case): bare `required`, `canonical`,
#          `should be`, `expected`, `must use`, bare `the marker is`,
#          `marker is`, `gate vocabulary` (alone, without `requires`),
#          `gate requires`, `hook requires`, `ceremony requires`,
#          `require the marker`, `required marker is`,
#          `approval marker is`, `marker vocabulary is`,
#          `the gate vocabulary is`. Each removal accepts more
#          false negatives in exchange for closing a false-positive
#          class.
#       3. Old marker is within 80 chars AFTER the demand phrase
#          (lookahead excludes `green phase authorized`, `not human
#          approved`, `is not human`, `isn't human`).
#       4. Inverse pattern does NOT match (no `human approved
#          implementation` followed within 200 chars by demand-vocab
#          + `green phase authorized` within 80 more).
#       5. Exclusion vocab does NOT appear: deprecated, outdated,
#          legacy, instead of canonical, should be replaced, migrated,
#          old name, previous name, pre-v1.6.0, replaced human
#          approved, old marker, backwards compat, in marker_aliases,
#          alias entry, breaks old cycles, removing it,
#          preserve.*alias, alias preservation,
#          alias.{0,30}human approved implementation, the alias.
#       6. Plan-as-subject pattern does NOT appear: `(plan|the plan)
#          ( still| currently| now)? (uses|requires|declares|is using
#          |was using).{0,80}human approved implementation`.
#       7. (Runtime, separate from regex): local config has
#          `marker_aliases` mapping containing the old name AND the
#          canonical name appears in `required_markers_*` AND the old
#          name does NOT appear in `required_markers_*`.
#
#     This narrow matcher will MISS many real drift findings (e.g.,
#     "wrong marker: Green phase authorized should be Human approved
#     implementation" — bare `should be`, no gate-subject demand).
#     The agent writes a full PUSHBACK essay for those. Operators
#     should not expect every drift finding to be fast-tracked.
#
#     ARCHITECTURAL LIMIT (acknowledged round 25): the canonical
#     drift pattern "Repo instructions require Human approved
#     implementation: yes" is INDISTINGUISHABLE from a real hook
#     defect "Repo instructions require Human approved implementation
#     in scripts/git-hooks/pre-commit" by keyword matching alone.
#     The matcher will flag both. The agent's verification step
#     (cite local evidence — field name + line number from
#     tdd-config.json AND read the cited hook file when one is named)
#     is the actual protection. The auto_pushback_eligible flag is
#     PERMISSION to skip the multi-paragraph essay; it is NOT
#     permission to skip the local-evidence verification. See
#     .claude/rules/go-tdd.md "Known reviewer-drift findings" for
#     the discipline contract.

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  cat
  exit 0
fi

input="$(cat)"
if ! printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
  printf '%s' "$input"
  exit 0
fi

# v1.6.2 round-4 F1: bind eligibility to LOCAL config. The
# canonical_citation must reference whatever the project's
# marker_aliases actually says; if no relevant mapping exists, pass
# the finding through unchanged (let the agent write a full PUSHBACK).
# Without this, downstream consumers with different/absent aliases
# would receive misleading hardcoded claims.
CONFIG=".tdd/tdd-config.json"
OLD_NAME="Human approved implementation: yes"
CANONICAL=""
if [[ -f "$CONFIG" ]]; then
  CANONICAL="$(jq -r --arg old "$OLD_NAME" '
    .marker_aliases // {}
    | to_entries
    | map(select(.value == $old))
    | .[0].key // empty
  ' "$CONFIG" 2>/dev/null)"
fi
if [[ -z "$CANONICAL" ]]; then
  # v1.6.2 round-11 F2: sanitize reserved fields BEFORE the early
  # return. Without this, forged auto_pushback_eligible /
  # canonical_citation in caller input would survive the no-alias
  # passthrough path. Direct/degraded use of this wrapper (not via
  # SKILL.md's pre-sanitizer) would otherwise preserve forged trust.
  printf '%s' "$input" \
    | jq '.findings |= map(del(.auto_pushback_eligible, .canonical_citation))'
  exit 0
fi

# v1.6.2 round-17 F2: alias presence isn't enough. The migration may
# be partial: alias entry exists but the ACTIVE required_markers_*
# still names the OLD marker. In that case a real drift finding
# (config really does require the old marker) must NOT be flagged.
# Verify both: CANONICAL appears in at least one required_markers_*
# array AND OLD_NAME does NOT appear in either.
CANONICAL_ACTIVE="$(jq -r --arg c "$CANONICAL" '
  ((.required_markers_edit_time // []) + (.required_markers_commit_time // []))
  | map(select(. == $c))
  | length
' "$CONFIG" 2>/dev/null)"
OLD_STILL_REQUIRED="$(jq -r --arg o "$OLD_NAME" '
  ((.required_markers_edit_time // []) + (.required_markers_commit_time // []))
  | map(select(. == $o))
  | length
' "$CONFIG" 2>/dev/null)"
if [[ "${CANONICAL_ACTIVE:-0}" -eq 0 ]] || [[ "${OLD_STILL_REQUIRED:-0}" -gt 0 ]]; then
  # Partial migration: don't flag. Same passthrough path as no-alias.
  printf '%s' "$input" \
    | jq '.findings |= map(del(.auto_pushback_eligible, .canonical_citation))'
  exit 0
fi

# v1.6.2 round-14 F2: include the line number of the marker_aliases
# entry so the canonical_citation satisfies go-tdd.md's
# "field name AND line number" requirement structurally.
ALIAS_LINE="$(grep -nF "\"$OLD_NAME\"" "$CONFIG" 2>/dev/null | head -1 | cut -d: -f1)"
[[ -z "$ALIAS_LINE" ]] && ALIAS_LINE="?"

CITATION="Local config (.tdd/tdd-config.json marker_aliases at line $ALIAS_LINE) records \"$OLD_NAME\" as the deprecated alias for \"$CANONICAL\". The plan is correct as written if it uses the canonical name."

printf '%s' "$input" | jq --arg cite "$CITATION" '
  # v1.6.2 rounds 1-6 F1/F2 (Codex caught self-annotations + plan-
  # subject false positives multiple times). Predicate philosophy:
  #   1. Strip caller-supplied auto_pushback_eligible/canonical_citation
  #      from EVERY finding first (round 6 F1: provenance hygiene; a
  #      forged or prompt-injected response could pre-populate them).
  #   2. Demand vocab must be GATE/SPEC-as-subject: only specific
  #      phrases like "repo instructions require", "the marker is",
  #      "required marker is", "gate vocabulary", "approval marker is",
  #      "marker vocabulary is" — NOT bare "required"/"canonical"
  #      (which falsely match "Plan requires" / "the canonical NEW").
  #   3. Negative lookahead: no "green phase authorized" between
  #      demand vocab and old marker.
  #   4. Inverse pattern must not match: old marker followed within
  #      200 chars by demand-vocab + "green phase authorized".
  #   5. Explicit deprecation vocab (deprecated/outdated/legacy/
  #      replaced/old marker/etc.) must not appear.
  # Conservative: false negatives → full PUSHBACK essay (acceptable).
  # False positives → suppress real signal (NOT acceptable).
  def is_marker_drift(f):
    ((f.evidence // "") + " " + (f.title // ""))
    | ascii_downcase as $body
    | ($body | test("(repo instructions require|tdd config (still |currently |now )?requires?|config (still |currently |now )?requires?|gate vocabulary requires?|demanding the marker)(?:(?!green phase authorized|not human approved|is not human|isn.t human).){1,80}human approved implementation"))
      and (($body | test("human approved implementation.{0,200}(canonical|required marker is|the marker is|current marker is|gate vocabulary|approval marker is|marker vocabulary is).{0,80}green phase authorized")) | not)
      and (($body | test("deprecated|outdated|legacy|instead of canonical|should be replaced|migrated|old name|previous name|pre-v1\\.6\\.0|replaced human approved|old marker|backwards compat|backward compat|in marker_aliases|alias entry|breaks old cycles|removing it|preserve.*alias|alias preservation|alias.{0,30}human approved implementation|the alias")) | not)
      and (($body | test("(plan|the plan)( still| currently| now)?.{0,40}(uses|requires|declares|is using|was using|gate vocabulary).{0,80}human approved implementation")) | not);

  # v1.6.2 round-6 F1: strip provenance-sensitive fields BEFORE
  # the match decision. Add them back only when our matcher accepts.
  .findings |= map(del(.auto_pushback_eligible, .canonical_citation)
                   | if is_marker_drift(.) then
                       . + { "auto_pushback_eligible": true, "canonical_citation": $cite }
                     else . end)
'
