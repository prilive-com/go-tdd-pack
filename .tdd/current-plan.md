# Feature Plan: v1.7.0-typed-test-edit-exceptions — replace boolean with auditable typed exceptions

Status: active
Cycle ID: v1.7.0-typed-test-edit-exceptions
Change type: feature (new schema + new hook integration + new
                     library + deprecation of legacy boolean)
Tier: 1 (touches `.claude/hooks/require-tdd-state.sh` — declared
         Tier 1 in `tdd-config.json` `tier1_path_regexes`)

<!-- TDD ceremony markers. Set each ONLY after the matching operator APPROVED reply. -->
Human approved spec: yes
Red phase confirmed: yes
Green phase authorized: yes
Implementation reviewed: yes

## Feature goal

Replace the all-or-nothing boolean
`test_file_policy.allow_after_red_confirmed` with a typed,
operator-authorized, mechanically-validated, auditable exception
system for post-red test-edit work.

The boolean's intent is correct (block "weaken a red test until
green passes" failure mode) but its blast radius is the entire
repository for the entire cycle. The parasitoid trial (memo
2026-05-09; 10 Tier 1 cycles, 4/4 hit the underlying
co-evolution-with-signature-change pattern, 2/4 explicitly
flipped the boolean as workaround) showed cross-cutting refactors
are NOT emergencies — they're routine, and the boolean's
"EMERGENCY ONLY" framing produces consistent operator friction.

The replacement: agent declares a typed exception with reason +
scope; operator authorizes with explicit reply; hook validates
diff structure mechanically (no assertion changes for edit mode;
assertion presence required for create mode); audit log captures
grant + use; auto-expiry on green commit. The boolean stays for
v1.7.x with a stderr deprecation warning; removed in v2.0.0.

## Business/domain invariants

The change MUST preserve:

1. **Test-weakening prevention.** No exception type may permit
   weakening assertions in existing tests. The structural
   validator catches this for testify/gomega/stdlib forms.
2. **Operator-in-the-loop.** No exception is granted without an
   explicit operator APPROVED reply. Agent self-grants are not
   permitted.
3. **Cycle-scoped.** Exceptions auto-expire on green commit
   (`.tdd/green-proof.md` written). Forgetting to clean up is
   not a failure mode operators need to remember.
4. **Audit trail.** Every grant + use writes to `.tdd/audit/`
   with the full exception envelope. Append-only invariant
   enforced at commit time (smoke test).
5. **Hash binding.** Each exception is bound to the specific
   cycle + symbol + intent (`change_intent_hash = sha256(cycle_id
   + symbol + exception_type + reason + approved_plan_section)`).
   Reuse on a different refactor invalidates the binding.
6. **Killswitch parity.** `TEST_EDIT_EXCEPTION_DISABLE=1` env var
   bypasses the typed exception system, mirroring the pattern
   used by `SECOND_OPINION_DISABLE`, `TDD_GIT_HOOK_DISABLE`,
   `SECOND_OPINION_HASH_DISABLE`. Documented as emergency-only
   with mandatory commit-message reason.

The change MUST NOT:

1. Change the `tier1_path_regexes` semantics or any other
   per-file gate.
2. Allow short-circuiting M1-M4 ceremony.
3. Strip `set -euo pipefail` discipline from hooks.
4. Be enabled by default in v1.7.0 (`enabled: false` initially).

## Acceptance criteria

### AC1 — Schema in `tdd-config.json`

1.1 New `test_file_policy.post_red_mechanical_update` object with
    fields:
    ```jsonc
    {
      "enabled": false,
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
        "default_level": "regex_structural",
        "active_profiles": ["stdlib", "testify"],
        "assertion_helper_patterns": [],
        "no_skip_added": true,
        "no_test_deletion": true,
        "no_empty_t_run": true,
        "forbid_assertion_changes_for_existing_tests": true,
        "require_assertions_for_new_tests": true
      }
    }
    ```
1.2 `enabled: false` is the default — opt-in for safe rollout.
1.3 `schema_predicate_correction` is intentionally absent
    (deferred to v1.8 per the consultant-synthesized analysis).
1.4 The legacy `allow_after_red_confirmed: false` field stays
    in place with full meaning.

### AC2 — Exception artifact format

2.1 Path: `.tdd/exceptions/post-red-test-edits.json` (gitignored;
    per-cycle local artifact).
