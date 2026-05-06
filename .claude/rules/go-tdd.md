# TDD Discipline Rules

## When TDD ceremony applies

The full ceremony (spec → APPROVED SPEC → red → APPROVED GREEN → green →
APPROVED IMPLEMENTATION → commit) is **required** for any path matched by
`tier1_path_regexes` in `.tdd/tdd-config.json`. The `require-tdd-state.sh`
and `require-second-opinion.sh` hooks gate edits; the `gate-tier1-commit.sh`
hook gates the green commit.

For code outside Tier 1, lighter discipline applies:
- Red-before-green for fixes that have a tractable test surface.
- Race-detector green before any commit touching goroutine code.
- Integration tests for cross-module workflows.

## The three gates

The Tier 1 ceremony has **three** operator-approval gates. Each gate has
a distinct command (plain `APPROVED` is also accepted; the model infers
which gate based on which marker is next-pending).

**Gate 1 — Spec.** After the model writes `.tdd/current-plan.md` with the
spec sections filled in. The operator replies:
- `APPROVED SPEC` (or plain `APPROVED`) — model proceeds to red phase.
- `CHANGES <reason>` — model revises the spec.
- `STOP` — model halts the cycle.

**Gate 2 — Red proof and green authorization.** After failing tests are
committed and verbatim output is captured in `.tdd/red-proof.md`. The
operator's reply has TWO meanings: red proof is valid AND green phase is
authorized. This is one operator decision, not two.
- `APPROVED GREEN` (or plain `APPROVED`) — model sets `Green phase
  authorized: yes` and proceeds to write production code.
- `CHANGES <reason>` — model revises the red proof or the spec (see
  "Editing tests in green phase" under Forbidden below).
- `STOP` — model halts.

**Gate 3 — Implementation review.** After the green code is written,
tests pass, `.tdd/green-proof.md` is captured, and `/second-opinion diff`
has produced a fresh adjudication artifact. The operator reads the diff
and the adjudication, then replies:
- `APPROVED IMPLEMENTATION` (or plain `APPROVED`) — model sets
  `Implementation reviewed: yes`, then `git commit` is allowed by the
  commit gate.
- `CHANGES <reason>` — model revises the implementation.
- `STOP` — model halts.

## Plan markers

The hook checks markers in `.tdd/tdd-config.json`. Edit-time hooks
require the first three; the commit-time hook requires all four.

| Marker | Set when |
|---|---|
| `Human approved spec: yes` | After operator says APPROVED at gate 1 |
| `Red phase confirmed: yes` | After `.tdd/red-proof.md` is on disk and tests run RED (model sets this autonomously when the artifact exists) |
| `Green phase authorized: yes` | After operator says APPROVED at gate 2 |
| `Implementation reviewed: yes` | After operator says APPROVED at gate 3 |

Set any marker to `yes` ONLY after the matching operator `APPROVED` reply.
Self-setting a marker without an explicit human reply is forbidden.

**Backwards-compat alias:** the old marker name `Human approved
implementation: yes` is honored as `Green phase authorized: yes` for one
minor version, with a stderr deprecation warning. Run
`scripts/migrate-tdd-markers.sh` on any in-flight plan to update.

## Commit naming

For TDD cycles, commits follow this convention (CI verifies the pairs
exist for Tier 1 paths):

- `red(<id>): <description>` — failing-test commit (exempt from the
  commit gate — it IS the red phase commit)
- `green(<id>): <description>` — implementation commit (gated; requires
  `Implementation reviewed: yes`)
- `refactor(<id>): <description>` — non-behavioral improvement (gated;
  refactors are post-green and need M4)

The `<id>` is a short slug shared across all commits in the cycle
(e.g. `auth-token-rotation`).

## Forbidden

- **Self-approving.** Never set any marker to `yes` without an explicit
  operator `APPROVED` reply at the corresponding gate. Setting markers
  on your own initiative defeats the gate's purpose. The hook's deny
  message tells you which marker is next; ASK the operator, do not
  self-approve.
- **Editing tests in green phase.** If tests need changes, the spec was
  incomplete. STOP, return to red phase. The model can return to red
  by asking the operator to set `Red phase confirmed: no` and approve
  a revised spec; it cannot edit `_test.go` files after `Red phase
  confirmed: yes` is set (the test-file policy in the config blocks
  that path by default).
- **Paraphrasing red proof.** The verbatim test output is the artifact
  that proves the test ran and failed.
- **False reds.** The `red-proof.md` must include the
  "Why this is not a false red" section — explaining why the failure is
  genuine, not a test setup error, missing dependency, typo, or unrelated
  broken code.
- **Skipping `/second-opinion diff` for Tier 1 green commits.** The
  commit gate requires a fresh adjudication artifact (mtime <60min). If
  you skip the diff review, the commit hook denies and tells you to
  re-run.

## What APPROVED means at each gate

Operators may use either the explicit gate-specific command or plain
`APPROVED` at any gate. The model infers which gate from the next-pending
marker. Use the explicit form for audit clarity in security-sensitive
cycles.

| Operator says | At which gate | Model does |
|---|---|---|
| `APPROVED SPEC` or plain `APPROVED` | Gate 1 (spec drafted) | Set M1 = yes; proceed to red phase |
| `APPROVED GREEN` or plain `APPROVED` | Gate 2 (red proof captured) | Set M3 = yes; proceed to green phase |
| `APPROVED IMPLEMENTATION` or plain `APPROVED` | Gate 3 (green proof + adjudication ready) | Set M4 = yes; allow commit |

## Bypass procedure

For an emergency hotfix where the operator vouches for the change:

1. Edit `.tdd/current-plan.md` to set the four required markers to `yes`.
2. Document the bypass reason in the commit message.
3. Open a follow-up issue to add the missing test.
4. The CI `tdd-ceremony-check` job will flag the missing red commit; the
   bypass reason should be in the PR/MR description.

The bypass is for **genuine emergencies only**. Routine cycles should go
through the three gates. Routinizing the bypass weakens the gate's
signal value.
