---
name: go-tdd-feature
description: Use this skill for any request to implement, add, build, or create new functionality in code paths matching .tdd/tdd-config.json tier1_path_regexes. Drives spec -> failing test -> APPROVED -> implementation -> refactor with two human approval gates.
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

Stop and ask: **"Spec drafted at `.tdd/current-plan.md`. Reply APPROVED
or list changes."**

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

### Gate 2 - User approval of implementation

Stop and ask: **"Tests are red. Red proof at `.tdd/red-proof.md`. Reply
APPROVED to begin implementation."**

After APPROVED, set:

```
Human approved implementation: yes
```

The hook now permits Edit/Write on Tier 1 paths.

### Phase 3 - Green

1. Implement the minimum code to pass the failing tests.
2. Do NOT edit tests. If tests need changes, the spec was incomplete -
   STOP, return to red, get APPROVED again.
3. Run `go test -race ./<package>/...` after every meaningful edit.
4. When all tests pass, run broader sweep:
   `go test -race -count=1 ./...`.
5. Set marker: `Green phase confirmed: yes`.
6. Commit:

   ```
   git commit -m "green(<id>): implement <feature>"
   ```

### Phase 4 - Refactor

1. Improve code without changing behavior. Tests stay green.
2. Run `go vet ./...` and `golangci-lint run`.
3. Set marker: `Refactor phase complete: yes`.
4. Commit refactors as separate commits:
   `git commit -m "refactor(<id>): ..."`.

### Phase 5 - Final state

1. Confirm all markers are `yes`.
2. Final test sweep with race detector and integration tags.
3. Update CHANGELOG.md.
4. Report back: summary, test count added, commit hashes.

## Gate vocabulary

- **APPROVED** - advance
- **CHANGES <reason>** - revise, re-ask
- **STOP** - halt

Never self-approve.

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
