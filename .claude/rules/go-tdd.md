# TDD Discipline Rules

## When TDD ceremony applies

The full ceremony (spec → APPROVED → red → APPROVED → green) is
**required** for any path matched by `tier1_path_regexes` in
`.tdd/tdd-config.json`. The `require-tdd-state.sh` PreToolUse hook
enforces this.

For code outside Tier 1, lighter discipline applies:
- Red-before-green for fixes that have a tractable test surface.
- Race-detector green before any commit touching goroutine code.
- Integration tests for cross-module workflows.

## The two gates

**Gate 1 — Spec.** After the model writes `.tdd/current-plan.md`. The
operator says `APPROVED`, `CHANGES <reason>`, or `STOP`.

**Gate 2 — Red proof.** After failing tests are committed and verbatim
output is in `.tdd/red-proof.md`. The operator says `APPROVED`,
`CHANGES`, or `STOP`.

## Plan markers

The hook checks markers in `.tdd/tdd-config.json` `required_markers`:

- `Human approved spec: yes`
- `Red phase confirmed: yes`
- `Human approved implementation: yes`

Set markers to `yes` ONLY after an explicit operator `APPROVED` reply.

## Commit naming

For TDD cycles, commits follow this convention (CI verifies the pairs
exist for Tier 1 paths):

- `red(<id>): <description>` — failing-test commit
- `green(<id>): <description>` — implementation commit
- `refactor(<id>): <description>` — non-behavioral improvement

The `<id>` is a short slug shared across all commits in the cycle
(e.g. `auth-token-rotation`).

## Forbidden

- **Self-approving.** Never set "Human approved implementation: yes"
  without an explicit user `APPROVED` reply.
- **Editing tests in green phase.** If tests need changes, the spec was
  incomplete. STOP, return to red.
- **Paraphrasing red proof.** The verbatim test output is the artifact
  that proves the test ran and failed.
- **False reds.** The `red-proof.md` must include the
  "Why this is not a false red" section — explaining why the failure is
  genuine, not a test setup error, missing dependency, typo, or unrelated
  broken code.

## Bypass procedure

For an emergency hotfix where the operator vouches for the change:

1. Edit `.tdd/current-plan.md` to set the three required markers to `yes`.
2. Document the bypass reason in the commit message.
3. Open a follow-up issue to add the missing test.
4. The CI `tdd-ceremony-check` job will flag the missing red commit; the
   bypass reason should be in the PR/MR description.
