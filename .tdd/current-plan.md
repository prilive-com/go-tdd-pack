# Bugfix Plan: f13-trivial-paths-consolidation — single config source for skip-path lists

Status: active
Cycle ID: f13-trivial-paths-consolidation
Change type: cleanup (drift prevention)
Tier: 1 (require-second-opinion.sh + tdd-config.json)

<!-- TDD ceremony markers. Set each ONLY after the matching operator APPROVED reply. -->
Bug reproduced: yes
Human approved spec: yes
Red phase confirmed: yes
Green phase authorized: yes
Implementation reviewed: yes
Fix applied: yes
Regression tests added: yes
Bug-elsewhere check complete: yes

## Bug

Three places encode "trivial / skip / always-allow path" lists, each
divergent and edited independently:

  1. `.claude/hooks/require-second-opinion.sh` `is_always_allowed_path()`
     (~13 lines of `case` patterns)
  2. `.claude/hooks/require-tdd-state.sh` inline `case` near line 188
     (different list — `*.md` deliberately removed per cycle f4)
  3. `.claude/skills/second-opinion/SKILL.md` Step 3 skip_globs filter
     (~9 patterns, similar to but not identical to #1)

Drift scenarios that have already happened or will:
- F1 added `.tdd/`/`.claude/`/`.second-opinion/` to #1 only; the skill
  filter (#3) still doesn't include them.
- f4 removed `*.md` from #2; #1 and #3 still include it.
- A new path category added to #1 won't appear in #3 unless someone
  remembers to mirror it.

The require-tdd-state.sh divergence (#2) is INTENTIONAL — that hook
governs Tier 1 markdown like `.claude/skills/second-opinion/SKILL.md`
and must NOT skip `*.md`. That's documented in the f4 cycle comment.
But the require-second-opinion.sh and SKILL.md lists (#1, #3) cover
the same conceptual category ("paths not worth a second opinion") and
should share a single source of truth.

## Acceptance criteria

1. `.tdd/tdd-config.json` has a `trivial_paths` array with the
   canonical "skip second opinion" globs.
2. `require-second-opinion.sh` `is_always_allowed_path()` consults
   `trivial_paths` from the config when present; falls back to the
   existing inline list if the config is missing OR jq is missing
   (no regression for environments without jq).
3. SKILL.md Step 3's skip_globs filter consults the same field
   (with the same fallback).
4. `require-tdd-state.sh` has a header comment explaining its
   intentional divergence from `trivial_paths` (the f4 carve-out).
5. A new smoke test asserts that `trivial_paths` exists in the
   config and includes the union of the require-second-opinion.sh
   and SKILL.md inline fallbacks (no entry silently lost).
6. No regression: existing 254 smoke tests still pass.

## Non-goals

- Consolidating require-tdd-state.sh into the same config (its
  divergence is intentional; would re-open f4).
- Generic "path-group" config (e.g., separate `pack_internal`,
  `community_docs`, `ci_config` groups). One canonical list is
  enough for v1; finer-grained grouping is deferred.
- Wiring other hooks (guard-bash-pipefail, gate-tier1-commit) to
  the same field. They don't currently use a path-skip list.
- A migration script. The fallback inline list preserves existing
  behavior; the new config field is opt-in (consumers populate it
  to pick up the consolidation; default `[]` or absent means
  hooks use their inline fallbacks).

## Affected code

- `.tdd/tdd-config.json` — add `trivial_paths` field
- `.claude/hooks/require-second-opinion.sh` — read config in
  `is_always_allowed_path()` with inline fallback
- `.claude/skills/second-opinion/SKILL.md` — read config in Step 3
  filter loop with inline fallback
- `.claude/hooks/require-tdd-state.sh` — add comment documenting
  the f4 carve-out (no behavior change)
- `scripts/tdd-test-hooks.sh` — new smoke tests

## Test plan

| Test name | Pins criterion # |
|---|---|
| f13_trivial_paths_field_exists_in_config | 1 |
| f13_trivial_paths_includes_canonical_globs | 1 |
| f13_hook_uses_config_trivial_paths | 2 |
| f13_hook_falls_back_when_config_missing | 2 |
| f13_skill_md_references_trivial_paths_config | 3 |
| f13_require_tdd_state_documents_divergence | 4 |

## Minimum implementation

### Config field

Add to `.tdd/tdd-config.json`:

```json
{
  "_trivial_paths_doc": "F13: canonical 'skip second opinion' glob list. Consumed by require-second-opinion.sh's is_always_allowed_path() and the /second-opinion skill's Step 3 filter loop. Each consumer falls back to its inline list if this field is missing or jq is unavailable. require-tdd-state.sh INTENTIONALLY does NOT consult this list (per cycle f4 — it must govern pack-internal markdown like .claude/skills/second-opinion/SKILL.md, which would be skipped if .md was here).",
  "trivial_paths": [
    "*.md",
    "*.txt",
    "*CHANGELOG*",
    "*README*",
    "*LICENSE*",
    ".editorconfig",
    "*/.editorconfig",
    ".gitignore",
    "*/.gitignore",
    "go.sum",
    "*/go.sum",
    ".github/*",
    "*/.github/*",
    ".gitlab-ci.yml",
    "*/.gitlab-ci.yml",
    ".tdd/*",
    "*/.tdd/*",
    ".claude/*",
    "*/.claude/*",
    ".second-opinion/*",
    "*/.second-opinion/*"
  ]
}
```

### Hook (`is_always_allowed_path`)

```bash
is_always_allowed_path() {
  local p="$1"
  # F13: consult tdd-config.json trivial_paths first; fall back to
  # inline list if config missing OR jq unavailable.
  if [[ -f "$TDD_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
    local has_config_list
    has_config_list="$(jq -r '(.trivial_paths // []) | length' "$TDD_CONFIG" 2>/dev/null)"
    if [[ -n "$has_config_list" ]] && [[ "$has_config_list" -gt 0 ]]; then
      while IFS= read -r pat; do
        [[ -z "$pat" ]] && continue
        # shellcheck disable=SC2053
        [[ "$p" == $pat ]] && return 0
      done < <(jq -r '.trivial_paths[]? // empty' "$TDD_CONFIG" 2>/dev/null)
      return 1
    fi
  fi
  # Inline fallback (preserved verbatim from pre-F13).
  case "$p" in
    *.md|*.txt|*CHANGELOG*|*README*|*LICENSE*) return 0 ;;
    .editorconfig|*/.editorconfig|.gitignore|*/.gitignore) return 0 ;;
    go.sum|*/go.sum) return 0 ;;
    .github/*|*/.github/*|.gitlab-ci.yml|*/.gitlab-ci.yml) return 0 ;;
    .tdd/*|*/.tdd/*) return 0 ;;
    .claude/*|*/.claude/*) return 0 ;;
    .second-opinion/*|*/.second-opinion/*) return 0 ;;
  esac
  return 1
}
```

### SKILL.md Step 3 filter

Same pattern: try config first via jq, fall back to the existing
case statement.

### require-tdd-state.sh comment

Above the existing case in `require-tdd-state.sh` (around line 188),
add:

```bash
  # F13 carve-out: this hook does NOT consult tdd-config.json
  # trivial_paths. The require-second-opinion.sh hook + /second-
  # opinion skill share that list because they implement the same
  # "skip second opinion on docs/CI/etc" policy. THIS hook governs
  # Tier 1 production-code edits — including pack-internal markdown
  # like .claude/skills/second-opinion/SKILL.md. If we used
  # trivial_paths here, *.md would skip Tier 1 enforcement entirely
  # (re-opening cycle f4). The list below is intentionally narrower.
  case "$FILE" in
    ...
  esac
```

## Risk register

| Risk | Mitigation |
|---|---|
| Config field is empty/null → hook silently skips path list | Length check `length > 0`; falls back to inline list when 0 or missing. Test verifies. |
| Bash glob `[[ "$p" == $pat ]]` differs from `case` pattern semantics | Both use `extglob`-free shell glob matching; equivalent for the patterns in use (no `?(...)`/`*(...)`). |
| jq not available → falls back to inline list silently | Existing behavior in other hooks (gate-tier1-commit, require-second-opinion guards). Documented in comment. |
| New consumer added later forgets the config field | Future-cycle concern; the current cycle establishes the pattern. Drift caught by smoke test that diff-checks consumer lists vs config. |
| operator overrides `trivial_paths` to empty (`[]`) intending to disable; hook falls back to inline list (= NOT disabled) | Documented: empty array is treated as "use fallback"; to actually disable, the operator would set the field to a single placeholder pattern that matches nothing. Edge case; document in `_trivial_paths_doc`. |
