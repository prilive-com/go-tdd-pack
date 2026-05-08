# Integration guards (project-level static invariants)

## What this is

A list of regex patterns in `.tdd/tdd-config.json` (`integration_guards`)
that the commit gate (`.claude/hooks/gate-tier1-commit.sh`) checks against
the entire repo. If any source file outside the guard's `allowed_globs`
matches the pattern, the green commit is denied (`severity: deny`) or
warned (`severity: warn`).

## What it catches

The class of bug that plan-review and `/second-opinion` cannot catch:
**cross-module integration assumptions that the planner didn't think to
verify**. Examples from real trial use:

- A new code path reads `metadata["order_link_id"]` (snake_case); a legacy
  emitter elsewhere writes `metadata["orderLinkId"]` (camelCase). The
  mismatch ships silently because both sides are stringly-typed.
- A new sanctioned wrapper (e.g., `IntentTracker`) is supposed to be the
  only call site for `ExchangeService.PlaceOrder`. Months later, an
  orchestrator in a different module still calls `PlaceOrder` directly,
  bypassing the wrapper.
- A helper function (e.g., `GenerateGridOrderLinkId`) is added for one
  code path but a sibling path that should use it passes empty string.

These are not visible from a plan diff. They are visible from a wide-angle
read of the integrated repo — i.e., from `grep`. The guards encode
that wide-angle knowledge as machine-checkable rules.

## What it is NOT

- **Not a substitute for integration tests.** If the orderLinkId mismatch
  could be caught by a single end-to-end test exercising
  emitter → executeSignal → RecordIntent, write that test first. The test
  is the primary defense. The guard is a fallback for invariants tests
  cannot easily reach.
- **Not auto-detection of integration boundaries.** The starter pack does
  not analyze the cycle's diff to infer guards. Each guard is manually
  declared. The point of guards is to encode lessons learned: every shipped
  bug that a grep could have caught becomes a permanent guard.
- **Not a general lint replacement.** `golangci-lint`, `staticcheck`,
  `unparam`, `deadcode` cover most language-level issues. Guards are for
  project-specific invariants those tools can't know about.

## When to use a guard vs write a test vs change types

Decision tree:

```
Question: can a single integration test exercise the failure path?
  YES  → write the test. Don't add a guard.
  NO   → continue.

Question: is the invariant expressible in the type system
         (typed enums, typed metadata constants, interface)?
  YES  → refactor toward type safety. Don't add a guard.
  NO   → continue.

Question: is the invariant a "no call to X outside Y" rule?
  YES  → guard with regex on the API name + allowed_globs for Y.
  NO   → continue.

Question: is the invariant "string Z must be consistent across writers"?
  YES  → strongly prefer a typed constant. If the codebase is
         too large to refactor right now, add a guard with severity=warn
         while the refactor is in progress.

Otherwise: probably not a guard. Document the invariant in the rule
file and revisit when a real bug surfaces.
```

## Guard schema

In `.tdd/tdd-config.json`:

```json
"integration_guards": [
  {
    "name": "no_direct_PlaceOrder",
    "pattern": "ExchangeService\\.PlaceOrder",
    "severity": "deny",
    "allowed_globs": [
      "internal/intent/**/*.go",
      "internal/sweepers/**/*.go",
      "**/*_test.go"
    ],
    "rationale": "All order placement must route through IntentTracker (G4 spec)"
  },
  {
    "name": "stringly_typed_metadata_key",
    "pattern": "Metadata\\[\"[a-zA-Z]+\"\\]",
    "severity": "warn",
    "allowed_globs": [],
    "rationale": "Use typed metadata constants from internal/keys to avoid case-mismatch bugs"
  }
]
```

| Field | Required | Purpose |
|---|---|---|
| `name` | yes | Short ID shown in violation message and audit log |
| `pattern` | yes | POSIX extended regex (grep -E), matched against file content |
| `severity` | no (default: `deny`) | `deny` blocks the commit; `warn` only logs |
| `allowed_globs` | no (default: empty) | List of glob patterns; `**` matches across directories. Files matching any are exempt. |
| `rationale` | no but recommended | One sentence explaining the invariant. Shown to the operator on violation. |

## When the hook fires

The commit-time gate (`gate-tier1-commit.sh`) checks integration guards
ONLY when:

1. The commit is on a Tier 1 cycle (matched via `tier1_path_regexes`).
2. The commit is not a `red(<id>)` commit (red commits are exempt by
   design).

For non-Tier-1 cycles the guards are silent. This is intentional — the
overhead of a full-repo grep is justified for high-stakes paths but not
for routine work.

## Maintaining guards

After every shipped bug that a grep could have caught:

1. Write the integration test that would have caught it (always).
2. Decide if the invariant the bug violated is broader than this one
   case. If yes, add a guard so future regressions are caught immediately.
3. Document the rationale linking the guard to the original bug in the
   `rationale` field.

A guards list with no rationale is technical debt. A guards list where
each entry has a rationale linking back to a real bug is institutional
memory.

## Friction note

`allowed_globs` will need updates when new sanctioned files are added
(e.g., `internal/intent/v2/tracker.go` joins the existing
`internal/intent/**/*.go` glob — covered automatically by `**`, no
update needed). When a NEW path becomes sanctioned (e.g., a new package
gains the right to call a guarded API), the `allowed_globs` list must be
extended in the same commit. The hook denies until it is. This is
intentional — it forces a decision on every expansion of an invariant's
allow-list.

## Future direction

A future minor version may add cycle-specific guards declared in
`.tdd/current-plan.md` (between `<!-- INTEGRATION_GUARDS_START -->` and
`<!-- INTEGRATION_GUARDS_END -->` markers). For now, all guards are
project-level. The reasoning: most useful guards are stable invariants,
not cycle-specific assumptions. The few cycle-specific cases can be
expressed as project-level guards with a TODO note in `rationale`.
