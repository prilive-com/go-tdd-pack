---
name: go-debug
description: Debug Go failures by reproducing the bug as a focused test, tracing root cause, fixing minimally, and verifying with race-enabled tests. Use when the user mentions a bug, panic, deadlock, race, leak, hang, crash, segfault, regression, flaky test, or any Go failure that needs reproducing — for non-Tier-1 paths only (Tier 1 bugs use go-tdd-bugfix).
license: MIT
version: 1.1.0
---

# Go Debug

For non-Tier-1 bugs. If the bug is on a Tier 1 path, switch to
`go-tdd-bugfix` — full ceremony required.

## Workflow

1. Capture the exact failure (error message, stack trace, log lines).
2. Identify reproduction command.
3. Read the failing test/log/error verbatim.
4. Trace the execution path.
5. Form one primary hypothesis.
6. Make the smallest fix.
7. Verify with targeted test.
8. Run broader verification (`go test -race ./...`).
9. Add regression test if missing.
10. Explain root cause, not only the patch.

## Forbidden

- Suppressing errors.
- Weakening tests to pass.
- Adding retries/sleeps unless root cause is timing.
- Broad refactors during debugging.
- "While I was in there, I also refactored…"

## Anti-patterns to avoid

- Fixing the symptom without understanding the root cause.
- "I added a try/catch to handle it silently" (hides the bug for next
  time).
- "I updated the test to match the new behavior" (never weaken an
  assertion to pass a test — if the test fails, the bug is real).
