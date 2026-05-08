# CLAUDE.md — Go Project Operating Rules

You are working in a Go repository. Read carefully — these are standing
rules.

## Prime directive

Prefer the smallest correct change.

Before editing code:

1. Understand the existing code path.
2. Identify the business invariant.
3. Write or identify tests that prove the behavior.
4. Prefer modifying existing code over creating new abstractions.
5. Do not add dependencies, exported APIs, goroutines, config fields,
   background workers, or new packages unless required by the task.

## Two workflow modes

**Mode A — High-stakes paths (TDD ceremony required).**
Files matching regexes in `.tdd/tdd-config.json` `tier1_path_regexes`
require the `go-tdd-bugfix` or `go-tdd-feature` skill. The
`require-tdd-state.sh` PreToolUse hook will block production-code edits
without an approved plan.
Workflow: spec → APPROVED → red proof → APPROVED → green → cleanup.

**Mode B — All other code.**
Use the `minimal-go-change` skill. No TDD ceremony, but the standard
discipline still applies (red-before-green where tractable; race
detector green; etc.).

If unsure which mode applies, check `.tdd/tdd-config.json` first.

## Standard workflow

For non-trivial changes:

1. Explore first.
2. Plan.
3. Write/update tests.
4. Implement the smallest safe change.
5. Run verification.
6. Review the diff for unnecessary code (use the `negative-diff` skill).
7. Summarize risks and commands run.

Do not claim tests passed unless you ran them or the user provided
output.

## Go quality rules (always)

See `.claude/rules/go-style.md` for the full list. Highlights:

- Idiomatic Go; small APIs; concrete types unless an interface boundary
  is needed.
- Do NOT introduce single-implementation interfaces "for testability" —
  use a fake struct in `_test.go`.
- Avoid package-level mutable state.
- `context.Context` first parameter for I/O paths; never stored in
  structs (except request-scoped).
- Never ignore errors silently.
- Never `panic` for ordinary error handling.
- Never log secrets, tokens, credentials, passwords, cookies, or PII.
- Never `float64` for money/balances/prices/quantities.
- Every goroutine has a documented termination path.
- Every opened resource is closed in all paths.
- `crypto/rand` for security randomness; in Go 1.26+ the random
  parameter to `crypto/*.GenerateKey` is ignored.

## Testing rules

See `.claude/rules/go-testing.md` for the full list. Highlights:

- Tests prove behavior, not implementation.
- Table-driven for input/output logic; >=3 rows or collapse.
- Edge cases, failure paths, cancellation/timeouts.
- Race-detector tests for concurrent code.
- For libraries: `Example_xxx` tests + consumer-perspective tests in
  `package_test`.
- Tests that only `t.Log` and assert nothing are not valid tests —
  flag them.
- Mock external boundaries (HTTP, DB, clock); never mock the function
  under test or same-package collaborators.
- Use `testing/synctest` (Go 1.25+) instead of `time.Sleep`.
- Use `t.ArtifactDir()` (Go 1.26+) for artifacts to preserve.

## AI-bloat control

See `.claude/rules/go-ai-bloat.md`. Treat every new abstraction as
suspicious until justified.

Before finishing a change, check each new symbol/file/abstraction/
dependency:

1. Required by the current task?
2. Does an existing function/type/package solve this?
3. >=2 real callers in this PR? (Rule of Three / two-callers rule)
4. Could this be a private function instead of exported API?
5. Could this be deleted with no behavior loss?

Reject single-implementation interfaces, dead exports, and dependencies
that duplicate existing ones.

## Dependencies (slopsquatting defense)

Never run `go get` or modify `go.mod` without:

1. Stating the exact module path.
2. Why no stdlib equivalent works.
3. Confirming the module prefix is on `.claude/allowed-modules.txt`.
4. If not on the allowlist: stop and ask.

Hallucinated package names are a known supply-chain attack vector
("slopsquatting") — ~20% of LLM-recommended Go packages don't exist;
attackers pre-register them as malware. Verify on https://pkg.go.dev
before adding. CI fails the merge if a dependency isn't on the
allowlist.

## Verification commands

Use the Makefile when available:

```bash
make fmt
make test
make race
make vet
make vuln
make lint
make ci
```

Do not claim these were run unless you ran them.

## Context discipline

See `.claude/rules/go-context-discipline.md`. Highlights:

- Use `/clear` between unrelated tasks.
- For read-heavy investigation, use a subagent — do not pollute the
  main context.
- For tasks spanning >50 messages, snapshot the plan to
  `specs/<feature>/plan.md` and start fresh.
- Performance starts to degrade well before stated context limits. When
  the session feels confused, that's the signal to clear, not to push
  harder.

## Git rules

- Do not commit unless explicitly asked.
- Do not rewrite history unless explicitly asked.
- For TDD cycles, commits follow the convention:
  - `red(<id>): <description>` — failing test commit
  - `green(<id>): <description>` — fix commit
  - `refactor(<id>): <description>` — non-behavioral improvements
- Show a concise diff summary before finalizing.
- Never include secrets in commits, logs, or generated files.
- Hooks block: `--no-verify`, `git push --force` (without
  `--force-with-lease`), `git filter-repo`, `git reset --hard origin/*`.
  Do not attempt to bypass these — they exist because of documented
  incidents.

## Gate vocabulary (for TDD ceremony)

When at a TDD gate, the operator replies with one word:

- **APPROVED** — advance phase
- **CHANGES <reason>** — revise current phase, re-ask
- **STOP** — halt workflow, leave partial state

Never interpret other replies as gate responses. Never self-approve.

## Skills available

- `specify` — Layer 0 spec gate (Specify → Plan → Tasks → Implement)
- `minimal-go-change` — routine non-Tier-1 work
- `go-tdd-feature` — Tier 1 feature work (two human gates)
- `go-tdd-bugfix` — Tier 1 bugfix work (two human gates)
- `go-debug` — non-Tier-1 debugging
- `go-test-writer` — write Go tests in team conventions
- `go-modernize` — Go 1.26 `go fix` modernize
- `go-code-review` — Staff+ review of current diff
- `go-release-check` — pre-release checklist
- `negative-diff` — post-implementation cleanup pass
- `migration-review` — DB migration safety review
- `new-module-scaffold` — scaffold a new package/binary
- `postmortem-fix` — incident → prevention plan
- `second-opinion` — optional cross-model review via OpenAI Codex CLI before non-trivial Tier 1 implementation; advisory only, requires `codex` installed + logged in

## Reviewer agents available

- `go-reviewer` — general Staff+ review
- `go-architect` — package boundaries, lifecycle, transactions
- `go-concurrency-reviewer` — races, locks, channels, goroutines
- `go-security-reviewer` — secrets, taint, supply chain, crypto
- `go-test-engineer` — test quality + TDD ceremony check
- `go-bloat-reviewer` — necessity gates, deletion candidates

## Reference

A worked Tier 1 TDD cycle (spec → red → green → refactor) is in
`examples/tdd-cycle/`. Read the four-stage README to see what
`.tdd/current-plan.md`, `.tdd/red-proof.md`, the test, and the
implementation look like at each gate.
