# Typed test-edit exceptions — v1.7.0 design spec

**Status:** shipped (v1.7.0-typed-test-edit-exceptions cycle, 2026-05-10)
**Authors:** parasitoid project operator (memo 2026-05-09); two
external consultants; pack maintainer + Claude Opus 4.7
**Replaces:** `test_file_policy.allow_after_red_confirmed` boolean
(deprecated in v1.7.x, removed in v2.0.0)

## Why

The legacy `test_file_policy.allow_after_red_confirmed` boolean
exists to enforce "don't weaken tests in green phase" — a real
TDD failure mode. But the boolean treats two structurally distinct
categories as one:

1. **Test weakening to make green pass** — what the rule is meant
   to block. Loosening assertions, deleting cases, replacing strict
   matchers with permissive ones.
2. **Co-evolution of pre-existing tests with an approved
   production-signature change** — happens whenever the green
   phase changes a function's signature in a way that breaks
   pre-existing test call sites. The test edits are mechanical;
   they're forced by a contract change the operator already
   approved at gate 1.

The parasitoid trial (10 Tier 1 cycles, 2026-04-23 → 2026-05-09)
showed 4/4 cycles hit the underlying co-evolution pattern; 2/4
explicitly flipped the boolean to `true` as workaround. Two
external consultants converged independently on the same
replacement design: typed exceptions with operator authorization
+ structural validation + audit log + auto-expiry.

## What

A typed-exception system that distinguishes the two categories
mechanically:

- **Typed**: each exception declares `type: mechanical_signature_propagation
  | compile_fix_only | import_only`. Validators differ per type.
- **Operator-authorized**: agent writes `status: pending`; operator
  replies `APPROVED EXCEPTION E-NNN`; agent runs `--approve E-NNN`
  to bump status; hook only allows edits while `status: approved`.
- **Mechanically validated**: validator checks per-file diffs for
  forbidden patterns (assertion changes for edit-existing; missing
  assertions for create-new). Per-file failure UX names offending
  files.
- **Auditable**: per-cycle log at `.tdd/audit/<cycle-id>.jsonl`
  (append-only, gitignored).
- **Auto-expiring**: cycle-scoped via `expires_after_next_green`;
  no manual cleanup needed.

## Architecture

### Schema (`tdd-config.json` `test_file_policy.post_red_mechanical_update`)

```jsonc
{
  "enabled": false,                       // opt-in for safe rollout
  "require_operator_approval": true,
  "exception_artifact": ".tdd/exceptions/post-red-test-edits.json",
  "audit_log_dir": ".tdd/audit",
  "expires_after_next_green": true,
  "exception_types": [
    "mechanical_signature_propagation",
    "compile_fix_only",
    "import_only"
  ],
  "validators": {
    "default_level": "regex_structural",  // v1.7.0: regex; v1.8: ast
    "active_profiles": ["stdlib", "testify"],  // opt-in: gomega
    "assertion_helper_patterns": [],      // project-defined helpers
    "no_skip_added": true,
    "no_test_deletion": true,
    "no_empty_t_run": true,
    "forbid_assertion_changes_for_existing_tests": true,
    "require_assertions_for_new_tests": true
  }
}
```

### Exception artifact (`.tdd/exceptions/post-red-test-edits.json`)

```jsonc
{
  "version": 1,
  "cycle_id": "<cycle-id>",
  "phase": "red_confirmed",
  "expires": "next_green_commit",
  "exceptions": [
    {
      "id": "E-001",
      "type": "mechanical_signature_propagation",
      "status": "approved",                // pending | approved | expired
      "approved_by": "operator",
      "approved_at": "<RFC3339>",
      "operations": ["edit_existing_tests", "create_new_tests"],
      "scope": {
        "paths": ["internal/modules/capital/**/*_test.go"],  // glob
        "symbols": ["ReconcileWithExchange"]
      },
      "reason": "<one-paragraph operator-readable rationale>",
      "binding": {
        "cycle_id": "<cycle-id>",
        "plan_hash": "<sha256(.tdd/current-plan.md)>",
        "red_proof_hash": "<sha256(.tdd/red-proof.md)>",
        "change_intent_hash": "<sha256(cycle_id|symbols|type|reason)>"
      }
    }
  ]
}
```

### Validator (`scripts/tdd/_lib_test_edit_exception.sh`)

Function: `validate_exception_diff <exception-json> <file1> [<file2> ...]`
(reads diff hunks from stdin).

- For `operations: edit_existing_tests`: scan + and - lines for
  assertion patterns matching `active_profiles`. Any match → fail.
- For `operations: create_new_tests`: scan the file for
  `func TestXxx(t *testing.T)` + at least one assertion + no
  unconditional `t.Skip`. Missing → fail.
- Per-file failure UX: emits a JSON report listing each file's
  status + reason + evidence; returns 1 (per-file fail) or 2
  (hard schema error). Hook denies the entire tool call but the
  agent sees which files failed.