2.2 Schema:
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
          "status": "pending|approved|expired",
          "approved_by": "operator | (empty when pending)",
          "approved_at": "<RFC3339> | (empty when pending)",
          "operations": ["edit_existing_tests", "create_new_tests"],
          "scope": {
            "paths": ["internal/modules/capital/**/*_test.go"],
            "symbols": ["ReconcileWithExchange"]
          },
          "reason": "<one-paragraph operator-readable rationale>",
          "binding": {
            "cycle_id": "<cycle-id>",
            "plan_hash": "<sha256>",
            "red_proof_hash": "<sha256>",
            "change_intent_hash": "<sha256>"
          }
        }
      ]
    }
    ```
2.3 Multiple `exceptions[]` entries supported in one artifact;
    each independently bound + audited.
2.4 `scope.paths` may be glob patterns (operator-friendly for
    cross-package refactors); hook expands via
    `git ls-files <pattern>` at validation time.

### AC3 — Validator library

3.1 New file: `scripts/tdd/_lib_test_edit_exception.sh`.
3.2 Function: `validate_exception_diff <exception-json> <files-changed>`
    returns 0 on pass, 1 on per-file failure (with diagnostic
    listing offending files), 2 on hard schema error.
3.3 For `operations: ["edit_existing_tests"]`: validates that
    no assertion patterns are added/removed (regex per
    `active_profiles` — stdlib + testify default; gomega opt-in).
3.4 For `operations: ["create_new_tests"]`: validates that new
    test files contain at least one `func TestXxx(t *testing.T)` +
    at least one assertion mechanism + no unconditional `t.Skip`.
3.5 Per-profile patterns (`stdlib`, `testify`, `gomega`) are
    declared in the lib; operator can opt-in to additional
    profiles via `active_profiles` array.
3.6 `assertion_helper_patterns` config field lets operators
    declare project-specific helper names (e.g., `mustEqual`).
3.7 Per-file failure UX: validator emits a JSON report
    `{exception_id, files: [{path, status, reason, evidence}]}`;
    hook denies the entire tool call but the report names the
    specific offending files.
3.8 Honest documentation: regex-based; catches testify-family
    cleanly; `if got != want { t.Errorf(...) }` and custom
    helpers (without operator-declared patterns) require AST-
    level analysis (deferred to v1.8).

### AC4 — Hook integration

4.1 `.claude/hooks/require-tdd-state.sh`: when `M2_SET=true` AND
    `ALLOW_AFTER_RED != true` AND
    `post_red_mechanical_update.enabled = true`, the hook checks
    the exception artifact BEFORE applying the existing block.
4.2 Lookup logic:
    - Load `.tdd/exceptions/post-red-test-edits.json`.
    - Find entry with `status: approved` whose `scope.paths`
      glob matches the file being edited AND whose binding
      hashes match current state.
    - If found: source `_lib_test_edit_exception.sh`, run
      `validate_exception_diff`, allow on pass, deny on fail.
    - If no matching approved exception: fall through to the
      existing block (denial directive includes a hint about
      the typed-exception path as alternative).
4.3 Killswitch: `TEST_EDIT_EXCEPTION_DISABLE=1` skips the
    typed-exception lookup entirely (hook proceeds to legacy
    block-or-allow logic). Documented as emergency-only.
4.4 If `enabled: false` (the default), the typed-exception
    lookup is skipped silently. The legacy boolean controls
    behavior as today.

### AC5 — Operator authorization workflow

5.1 New helper: `scripts/tdd/grant-test-edit-exception.sh`.
    Agent invokes:
    ```bash
    scripts/tdd/grant-test-edit-exception.sh \
      --type mechanical_signature_propagation \
      --paths "internal/modules/capital/**/*_test.go" \
      --symbol ReconcileWithExchange \
      --operations edit_existing_tests,create_new_tests \
      --reason "PR4 widens ReconcileWithExchange to (ReconcileResult, error); 12 pre-existing test call sites need mechanical updates."
    ```
5.2 The helper writes the exception entry to the artifact with
    `status: pending`. Agent then surfaces the entry to the
    operator + asks "APPROVED EXCEPTION E-001?".
5.3 When operator replies `APPROVED EXCEPTION E-001` (or
    `APPROVED EXCEPTIONS E-001, E-002` / `APPROVED EXCEPTIONS
    E-001 through E-003` for batch), agent runs:
    ```bash
    scripts/tdd/grant-test-edit-exception.sh --approve E-001
    ```
    which bumps `status: approved` + sets `approved_by`,
    `approved_at`. Computes the binding hashes from current
    plan + red-proof + cycle.
5.4 Hook only allows edits while `status: approved`. Pending
    or expired entries are ignored.

### AC6 — Audit log

6.1 Per-cycle log at `.tdd/audit/<cycle-id>.jsonl`. Append-only
    JSON lines. Each line: `{ts, event, exception_id,
    exception_type, scope, files, validator_passed, sha_before,
    sha_after, reason}`.
6.2 Events: `granted` (status: pending → approved), `used`
    (validator allowed an edit), `denied` (validator rejected an
    edit), `expired` (auto-expiry on green-proof write).
6.3 Smoke test (`v17_audit_log_append_only`): the audit log
    can only grow within a cycle; lines from previous staged
    state must remain unchanged. Asserted via diff vs `git show
    HEAD:.tdd/audit/<cycle-id>.jsonl`.
6.4 At cycle close (post-green commit), audit log is gitignored
    in-place but operators may explicitly stage it for cycle
    history.

### AC7 — Phased migration with deprecation warning

7.1 The boolean `allow_after_red_confirmed` continues to work
    in v1.7.x with original semantics.
7.2 Every consultation of the boolean (whether `true` or
    `false`) emits a stderr deprecation warning:
    ```text
    DEPRECATED: test_file_policy.allow_after_red_confirmed is a
    global post-red test-edit bypass. Use
    post_red_mechanical_update typed exceptions instead. This
    boolean will be removed in v2.0.0.
    ```
7.3 The warning is rate-limited (once per hook invocation, not
    once per consultation) so cycles with many test-file edits
    don't drown stderr.
7.4 Documentation note in `.claude/rules/go-tdd.md` "Bypass
    procedure" section explaining migration path with an
    example-driven walkthrough.
7.5 Removal in v2.0.0 (separate cycle, out of scope).

### AC8 — Killswitch

8.1 `TEST_EDIT_EXCEPTION_DISABLE=1` env var bypasses the
    typed-exception lookup. Documented as emergency-only.
8.2 When invoked, hook still emits the legacy boolean's
    deprecation warning (no chaining of bypasses).
8.3 Mandatory: when used, the operator MUST document the
    reason in the next commit message. Honor system; not
    enforced mechanically (consistent with other killswitches).

## Affected code

- `.tdd/tdd-config.json` — schema additions (post_red_mechanical_update block; new field on test_file_policy).
- `.claude/hooks/require-tdd-state.sh` — Tier 1 file. Add typed-exception lookup + dispatch + deprecation warning. ~70 lines net.
- `scripts/tdd/_lib_test_edit_exception.sh` — NEW. Validator library. ~200 lines bash.
- `scripts/tdd/grant-test-edit-exception.sh` — NEW. Operator-facing grant tool. ~120 lines bash.
- `scripts/tdd-test-hooks.sh` — fixtures: ~12-15 acceptance tests.
- `.claude/rules/go-tdd.md` — new "Typed test-edit exceptions" subsection of "Bypass procedure". ~80 lines markdown.
- `docs/specs/typed-test-edit-exceptions-v1.7.0-spec.md` — NEW design doc capturing the consultant-synthesized analysis.
- `.gitignore` — `.tdd/exceptions/` + `.tdd/audit/` per-cycle artifacts.

## Failing tests that capture the feature

| Test | What it pins |
|---|---|
| v17_schema_post_red_mechanical_update_present | AC1.1 |
| v17_schema_enabled_defaults_false | AC1.2 |
| v17_schema_predicate_correction_absent | AC1.3 |
| v17_artifact_schema_validates | AC2.2 |
| v17_artifact_supports_multiple_entries | AC2.3 |
| v17_artifact_path_globs_expand | AC2.4 |
| v17_validator_lib_exists_and_executable | AC3.1, AC3.2 |
| v17_validator_edit_existing_blocks_assertion_change | AC3.3 |
| v17_validator_create_new_requires_assertions | AC3.4 |
| v17_validator_per_file_failure_ux | AC3.7 |
| v17_validator_active_profiles_default_stdlib_testify | AC3.5 |
| v17_validator_assertion_helper_patterns_configurable | AC3.6 |
| v17_hook_typed_exception_path_when_enabled | AC4.1, AC4.2 |
| v17_hook_typed_exception_killswitch | AC4.3 |
| v17_hook_typed_exception_skipped_when_enabled_false | AC4.4 |
| v17_grant_helper_creates_pending_entry | AC5.1, AC5.2 |
| v17_grant_helper_approve_bumps_status | AC5.3 |
| v17_grant_helper_batch_approve | AC5.3 |
| v17_audit_log_records_grant_use_deny_expire | AC6.1, AC6.2 |
| v17_audit_log_append_only | AC6.3 |
| v17_legacy_boolean_emits_deprecation_warning | AC7.2 |
| v17_legacy_boolean_warning_rate_limited | AC7.3 |
| v17_test_edit_exception_disable_killswitch | AC8.1 |

~22 acceptance tests.

## Implementation order (dependency-driven)

1. **AC1 (schema)** — additive to tdd-config.json. Cheap; smoke
   tests verify schema shape.
2. **AC3 (validator library)** — standalone; can be developed
   and tested independently of hook integration.
3. **AC2 (artifact format)** — depends on validator's input
   contract.
4. **AC5 (grant helper)** — produces artifact entries.
5. **AC4 (hook integration)** — Tier 1 file edit. Touches
   require-tdd-state.sh. Depends on AC1, AC2, AC3.
6. **AC6 (audit log)** — written by grant helper + hook.
7. **AC7 (deprecation warning)** — small change to the existing
   boolean consultation block in require-tdd-state.sh.
8. **AC8 (killswitch)** — minimal addition.

Sequence: 1 → 3 → 2 → 5 → 4 → 6 → 7 → 8.

The Tier 1 edit (AC4) is sequenced LATE so most validation is
mechanical (library + helper + tests) before the gate file moves.

## Non-goals (this cycle)

- `schema_predicate_correction` exception type — deferred to
  v1.8.0. The consultant-synthesized analysis flagged it as
  high-risk; ship the three safer types first and gather trial
  data before adding it.
- AST-level assertion detection — deferred to v1.8.0. v1.7.0
  ships regex-based with declared limitations.
- Removing `allow_after_red_confirmed` — v2.0.0 (after at least
  one minor cycle with deprecation warnings observed in the
  wild).
- Robust `signature_change_hash` extraction via `go/parser` —
  v1.8.0. v1.7.0 uses the simpler
  `change_intent_hash = sha256(cycle_id + symbol + exception_type
  + reason + plan_section)` — bound to operator-approved cycle
  intent rather than to the specific Go signature bytes.
- Encrypted/signed audit log — v2.0+. Append-only invariant
  test is enough for v1.7.0.

## Risk register

| Risk | Mitigation |
|---|---|
| Validator regex misses non-testify weakening (e.g., `if got != want { t.Errorf }`) | Documented honestly in AC3.8 + active_profiles config + assertion_helper_patterns escape hatch. False negatives → operator/agent caught it via review; false positives → operator denies the exception. Conservative-by-design. |
| Operator forgets to expire the exception | `expires_after_next_green: true` auto-expires on green-proof.md write. No manual cleanup needed. |
| Glob pattern in scope.paths matches files outside intent | Operator authorizes the EXACT artifact (including expanded glob preview); helper script prints the resolved file list before asking for APPROVED. |
| Hash binding too strict (small plan iterations break the binding) | `change_intent_hash` uses the approved-plan-section, not the full plan or production diff. Iterations on production code or tests don't invalidate. |
| Forged exception artifact | Hook validates `binding.cycle_id == current_cycle_id` and `binding.plan_hash == sha256(.tdd/current-plan.md)`. Operator-supplied scope can't reach across cycles. |
| Deprecation warning floods stderr | Rate-limited to once per hook invocation per process (AC7.3). |
| Audit log append-only check produces false positives during local rebases | The check runs at commit time only. Local rebases reset the staged state; the invariant resumes from the new HEAD. |
| 27-round /second-opinion (per v1.6.2 trajectory) on a similar-Tier-1 edit | Realistic; budget 6-8 rounds; PUSHBACK on architectural-limit findings as we did in v1.6.2 R21/R25. |

## Smoke test growth target

426 baseline (post v1.6.2) + ~22 new = **~448 passing, 0 failing**.

## Effort estimate (honest)

| Phase | Time |
|---|---|
| Cycle plan (this draft) | ~1h (done) |
| Red phase (~22 RED tests) | 2.5h |
| Green phase (AC1 → AC8 implementation) | 5h |
| /second-opinion review (~6-8 rounds expected) | 6-8h |
| Adjudication artifacts | 1.5h |
| Total elapsed | **~16-18h** |

Matches the v1.7.0 budget agreed in the ChatGPT-synthesized
analysis. v1.6.2 took 27 rounds; this cycle should converge
faster because it's adding new files (less risk of breaking
existing hook semantics) and the schema is well-specified.
