# TDD Workflow (Tier Model)

This document describes the tiered TDD discipline applied to Go changes
in this repository. It is referenced by:

- `.claude/skills/go-tdd-feature/SKILL.md`
- `.claude/skills/go-tdd-bugfix/SKILL.md`
- `.claude/hooks/route-to-tdd.sh` (advisory router)
- `.claude/hooks/require-tdd-state.sh` (blocking edit-time gate on Tier 1)
- `.claude/hooks/require-second-opinion.sh` (additional edit-time gate on Tier 1)
- `.claude/hooks/gate-tier1-commit.sh` (blocking commit-time gate on Tier 1)

## Tier Model

| Tier | Trigger | Process |
|------|---------|---------|
| **Tier 1 — Full ceremony** | File matches `.tdd/tdd-config.json` `tier1_path_regexes` | spec → APPROVED SPEC → red proof → APPROVED GREEN → green → APPROVED IMPLEMENTATION → commit. Three operator gates. Four plan markers. Edit and commit hooks block on missing markers. |
| **Tier 2 — Standard discipline** | Production Go code outside Tier 1 | `minimal-go-change` skill. Red-before-green where tractable. Race detector green. No plan file. No hook blocks. |
| **Tier 3 — Light** | Test infrastructure, refactors with full coverage | No ceremony. CI catches regressions. |
| **Tier 4 — None** | Docs, CHANGELOG, `.claude/` config, CI YAML | No process. Hooks silent on these paths. |

## Tier 1 — Full cycle

```
1.  Spec → .tdd/current-plan.md filled in.
2.  STOP. Operator: APPROVED SPEC (or plain APPROVED at gate 1).
3.  Set marker: Human approved spec: yes.
4.  Write failing tests. Run them. Capture VERBATIM output to .tdd/red-proof.md.
5.  Fill "Why this is not a false red" section.
6.  Commit: red(<id>): <description>
7.  Set marker: Red phase confirmed: yes.
8.  STOP. Operator: APPROVED GREEN (or plain APPROVED at gate 2).
    The operator's reply at gate 2 has TWO meanings: red proof is valid
    AND green phase is authorized.
9.  Set marker: Green phase authorized: yes.
10. Edit-time hooks now permit production edits on Tier 1 paths.
11. Implement. Tests go green. Race detector green.
12. Capture .tdd/green-proof.md (verbatim passing test output).
13. Run /second-opinion diff. Adjudicate findings. Write
    .tdd/second-opinion-completed.md.
14. STOP. Operator reads the diff + adjudication. Operator: APPROVED
    IMPLEMENTATION (or plain APPROVED at gate 3).
15. Set marker: Implementation reviewed: yes.
16. Commit: green(<id>): <description>
17. Set marker: Green phase confirmed: yes (informational; not gated).
18. Refactor (no behavior change). Linters green.
19. Commit: refactor(<id>): <description> (separately).
20. Set marker: Refactor phase complete: yes (informational; not gated).
21. Final test sweep. Update CHANGELOG.
```

## Gate vocabulary

| Operator command | Meaning |
|---|---|
| `APPROVED SPEC` | Gate 1: spec accepted; red phase may begin |
| `APPROVED GREEN` | Gate 2: red proof valid AND green phase authorized; production code may be written |
| `APPROVED IMPLEMENTATION` | Gate 3: implementation reviewed; commit may proceed |
| `APPROVED` (plain) | Inferred from next-pending marker — works for any gate |
| `CHANGES <reason>` | Revise current phase, re-ask |
| `STOP` | Halt cycle; leave partial state |

The plain `APPROVED` form is accepted for backwards compatibility and
for cycles where the operator and model have established context. The
explicit form is recommended for security-sensitive Tier 1 cycles where
audit clarity matters.

## Plan markers (4-marker model)

```text
Human approved spec: yes/no            <- M1 (gate 1)
Red phase confirmed: yes/no            <- M2 (set after red proof captured)
Green phase authorized: yes/no         <- M3 (gate 2)
Implementation reviewed: yes/no        <- M4 (gate 3, commit-time)
```

Edit-time hooks (`require-tdd-state.sh`, `require-second-opinion.sh`)
require M1+M2+M3. Commit-time hook (`gate-tier1-commit.sh`) additionally
requires M4 plus `.tdd/green-proof.md` and a fresh
`.tdd/second-opinion-completed.md` (mtime <60min).

**Backwards compat:** old marker `Human approved implementation: yes` is
honored as `Green phase authorized: yes` for one minor version with a
stderr deprecation warning. Run `scripts/migrate-tdd-markers.sh` to
update in-flight plans.

## Forbidden

- **Self-approving.** Never set any of the four markers to `yes` without
  an explicit operator `APPROVED` reply at the corresponding gate.
- **Editing tests in green phase.** Phase-aware test policy in the
  config (`test_file_policy`) blocks `_test.go` edits after `Red phase
  confirmed: yes` is set. To return to red phase, the operator must
  explicitly authorize setting M2 back to `no` and a revised spec.
- **Paraphrased red proof.** Verbatim test output is the artifact that
  proves the test ran and failed.
- **False reds.** The "Why this is not a false red" section must
  explain that the failure is genuine, not a setup error.
- **Skipping `/second-opinion diff` for Tier 1 green commits.** The
  commit hook denies if the adjudication artifact is missing or stale.

## Bypass procedure

For an emergency hotfix where the operator vouches for the change:

1. Edit `.tdd/current-plan.md` to set all four required markers to
   `yes`.
2. Document the bypass reason in the commit message.
3. Open a follow-up issue to add the missing test.
4. The CI `tdd-ceremony-check` job will flag the missing red commit;
   the bypass reason should be in the PR/MR description.

The bypass is for **genuine emergencies only**. Routinizing it weakens
the gate's signal value — it should be rare enough that every bypass
is an audit-loggable event.

## Why this exists

Three operator-approval gates on Tier 1 paths catch three different
failure modes:

- **Gate 1 (spec)** catches the agent inferring the wrong invariant from
  the user's request before any code is touched.
- **Gate 2 (red proof + green authorization)** catches false-red proofs
  and ensures the operator explicitly authorizes production edits.
- **Gate 3 (implementation review)** catches scope creep, team-style
  mismatches, and "is this the right thing to ship?" judgment calls
  that automated `/second-opinion diff` review cannot fully cover.

The hooks are the structural defense. CLAUDE.md rules are advisory —
documented incidents prove the agent will violate text rules under
pressure.

## Integration guards (commit-time)

The commit gate also runs project-level **integration guards** — regex
patterns declared in `.tdd/tdd-config.json` (`integration_guards` array).
Guards encode invariants that aren't easily expressed as integration
tests, e.g. "no direct calls to API X outside wrapper Y". On any guard
violation outside the allowed-globs list, the commit is denied (or
warned, if `severity: warn`).

Guards are FALLBACK protection. Integration tests are primary. See
[`.claude/rules/go-integration-guards.md`](../../.claude/rules/go-integration-guards.md)
for the decision tree and schema.

## History

The earlier "two gates" model produced a deadlock when the documentation
treated marker 3 (then named `Human approved implementation: yes`) as a
post-implementation review while the hook used it as a pre-green
authorization. The 4-marker model resolves this by separating
authorization (M3) from review (M4). Full design rationale in
[`docs/specs/tdd-gate-conflict-resolution-spec.md`](../specs/tdd-gate-conflict-resolution-spec.md).