Profiles:
- `stdlib`: `t.Error*`, `t.Fatal*`, `t.Skip*`, `t.Fail*`,
  `if (got|cond) ... t.(Error|Fatal)`.
- `testify`: `require.X(...)`, `assert.X(...)`.
- `gomega`: `Expect(...)`, `Ω(...)`.

Operator extends via `assertion_helper_patterns: ["mustEqual",
"requireSignal"]`.

### Hook integration (`require-tdd-state.sh`)

In the existing `test_file_policy` block, BEFORE the legacy
`if [[ "$M2_SET" == "true" && "$ALLOW_AFTER_RED" != "true" ]]`
deny:

1. Check `post_red_mechanical_update.enabled`. If false, skip
   typed-exception path (legacy boolean controls behavior).
2. Check `TEST_EDIT_EXCEPTION_DISABLE=1` killswitch. If set,
   skip typed-exception path.
3. Load `.tdd/exceptions/post-red-test-edits.json`. For each
   `TIER1_TESTS` file, find the first `status: approved` exception
   whose `scope.paths` glob matches AND whose `binding.plan_hash`
   matches the current plan.
4. If ALL `TIER1_TESTS` files match an approved exception:
   set `ALLOW_AFTER_RED=true` for this invocation, fall through
   to the legacy block-or-allow logic (which now allows).
5. Otherwise: fall through with `ALLOW_AFTER_RED` unchanged
   (legacy block fires).

Validator dispatch happens in the typed-exception path (matched
file → call `validate_exception_diff`); if the validator denies,
the exception attempt fails and the legacy block fires.

### Grant helper (`scripts/tdd/grant-test-edit-exception.sh`)

Two modes:

- `--type ... --paths ... --reason ... [--symbol ... --operations ...
   --cycle-id ...]`: creates `pending` entry, generates next E-NNN
  id. Default `operations: edit_existing_tests`.
- `--approve E-NNN` (or `E-001,E-002` or `E-001 through E-003`):
  bumps status to `approved`, sets `approved_by` + `approved_at`,
  computes binding hashes (plan, red-proof, change-intent), appends
  `granted` event to audit log.

### Audit log (`.tdd/audit/<cycle-id>.jsonl`)

Append-only JSON lines. Events:
- `granted`: `{ts, event: "granted", exception_id, cycle_id}`
  (written by `--approve`).
- `used`: validator allowed an edit (extension point — v1.7.0
  ships `granted` only; `used`/`denied`/`expired` deferred to
  v1.8 if operators report value).

### Killswitches

- `TEST_EDIT_EXCEPTION_DISABLE=1`: bypasses typed-exception lookup.
- `enabled: false` (default in v1.7.0): typed-exception system is
  inactive; legacy boolean controls behavior.

### Migration (deprecation warning)

Every consultation of `allow_after_red_confirmed` emits a stderr
deprecation warning (rate-limited per hook invocation):

```text
[require-tdd-state] DEPRECATED: test_file_policy.allow_after_red_confirmed
is a global post-red test-edit bypass. Use post_red_mechanical_update
typed exceptions instead. This boolean will be removed in v2.0.0.
```

The boolean continues to work in v1.7.x; removed in v2.0.0
(separate cycle, out of scope here).

## Non-goals (v1.7.0; deferred)

- `schema_predicate_correction` exception type → v1.8.0.
- AST-level assertion detection (Level 2 validators) → v1.8.0.
- Robust `signature_change_hash` extraction via `go/parser` →
  v1.8.0. v1.7.0 uses `change_intent_hash = sha256(cycle_id|
  symbols|type|reason)` — bound to operator-approved cycle intent.
- Removal of `allow_after_red_confirmed` boolean → v2.0.0.
- Encrypted/signed audit log → v2.0+.
- `used`/`denied`/`expired` event types in audit log → v1.8 if
  operators report value.

## Honest validator limits

The regex-based validator catches:

- testify `require.*` / `assert.*` family — high confidence.
- gomega `Expect()` / `Ω()` — opt-in via `active_profiles`.
- stdlib `t.Errorf` / `t.Fatal` family + `if ... t.Error` patterns
  — moderate confidence; misses unusual control flows.

Misses (without operator-declared `assertion_helper_patterns`):

- Custom helpers: `mustEqual(t, got, want)`, `requireSignal(...)`.
- Wrapped patterns inside higher-order test combinators.
- Semantic weakening that preserves syntax (e.g., changing the
  expected value but keeping the same assertion form).

For these, the operator/agent review at exception-grant time is
the remaining protection. Operators with custom-helper-heavy
codebases should declare their helpers in
`validators.assertion_helper_patterns`.

## References

- Parasitoid trial memo, 2026-05-09 (operator + Claude Opus 4.7).
- Two consultant analyses converging on typed-exception design.
- Pack maintainer's synthesized comparison
  (chat history, 2026-05-10).
