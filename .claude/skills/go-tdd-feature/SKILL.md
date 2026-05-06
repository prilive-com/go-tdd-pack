---
name: go-tdd-feature
description: Use this skill for any request to implement, add, build, or create new functionality in code paths matching .tdd/tdd-config.json tier1_path_regexes. Drives spec -> APPROVED SPEC -> failing test -> APPROVED GREEN -> implementation -> APPROVED IMPLEMENTATION -> commit -> refactor, with three human approval gates.
license: MIT
version: 1.0.0
---

# Go TDD - Feature workflow

Spec-driven, red-before-green discipline for new feature work in Tier 1
paths.

## When this skill applies

**Use when the user asks to implement/add/build/create new functionality
in:**
- Any path matching `tier1_path_regexes` in `.tdd/tdd-config.json`

**Do NOT use for:**
- Doc updates, CHANGELOG, README
- `.claude/` config, hook scripts
- CI workflow YAML
- Test infrastructure
- Code outside Tier 1 (use `minimal-go-change`)

## Workflow

### Phase 1 - Spec analysis

1. Read the user's request. If a linked spec exists in `specs/`, read it.
2. Copy `.tdd/templates/feature-plan.md` to `.tdd/current-plan.md`.
3. Fill in:
   - Summary (one paragraph, why)
   - User-visible behavior (observable, no implementation)
   - Acceptance criteria (numbered, testable)
   - Non-goals (forced explicit)
   - Test plan
   - Risks
   - Implementation sketch (3-5 bullets, do NOT pre-implement)

If the request is ambiguous, list questions and STOP.

### Gate 1 - User approval of spec

Stop and ask: **"Spec drafted at `.tdd/current-plan.md`. Reply
`APPROVED SPEC` (or plain `APPROVED`) to authorize the red phase, or
`CHANGES <reason>`."**

After APPROVED, set:

```
Human approved spec: yes
```

### Phase 2 - Red

1. For each test in the test plan:
   - Write a failing test pinned to the acceptance criterion.
   - Name it `Test<Behavior>_When_<Condition>_Then_<Expectation>`.
   - Use existing patterns (table-driven, embed-nil-interface fakes,
     compile-time interface assertions).
   - Use `testify/require` for assertions.
   - Run the test. It MUST fail. Capture verbatim output.
2. Write `.tdd/red-proof.md` with date, test files, command,
   **verbatim** failure output, "What this red proves",
   **"Why this is not a false red"**, expected green signal.
3. Set marker: `Red phase confirmed: yes`.
4. Commit ONLY the test files and red-proof.md:

   ```
   git commit -m "red(<id>): add failing tests for <feature>"
   ```

### Gate 2 - Green authorization (red proof valid AND green phase authorized)

Stop and ask: **"Tests are red. Red proof at `.tdd/red-proof.md`. Reply
`APPROVED GREEN` (or plain `APPROVED`) to authorize the green phase, or
`CHANGES <reason>`. Note: APPROVED GREEN means the red proof is valid
AND I can begin writing the production implementation."**

After APPROVED, set:

```
Green phase authorized: yes
```

The edit-time hooks now permit Edit/Write on Tier 1 production paths.

### Phase 3 - Green

1. Implement the minimum code to pass the failing tests.
2. Do NOT edit tests. The phase-aware test policy will deny test edits
   after `Red phase confirmed: yes` is set. If tests need changes, the
   spec was incomplete — STOP, ask the operator to revert
   `Red phase confirmed: no` and re-approve a revised spec.
3. Run `go test -race ./<package>/...` after every meaningful edit.
4. When all tests pass, run broader sweep:
   `go test -race -count=1 ./...`.
5. Capture the verbatim passing test output to `.tdd/green-proof.md`.

### Gate 3 - Implementation review (commit gate)

1. Run `/second-opinion diff` on the staged Tier 1 production diff.
   Adjudicate findings; the skill writes
   `.tdd/second-opinion-completed.md`.
2. Stop and ask: **"Green implementation complete. Diff is staged.
   `.tdd/green-proof.md` and `.tdd/second-opinion-completed.md` are
   ready. Reply `APPROVED IMPLEMENTATION` (or plain `APPROVED`) to
   authorize the green commit, or `CHANGES <reason>`."**
3. After APPROVED, set:

   ```
   Implementation reviewed: yes
   ```

4. Commit (gate-tier1-commit.sh allows once M4 + green-proof + fresh
   adjudication are present):

   ```
   git commit -m "green(<id>): implement <feature>"
   ```

5. Set marker: `Green phase confirmed: yes` (informational; not gated).

### Phase 4 - Refactor

1. Improve code without changing behavior. Tests stay green.
2. Run `go vet ./...` and `golangci-lint run`.
3. Set marker: `Refactor phase complete: yes`.
4. Commit refactors as separate commits:
   `git commit -m "refactor(<id>): ..."`. Refactor commits are also
   gated by `gate-tier1-commit.sh` (require M4 + green-proof + fresh
   adjudication, since refactors are post-green).

### Phase 5 - Final state

1. Confirm all four markers are `yes` (M1: spec, M2: red, M3:
   green-authorized, M4: implementation-reviewed).
2. Final test sweep with race detector and integration tags.
3. Update CHANGELOG.md.
4. Report back: summary, test count added, commit hashes.

## Gate vocabulary

- **APPROVED SPEC** / `APPROVED` (gate 1) — advance to red
- **APPROVED GREEN** / `APPROVED` (gate 2) — advance to green
- **APPROVED IMPLEMENTATION** / `APPROVED` (gate 3) — allow commit
- **CHANGES <reason>** — revise, re-ask
- **STOP** — halt

Never self-approve any of the four markers.

## Failure modes to avoid

- Skipping the test phase.
- Editing tests in green phase.
- Self-approving.
- Mocking what you don't own (wrap external deps in your own interface
  first).
- Tautological assertions.
- Time-based flakiness (use `testing/synctest` Go 1.25+).

## Reference

Companion: `go-tdd-bugfix`. Templates: `.tdd/templates/`.
