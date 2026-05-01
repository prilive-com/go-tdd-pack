# Example TDD cycle on a Tier 1 path

A minimal worked example of a full Tier 1 cycle on a fake
`internal/payments/cents.go` path. Read these four directories in
order to see what `.tdd/current-plan.md`, `.tdd/red-proof.md`, and the
test/code files look like at each phase.

This is **illustrative**, not runnable. Each `.go` file in the
example carries a `//go:build ignore` build tag so `go build ./...`
and `go test ./...` skip them. The files are snapshot artifacts
captured at each gate, not a real Go package. A real cycle produces
equivalent files (but a single set evolving in place, not four
separate copies).

When you copy the *pattern* into a real project, drop the
`//go:build ignore` line from your real Go files.

## What the example shows

The toy task: implement a `Cents` money type and an `Add` method.
Money paths are Tier 1 by default (per `.tdd/tdd-config.json`), so
the full ceremony applies — two human approval gates and a
verbatim red-proof artifact.

| Stage | Directory | What's in it |
|---|---|---|
| 1. Spec | `01-spec/` | Plan file freshly created from `.tdd/templates/feature-plan.md` and filled in. Status: `active`. No markers set yet. **Operator must reply `APPROVED` before proceeding.** |
| 2. Red | `02-red/` | Spec was APPROVED (`Human approved spec: yes`). Failing test written. `red-proof.md` captures verbatim test output and the "Why this is not a false red" justification. **Operator must reply `APPROVED` again before any production-code edit.** |
| 3. Green | `03-green/` | Implementation gate APPROVED. Minimum production code written. Tests pass. All 3 markers now `yes`. |
| 4. Refactor | `04-refactor/` | Behavior unchanged; code clarity improved. New commit `refactor(<id>): ...`. Final marker set. Cycle complete. |

## What to copy into your own cycle

Don't copy the example files into a real project. Do copy the
**rhythm**:

1. Read the user's request. If a spec exists in `specs/`, read it.
2. `cp .tdd/templates/feature-plan.md .tdd/current-plan.md` (or
   `bugfix-plan.md` for bug fixes).
3. Fill in the spec. Stop. Ask for `APPROVED`.
4. Write a failing test. Run it. Capture verbatim output to
   `.tdd/red-proof.md`. Fill in "Why this is not a false red".
   Commit `red(<id>): ...`.
5. Stop. Ask for `APPROVED`.
6. Write the minimum code to pass the test. Commit `green(<id>): ...`.
7. Refactor (no behavior change). Commit `refactor(<id>): ...`.

The hooks in `.claude/hooks/` enforce that production-code edits to
Tier 1 paths cannot proceed until the three required markers are
`yes`. The CI step `tdd-ceremony-check` enforces that every
`green(<id>):` commit on a Tier 1 path has a preceding `red(<id>):`
commit on the same branch.

## What this example deliberately does NOT show

- The full `negative-diff` cleanup pass (not always needed for a
  3-line implementation).
- Multi-file edits (the example is one file + one test file).
- The `bug-elsewhere` check from `go-tdd-bugfix` (this is a feature
  cycle, not a bugfix cycle).
- Failing red-proof recovery (when the red doesn't fail for the right
  reason and you have to `STOP` and revise).

For those flows, see `.claude/skills/go-tdd-feature/SKILL.md` and
`.claude/skills/go-tdd-bugfix/SKILL.md`.

## Maintenance note

This example is a snapshot. If you change the templates in
`.tdd/templates/`, the example WILL drift. Don't sync them
automatically — the example illustrates the v1.2.0 shape; future
template changes can update the example deliberately at major
revisions.
