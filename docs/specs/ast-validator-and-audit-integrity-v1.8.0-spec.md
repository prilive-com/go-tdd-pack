# v1.8.0 — AST validator + audit-log chain integrity

**Status:** Shipped. Closes 5 deferred items from the v1.7.0
disposition matrix.

## What this cycle delivers

The v1.7.0 typed-test-edit exception system used a regex-only
validator. Seven `/second-opinion` rounds caught 24 P0/P1 findings,
many of them rooted in the validator's structural blind spots:

- regex can't tell a `func XHelper()` call from "scope is `X`"
- regex can't track import-block boundaries
- regex's helper-shape multiset check is foolable in edge cases
- audit-log integrity was trust-only

v1.8.0 fixes all four by introducing a Go AST helper invoked by the
bash validator library, plus a sha-chain over the audit log.

## Architecture

```
.claude/hooks/require-tdd-state.sh
  │
  │ source                     verify chain
  ▼                              │
scripts/tdd/_lib_test_edit_exception.sh   ───►  scripts/tdd/verify-audit-chain.sh
  │
  │ go run (per-type)
  ▼
scripts/tdd/ast/validator.go
  ├── import-block-check          (AC1.2)
  ├── mech-sig-prop-check         (AC1.2)
  ├── compile-fix-scope-check     (AC1.2)
  └── schema-predicate-check      (AC1.2)
```

Two design choices to flag for reviewers:

1. **`go run` not pre-built binary** — Go ≥1.26.2 is already a
   pack hard dependency (CLAUDE.md "Version floors"). Cold-start
   is ~300ms per invocation; acceptable for an interactive hook.
   Pack consumers can `go build scripts/tdd/ast/validator.go` if
   they want to amortize the cold-start.

2. **AST AND-gate (not replace) regex** — both checks must pass.
   AST is strictly stricter: it adds rejections, never adds
   allows. When AST is unavailable (no Go, killswitch, validator
   file missing), the system warns and falls back to v1.7.0
   regex behavior.

## Subcommand contracts

### `import-block-check --paths a,b`

Rejects any `+` line whose new-file line number falls outside an
`import (...)` block or top-level `import "x"` declaration in the
on-disk file.

**Lenient when:** the on-disk file has zero import declarations.
This case (operator initializing a new import block) defers to
the regex check, which already enforces the four canonical Go
import shapes (bare, aliased, dot, blank).

### `mech-sig-prop-check --paths a,b`

For paired `-` / `+` assertion lines, rejects if the assertion
helper (e.g. `require.Equal`) shape changes. Only call-site
arguments may differ between sides.

**Lenient when:** either side fails to parse as an expression
(returns "" helper). The regex multiset check is strict for those
cases.

### `compile-fix-scope-check --symbols X,Y --paths a,b`

Rejects any changed line whose AST identifiers do not include any
declared scope symbol. AST identifier matching distinguishes
`XHelper` from `X` (regex word-boundary substring would not).

**Strict:** unparseable fragments are rejected (no idents found
→ no symbol use confirmed).

### `schema-predicate-check --old-name X --new-name Y --paths a,b`

Accepts ONLY pure renames of `X` to `Y`. Any other identifier
change between `-` and `+` sides is rejected.

**Strict:** length mismatch (different number of identifiers)
rejects. Anywhere `X` was renamed to anything-other-than-`Y`
rejects.

## Audit-log chain

Each appended audit-log line in `.tdd/audit/<cycle-id>.jsonl`
gains a `prev_sha` field holding `sha256(previous_line_text)`.
First line: `prev_sha: ""`. Subsequent lines: hash of the verbatim
preceding line (no trailing newline).

`scripts/tdd/verify-audit-chain.sh <cycle-id>` walks the file:
- Empty file or missing file: exit 0 (vacuously OK).
- Missing `prev_sha` field on a line: warn once, treat as pre-v1.8
  history; chain check resumes from the next line that has the
  field.
- Mismatch between stored `prev_sha` and recomputed sha of the
  prior line: exit 1 with the diverging line number.

The hook (`require-tdd-state.sh`) calls `verify-audit-chain.sh` at
typed-exception dispatch. Tamper → fail closed for typed
exceptions in this cycle (legacy boolean path remains as
documented bypass).

## Per-cycle exception count cap

`tdd-config.json` adds:
```jsonc
"test_file_policy": {
  "post_red_mechanical_update": {
    "max_per_cycle": 5  // 0 = no cap
  }
}
```

The hook counts approved exceptions whose `binding.cycle_id`
matches the current cycle. If the count exceeds `max_per_cycle`,
typed exceptions are disabled for the cycle. Operators can:
- Lower the count by reverting to red phase (gate 2 → re-spec).
- Raise `max_per_cycle` with documented reason in the next commit.

`max_per_cycle: 0` is the explicit no-cap signal (for projects
where exception count is governed by code review, not the hook).

## Killswitch decision table

| Go available? | `TDD_AST_VALIDATOR_DISABLE` | Behavior |
|---|---|---|
| Yes | unset / `0` | AST + regex AND-gate (default; strictest) |
| Yes | `1` | regex-only + stderr warning |
| No | unset / `1` | regex-only + stderr warning |
| Validator file missing | any | regex-only + stderr warning |

The warning is rate-limited per validator-library invocation
(`_V18_AST_WARNED` guard) so cycles with many test-file edits
don't drown stderr.

`TEST_EDIT_EXCEPTION_DISABLE=1` (from v1.7.0) still bypasses the
ENTIRE typed-exception system — both AST and regex paths. Use
sparingly and document in the commit message (honor system,
consistent with other killswitches in the pack).

## Backwards compatibility with v1.7.0 artifacts

- v1.7.0 artifacts have no `binding.head_at_approval` for entries
  approved before v1.8 — the hook's lifecycle check still works
  because v1.7.0 entries lack `prev_sha` too, and the chain check
  warns + skips them per the "pre-v1.8 history" rule.
- v1.7.0 schema fields are unchanged. v1.8 adds:
  - `scope.old_name`, `scope.new_name` (only when type is
    `schema_predicate_correction`).
  - `binding.head_at_approval` (set by grant helper, not required).
  - `prev_sha` field on audit-log lines (additive).
- The legacy `allow_after_red_confirmed` boolean still works with
  the v1.7.0 deprecation warning. Removal still planned for v2.0.0.

## Smoke test growth

v1.7.0 baseline: 483 / 0
v1.8.0 final:    497 / 0  (+14 acceptance tests across AC1-AC5)

## Known limits — deferred to v1.9

1. **AST helper cold-start** ~300ms per `go run` invocation. Pack
   consumers can pre-build a binary; the hook will detect
   `scripts/tdd/ast/validator` (no `.go` extension) and prefer it
   in v1.9.
2. **`schema-predicate-check` is line-by-line**. A multi-line
   refactor that legitimately renames across hunks isn't
   supported yet; operator splits the change.
3. **Audit log archival/rotation** — the log grows unbounded
   per cycle. v1.9 adds a `cycle_close` event + auto-archive on
   green commit.
4. **Encrypted/signed audit log** — v2.0+. Sha-chain detects
   tampering by an unsophisticated operator; doesn't protect
   against a compromised host.
