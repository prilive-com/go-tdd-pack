# AI-Bloat Prevention Rules

Treat every new abstraction as suspicious until justified.

## Necessity gates

Before accepting any new exported symbol, file, type, interface, helper,
config field, dependency, goroutine, or test helper, ask:

1. Required by the current task?
2. Does existing code already solve this?
3. Is it a parallel implementation?
4. Two real callers in this PR? (Rule of Three / two-callers rule)
5. Could it be private instead of exported?
6. Could it be table-driven data instead of new control flow?
7. Could it be deleted with no behavior loss?
8. Does the test prove behavior, or only mirror implementation?

## Default actions

- Delete unnecessary code.
- Inline single-use helpers.
- Reuse existing functions.
- Avoid new dependencies.
- Avoid new public API.

## Severity (use during review)

- Hallucinated package import → **Important** (slopsquatting)
- Tautological test masking real bug path → **Important**
- Speculative abstraction with no second caller → **Should-fix**
  (request removal)
- Dead export → **Should-fix** for SERVICE/CLI; **Important** for LIBRARY
  (one-way door)
- Vestigial TODO / over-commented obvious code → **Nit**

## Anti-patterns

- "While I was in there, I also refactored…"
- "This revealed a broader architectural issue, so I rewrote the module…"
- New file containing a single 5-line helper that has one caller.
- Single-implementation interface "for testability" — use a fake struct
  in `_test.go` instead.
- New dependency that duplicates 30 lines of stdlib code.
- Test helper that hides assertion logic from the test, making failures
  hard to read.
- Pre-emptive `Options` struct for a function with two parameters.
- Adding a dependency on a package whose name "sounds right" without
  verifying on pkg.go.dev (slopsquatting).

## Cleanup pass

After implementation is complete and tests pass, run the `negative-diff`
skill — its job is to find code added in this PR that should be deleted,
inlined, or replaced with reuse. The cleanup pass is non-negotiable for
PRs over 200 lines.
