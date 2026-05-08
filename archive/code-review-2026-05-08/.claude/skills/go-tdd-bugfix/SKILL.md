---
name: go-tdd-bugfix
description: Use this skill for any request to fix a bug, debug a failure, or address a regression in code paths matching .tdd/tdd-config.json tier1_path_regexes. Reproduces the bug as a failing test BEFORE diagnosing or fixing. Two human approval gates.
license: MIT
version: 1.0.0
---

# Go TDD - Bugfix workflow

This skill enforces bug-first TDD on Tier 1 paths. Reproduce as a failing
test BEFORE root-cause analysis.

## When this skill applies

**Use when the user reports:**
- A production incident on a Tier 1 path
- A regression in a Tier 1 path
- An unexpected behavior in money/auth/state-machine/migration code

**Do NOT use for:**
- Doc typos, CHANGELOG corrections
- Test-only fixes
- Feature requests (use `go-tdd-feature`)
- Bugs in non-Tier 1 code (use `minimal-go-change`)

## Workflow

### Phase 1 - Reproduce

1. Document the EXACT reproduction steps from the user's report. Don't
   paraphrase.
2. Copy `.tdd/templates/bugfix-plan.md` to `.tdd/current-plan.md`.
3. Fill in: Reproduction, Expected, Actual, Affected code (initial guess).
4. Write a test that reproduces the bug. The test MUST fail. If it
   passes:
   - The reproduction is wrong (revise)
   - OR the bug is in a different layer
   - OR the bug is environmental
5. Capture the failure in `.tdd/red-proof.md` — **verbatim test output,
   no paraphrase, including "Why this is not a false red" section.**

### Gate 1 - User confirms reproduction

Stop and ask: **"Bug reproduced as a failing test. Red proof at
`.tdd/red-proof.md`. Is this the right reproduction? Reply
`APPROVED SPEC` (or plain `APPROVED`) to confirm, or `CHANGES <reason>`."**

After APPROVED, set:

```
Bug reproduced: yes
Human approved spec: yes
```

### Phase 2 - Root cause

1. Read related code paths. `Grep` call sites. `git log -p` and
   `git blame`.
2. Fill in "Root cause analysis":
   - Mechanism
   - Introduced in commit
   - Why not caught
3. Identify the **minimum fix** (no scope creep).
4. Identify **adjacent code paths** that could share the same root cause.

### Gate 2 - Green authorization (red proof valid AND fix may begin)

Stop and ask: **"Root cause documented. Minimum fix identified at
`.tdd/current-plan.md`. Reply `APPROVED GREEN` (or plain `APPROVED`)
to authorize the fix implementation, or `CHANGES <reason>`. Note:
APPROVED GREEN means red proof is valid AND I can begin implementing
the fix."**

After APPROVED, set:

```
Red phase confirmed: yes
Green phase authorized: yes
```

The edit-time hooks now permit Edit/Write on Tier 1 production paths.

### Phase 3 - Fix

1. Apply the minimum fix. Do NOT edit the failing test (the phase-aware
   test policy will deny test edits after `Red phase confirmed: yes`).
2. Run the failing test. Must go green.
3. Run full sweep: `go test -race -count=1 ./...`. Must be green.
4. Capture verbatim passing test output to `.tdd/green-proof.md`.
5. Add regression tests for adjacent code paths.
6. Set markers: `Fix applied: yes`, `Regression tests added: yes`.

### Gate 3 - Implementation review (commit gate)

1. Run `/second-opinion diff` on the staged Tier 1 fix diff. Adjudicate
   findings; the skill writes `.tdd/second-opinion-completed.md`.
2. Stop and ask: **"Fix complete. Diff is staged.
   `.tdd/green-proof.md` and `.tdd/second-opinion-completed.md` are
   ready. Reply `APPROVED IMPLEMENTATION` (or plain `APPROVED`) to
   authorize the green commit, or `CHANGES <reason>`."**
3. After APPROVED, set:

   ```
   Implementation reviewed: yes
   ```

4. Commit:

   ```
   git commit -m "red(<id>): tests pin <bug>"  (if not already done)
   git commit -m "green(<id>): fix <bug>"
   ```

### Phase 4 - Bug-elsewhere check

1. Scan codebase for similar patterns.
2. For each candidate, write a test. If it passes, fine. If it fails,
   file an issue or apply the same fix.
3. Set marker: `Bug-elsewhere check complete: yes`.

### Phase 5 - Final state

1. Confirm all four gate markers are `yes`.
2. Update CHANGELOG.md.
3. Report back: bug summary, root cause, fix scope, regression tests
   added.

## Gate vocabulary

- **APPROVED SPEC** / `APPROVED` (gate 1) — confirm reproduction
- **APPROVED GREEN** / `APPROVED` (gate 2) — authorize fix implementation
- **APPROVED IMPLEMENTATION** / `APPROVED` (gate 3) — allow commit
- **CHANGES <reason>** — revise, re-ask
- **STOP** — halt

Never self-approve any of the four markers.

## Failure modes to avoid

- Fixing without reproducing.
- Fixing more than the bug (scope creep).
- Skipping the bug-elsewhere check.
- Tautological assertions (`assert.NoError(err)` alone tells you
  nothing).
- Self-approving.

## Reference

Companion: `go-tdd-feature`. Plan template: `.tdd/templates/bugfix-plan.md`.
Red-proof template: `.tdd/templates/red-proof.md`.
