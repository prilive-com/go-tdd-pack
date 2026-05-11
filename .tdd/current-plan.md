# Feature Plan: v1.8.0-ast-validator-and-audit-integrity — replace regex validator with AST + harden audit trail

Status: active
Cycle ID: v1.8.0-ast-validator-and-audit-integrity
Change type: feature (new validator infra + new exception type + new
                     audit integrity + new caps; closes 5 deferred
                     items from v1.7.0 disposition matrix)
Tier: 1 (touches `.claude/hooks/require-tdd-state.sh` — declared
         Tier 1 in `tdd-config.json` `tier1_path_regexes`)

<!-- TDD ceremony markers. Set each ONLY after the matching operator APPROVED reply. -->
Human approved spec: yes
Red phase confirmed: yes
Green phase authorized: yes
Implementation reviewed: yes

## Feature goal

v1.7.0 shipped typed test-edit exceptions on a regex-only validator
because AST analysis was deferred. Seven `/second-opinion` rounds
caught 24 P0/P1 findings — most rooted in regex's structural blind
spots (no parse-tree, no scope analysis, no AST symbol resolution).

v1.8.0 closes the deferred backlog by introducing a Go-based AST
helper invoked from the bash validator library. The helper handles
parse-tree work that regex genuinely can't do: import-block
boundary tracking, mechanical-signature-propagation helper-shape
preservation at AST level, compile_fix_only "uses of declared
symbol" scope check, and a NEW exception type
`schema_predicate_correction` (struct-tag / field-rename
propagation that regex can't safely characterize).

Two governance hardenings ride along: per-cycle exception count
caps (operator can't accidentally rubber-stamp 30 exceptions in
one cycle) and an append-only sha-chain over the audit log
(previously trust-only).

## Business/domain invariants

The change MUST preserve:

1. **Test-weakening prevention.** No new exception type may permit
   weakening assertions in existing tests. AST validation is
   STRICTER than regex (catches more), never looser.
2. **Operator-in-the-loop.** No exception is granted without an
   explicit operator APPROVED reply. AST helper does not
   self-grant.
3. **Cycle-scoped + git-HEAD-bound.** Lifecycle invariants from
   v1.7.0 round-7 F4 unchanged — `binding.head_at_approval` still
   the lifecycle authority.
4. **Audit trail integrity.** Append-only invariant becomes
   ENFORCEABLE (was trust-only in v1.7.0). Sha-chain ties each
   line to the prior line's hash; tampering with any line
   invalidates the chain.
5. **Hash binding.** `binding.change_intent_hash` extends to
   include exception type's AST-relevant fields when applicable
   (e.g., `schema_predicate_correction` includes the renamed
   field name in the hash so a different rename can't reuse the
   approval).
6. **Killswitch parity.** `TEST_EDIT_EXCEPTION_DISABLE=1`
   continues to bypass the entire typed-exception system.
   Additionally `TDD_AST_VALIDATOR_DISABLE=1` falls back to regex
   when AST helper is unavailable (graceful degradation).

The change MUST NOT:

1. Change the v1.7.0 schema in a way that breaks existing
   approved exception artifacts (additive only — new fields
   default to safe values when absent).
2. Require a Go binary to be pre-built or distributed. The
   AST helper runs via `go run` (Go ≥1.26.2 already a pack hard
   dep per `CLAUDE.md` "Version floors").
3. Strip `set -euo pipefail` discipline from hooks.
4. Add the new `schema_predicate_correction` type to the
   default `exception_types` list (opt-in via config — same
   conservative-rollout pattern as v1.7.0's `enabled: false`).

## Acceptance criteria

### AC1 — Go AST helper

1.1 New file: `scripts/tdd/ast/validator.go` (single-file Go
    program; package `main`; runs via
    `go run scripts/tdd/ast/validator.go <subcommand> <args>`).
1.2 Subcommands:
    - `import-block-check <unified-diff-on-stdin> --paths a,b,c` —
      verifies every `+` and `-` import-shaped line lives inside an
      `import (...)` block (or is a top-level `import "x"` decl).
      Exit 0 = pass; exit 1 = "outside import block" with offending
      lines on stderr.
    - `mech-sig-prop-check <diff> --symbols X,Y,Z` — for changed
      assertion lines, verifies the helper-shape (function call
      tree) is preserved between `-` and `+` sides; only call-site
      arguments may change AND the changed argument must contain a
      declared symbol from `--symbols`. Exit 0/1.
    - `compile-fix-scope-check <diff> --symbols X,Y,Z` —
      AST-resolves each `+`/`-` line to the enclosing function call
      / type expression; rejects if no declared symbol is *used*
      (AST identifier match, not regex word match).
    - `schema-predicate-check <diff> --old-name X --new-name Y` —
      validates the diff is a pure rename of `X` to `Y` in
      assertion predicates and struct tags; rejects any other
      structural change.
1.3 Honest output contract: each subcommand emits a JSON report
    on stderr `{ok: bool, reason: "...", evidence: ["..."]}` and
    a single exit code (0 pass, 1 reject, 2 hard error).
1.4 No external Go dependencies — uses only the standard
    library (`go/parser`, `go/ast`, `go/token`, `go/types`).
1.5 Compiles and runs on `go run` cold-start in <500ms (smoke
    test verifies; pre-warm via `go build` is the operator's
    optimization).

### AC2 — Validator library dispatches to AST helper

2.1 `scripts/tdd/_lib_test_edit_exception.sh` adds
    `_v18_ast_check <subcommand> <args...>` helper that:
    - Locates `scripts/tdd/ast/validator.go` relative to lib
      (`$(dirname "${BASH_SOURCE[0]}")/ast/validator.go`).
    - Runs `go run "$validator_go" <subcommand> ...` with the
      diff piped on stdin.
    - Honors `TDD_AST_VALIDATOR_DISABLE=1` — when set, returns
      exit 0 (pass) AND emits a stderr warning so operators see
      it, then validator falls through to existing regex check.
    - When `go` binary is absent, behaves identically to the
      killswitch (warn + fall through to regex).
2.2 `mechanical_signature_propagation` validation order:
    - First: AST helper-shape preservation check (AC1.2 mech-
      sig-prop-check).
    - Second: existing scope.symbols regex word-boundary check
      (defense in depth).
    - Both must pass.
2.3 `compile_fix_only` validation order:
    - First: AST symbol-uses check (AC1.2 compile-fix-scope-
      check).
    - Second: existing regex word-boundary check.
    - Both must pass.
2.4 `import_only` validation order:
    - First: AST import-block check (AC1.2 import-block-check).
    - Second: existing regex shape check.
    - Both must pass.
2.5 Conservative-by-design preserved: AST + regex AND-gate
    means a false-positive on either rejects the exception.
    Operator unblocks via `--type` change or scope refinement.

### AC3 — `schema_predicate_correction` exception type

3.1 New type added to:
    - `tdd-config.json` `exception_types` (off by default;
      operators must opt in by adding it to their list).
    - Validator type whitelist in `_lib_test_edit_exception.sh`.
    - Type whitelist in `grant-test-edit-exception.sh`.
3.2 Required scope fields: `--paths` (test files affected),
    `--old-name` (deprecated symbol/field name), `--new-name`
    (target symbol/field name). The grant helper's CLI is
    extended.
3.3 Validator runs `schema-predicate-check` AST subcommand
    (AC1.2) with `--old-name` / `--new-name` from scope.
3.4 `change_intent_hash` for this type:
    `sha256(cycle_id|symbols|type|reason|paths|operations|old_name|new_name)`.
    A different rename pair invalidates the hash.

### AC4 — Per-cycle exception count caps

4.1 New `tdd-config.json` field:
    `test_file_policy.post_red_mechanical_update.max_per_cycle`
    (integer; default 5; 0 = no cap).
4.2 Hook (require-tdd-state.sh) at typed-exception lookup time:
    - Counts `approved` entries in
      `.tdd/exceptions/post-red-test-edits.json` whose
      `binding.cycle_id == current_cycle_id`.
    - If count > max_per_cycle: deny ALL typed-exception
      lookups for the rest of the cycle. Stderr message tells
      the operator the cap was hit + suggests reverting to
      red phase OR raising the cap with documented reason.
4.3 Grant helper (`grant-test-edit-exception.sh`) `--approve`
    path also enforces the cap as a preflight (refuse to
    approve the N+1th exception in a cycle).
4.4 The cap is per CYCLE (cycle_id), not per artifact, so
    rotating cycle IDs resets it.

### AC5 — Audit-log sha-chain integrity

5.1 Each appended audit-log line gains a `prev_sha` field
    holding the sha256 of the previous line (with newline
    stripped). First line in a log has `prev_sha: ""`.
5.2 New helper script `scripts/tdd/verify-audit-chain.sh
    <cycle-id>`:
    - Reads `.tdd/audit/<cycle-id>.jsonl` line by line.
    - Recomputes the chain; reports the first divergence.
    - Exit 0 = chain intact; exit 1 = tamper detected.
5.3 Hook (require-tdd-state.sh) calls verify-audit-chain.sh
    at typed-exception dispatch. Tamper → fail closed (deny
    all typed exceptions for the cycle; legacy boolean path
    unaffected).
5.4 Grant helper writes `prev_sha` correctly when appending.

### AC6 — Graceful degradation when AST unavailable

6.1 When `command -v go` returns false OR `go run scripts/tdd/
    ast/validator.go --version` exits non-zero, validator
    library:
    - Emits stderr warning: `[lib_test_edit_exception] WARN:
      Go AST helper unavailable; falling back to regex-only
      validation. Install Go ≥1.26.2 for stricter governance.`
    - Falls back to v1.7.0 regex behavior for that exception
      type.
6.2 `TDD_AST_VALIDATOR_DISABLE=1` env-var killswitch (AC2.1)
    is the same code path — emits the warning but exits the
    AST check successfully so the regex-only fall-through
    runs.
6.3 Smoke test fixture explicitly removes `go` from PATH and
    verifies fallback works without breaking the hook.

### AC7 — Smoke tests + spec doc

7.1 ~12 new acceptance tests:
    - v18_ast_validator_go_compiles_and_runs (AC1.1, AC1.5)
    - v18_ast_import_block_check_rejects_outside_block (AC1.2)
    - v18_ast_mech_sig_prop_check_rejects_helper_change (AC1.2)
    - v18_ast_compile_fix_scope_uses_ast_not_regex (AC1.2)
    - v18_ast_schema_predicate_check_only_renames (AC1.2)
    - v18_validator_dispatches_to_ast_helper (AC2.1)
    - v18_validator_ast_killswitch_falls_back_to_regex (AC2.1, AC6.2)
    - v18_validator_no_go_binary_warns_and_falls_back (AC6.1, AC6.3)
    - v18_schema_predicate_correction_grant_and_validate (AC3.*)
    - v18_max_per_cycle_cap_blocks_at_threshold (AC4.2, AC4.3)
    - v18_max_per_cycle_zero_means_no_cap (AC4.1)
    - v18_audit_chain_detects_tamper (AC5.2, AC5.3)
    - v18_audit_chain_intact_passes_verify (AC5.2)
    - v18_audit_chain_grant_helper_writes_prev_sha (AC5.4)
7.2 `docs/specs/ast-validator-and-audit-integrity-v1.8.0-spec.md`
    captures: design rationale, AST helper architecture,
    `go run` cold-start budget, schema_predicate_correction's
    use case, audit chain math, killswitch semantics,
    backwards-compat with v1.7.0 artifacts.
7.3 `.claude/rules/go-tdd.md` adds `schema_predicate_correction`
    to the typed-exception types list + a "verify audit chain"
    operator note.
7.4 `CHANGELOG`-style note in spec doc covers v1.7 → v1.8
    migration (artifacts written by v1.7 grant helper still
    work; v1.8 grant helper writes the `prev_sha` field, but
    its absence in v1.7 lines is treated as legitimate
    pre-v1.8 history — the chain check skips them with a
    one-shot warning).

### AC8 — Killswitch parity + documentation

8.1 `TDD_AST_VALIDATOR_DISABLE=1` documented in
    `.claude/rules/go-tdd.md` alongside
    `TEST_EDIT_EXCEPTION_DISABLE`.
8.2 Both killswitches require commit-message documentation
    when used (honor system; consistent with v1.7.0 AC8.3).
8.3 Spec doc includes a decision table:
    `Go available? AST disabled? → behavior`.

## Affected code

- `.tdd/tdd-config.json` — additive: `max_per_cycle` field;
  optional `schema_predicate_correction` in operator-managed
  `exception_types` array.
- `.claude/hooks/require-tdd-state.sh` — Tier 1 file. Per-cycle
  cap check; audit-chain verify call. ~30 lines net.
- `scripts/tdd/_lib_test_edit_exception.sh` — AST dispatch
  helpers; per-type AST integration. ~120 lines net.
- `scripts/tdd/grant-test-edit-exception.sh` — `schema_predicate_
  correction` schema flags; `--old-name` / `--new-name` CLI;
  cap preflight; `prev_sha` writer. ~80 lines net.
- `scripts/tdd/ast/validator.go` — NEW. Single-file Go program
  implementing the four subcommands. ~400 lines Go.
- `scripts/tdd/verify-audit-chain.sh` — NEW. ~40 lines bash.
- `scripts/tdd-test-hooks.sh` — ~14 new RED tests (~250 lines).
- `.claude/rules/go-tdd.md` — schema_predicate_correction
  documentation; killswitch table; verify-audit-chain note.
- `docs/specs/ast-validator-and-audit-integrity-v1.8.0-spec.md`
  — NEW design doc.

## Implementation order (dependency-driven)

1. **AC1 (AST helper Go program)** — standalone; testable via
   direct `go run` invocations. Ship four subcommands, each
   with stderr JSON contract + exit code.
2. **AC6 (graceful degradation)** — implement fallback path in
   validator library before AC2 dispatch. This means even
   when AC2 is wiring up dispatch, the no-Go path is already
   handled.
3. **AC2 (validator dispatches to AST)** — wire each exception
   type to its subcommand.
4. **AC3 (schema_predicate_correction type)** — add type to
   whitelists; grant helper CLI; validator wiring.
5. **AC5 (audit-chain integrity)** — `prev_sha` writer + verify
   helper + hook hookup.
6. **AC4 (per-cycle caps)** — count + threshold check in hook
   AND grant helper preflight.
7. **AC7 (smoke tests)** — exercises every code path; many
   small fixtures rather than a few large ones.
8. **AC8 (killswitch docs + decision table)** — closes the loop.

The Tier 1 edit (require-tdd-state.sh, AC4 + AC5) is sequenced
LATE so most validation is mechanical (Go program + library
dispatch + helper) before the gate file moves.

## Non-goals (this cycle)

- Pre-built Go binary distribution. v1.8.0 ships a `.go` source
  file invoked via `go run`; cold-start latency is the
  operator's optimization.
- Replacing the regex validator entirely. Regex stays as
  defense-in-depth and as the no-Go fallback path.
- Encrypted/signed audit log. Sha-chain is enough for v1.8.0
  (operator-tampering detection, not protection from a
  compromised host).
- Audit-log archival/rotation. v1.7.0 already gitignores the
  log; cycle close cleanup is operator-managed.
- Refactoring the v1.7.0 artifact schema. Only additive
  changes.
- New exception types beyond `schema_predicate_correction`.
  Future types are tracked in v1.9 backlog.

## Risk register

| Risk | Mitigation |
|---|---|
| `go run` cold-start (~300ms) is slow vs regex | Acceptable. Hook fires per Edit/Write; operator hot-path is interactive and tolerates 300ms. Smoke test verifies <500ms budget. |
| Go binary changes between Go versions break the parser | Use only `go/ast` + `go/parser` + `go/token` from stdlib (stable since Go 1.0). Avoid `go/types` global state. |
| AST helper crashes on partial Go syntax (test files mid-edit) | Helper uses `parser.AllErrors` mode; collects errors but still returns the partial AST; subcommand decides whether unparseable → exit 1 (reject) or pass (lenient). Each subcommand documents its choice. |
| Audit-chain sha computation differs between platforms | Use `sha256sum` with explicit `awk '{print $1}'` — same as existing hash binding. Fall back to `shasum -a 256` on macOS. |
| Operator manually edits audit log to reset chain | Detected by verify-audit-chain.sh; hook fails closed for typed exceptions; legacy boolean path unaffected. Operator must `rm` the log + restart cycle (intentional friction). |
| Cap = 5 too tight for legitimate cross-package refactors | Operator overrides `max_per_cycle` in config with documented reason in the same commit. Default is conservative; large refactors are flagged. |
| Tests pass on regex-only fall-through; AST path never exercised | RED test `v18_validator_dispatches_to_ast_helper` explicitly asserts the AST exit code drives the validator decision (not the regex). |
| schema_predicate_correction edge cases (struct tag changes, comment-only) | Validator's AST subcommand walks the parse tree; each non-rename change rejected. Documented in spec; covered by the AC3 RED test. |
| `/second-opinion` rounds find regex-style false positives in AST helper | Go's parser is canonical; false positives from AST analysis are rarer and more legitimate (parse-error → reject is correct). Budget 4-6 rounds. |

## Smoke test growth target

483 baseline (post v1.7.0) + ~14 new = **~497 passing, 0 failing**.

## Effort estimate (honest)

| Phase | Time |
|---|---|
| Cycle plan (this draft) | ~1h (done) |
| Red phase (~14 RED tests) | 2h |
| Green phase | 6h (Go program is the bulk: ~3h; library dispatch + caps + chain + grant: ~3h) |
| /second-opinion review (~4-6 rounds expected) | 4-6h |
| Adjudication artifacts | 1.5h |
| Total elapsed | **~14-17h** |

Slightly under v1.7.0 because:
- Architecture is set (no schema redesign).
- AST is canonical (regex's edge-case roulette doesn't apply).
- Audit chain + caps are well-scoped (sha-chain math is closed-form).

But could exceed v1.7.0 if:
- `go run` cold-start surprises us across rounds.
- AST helper's parse-error handling reveals subtle classes.
