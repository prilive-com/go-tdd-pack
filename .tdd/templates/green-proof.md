# Green Proof: <ID> — <title>

**Date:** <YYYY-MM-DD>
**Plan:** `.tdd/current-plan.md`
**Red proof:** `.tdd/red-proof.md` (the matching red proof this green satisfies)

## Command run

```bash
<exact go test command — should be the same one used for red proof,
 ideally with -race -count=1 to catch flakes>
```

## Output (verbatim)

```text
<paste exact passing output; do not paraphrase>
<must show PASS for the tests that were RED>
<must show ok / no-fail summary for the affected packages>
```

## What this green proves

For each acceptance criterion the red proof pinned, point at the now-passing test that demonstrates it works. Cite the test name and what assertion now passes.

## Why this is not a fake green

This section prevents skipped tests, weakened assertions, and other fake-greens from passing the commit gate. Address each:

- **No tests were modified** post-red. The same tests that were RED are now PASS, with the same assertions. (If a test WAS modified, you returned to red phase per the documented workflow.)
- **No tests were skipped** (`t.Skip`, `t.SkipNow`, build tags excluding the test). The output shows them ran.
- **No `-short` flag** was used to skip slow tests.
- **Race detector is green** (the `-race` flag was used, output shows no DATA RACE).
- **Count is 1** (the `-count=1` flag was used to bypass test cache, output is from a fresh run).

## Coverage delta (optional)

If you ran `go test -cover` or have coverage data, paste relevant numbers. Not required by the gate; useful for the operator review.

## Reviewer confirmation

Human approved implementation (gate 3) at: <date/time or pending>

Once `Implementation reviewed: yes` is set in `.tdd/current-plan.md`, the
`gate-tier1-commit.sh` hook permits the green commit.
