# Red Proof: <ID> — <title>

**Date:** <YYYY-MM-DD>
**Plan:** `.tdd/current-plan.md`

## Command run

```bash
<exact go test command>
```

## Output (verbatim)

```text
<paste exact failing output; do not paraphrase>
```

## What this red proves

Explain which assertion failed and why this failure corresponds to the bug/feature acceptance criterion.

## Why this is not a false red

Explain why the failure is not caused by test setup, missing dependency, typo, or unrelated broken code. (This section prevents fake-failures from passing as red proofs.)

## Expected green signal

What exact command/output should pass after implementation?

## Reviewer confirmation

Human approved implementation at: <date/time or pending>
