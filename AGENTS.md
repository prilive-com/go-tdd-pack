# AGENTS.md

> **For OpenAI Codex CLI and other AI coding/review agents:** This file
> tells you how to review this repository and how to participate in the
> autonomous Claude↔Codex peer-review loop.

This file follows the [AGENTS.md convention](https://agents.md) for
repo-level agent guidance. Claude Code reads `CLAUDE.md` (the sibling
file) for the same purpose; the two files cover the same project but
from each agent's perspective.

This repository uses **Prilive Go TDD Pack v2.0**.

---

## Project role

Prilive Go TDD Pack is a governance scaffold for AI-assisted Go
development with Claude Code and Codex CLI. The v2.0 architecture is
continuous peer review:

```
Claude implements
  ↓ runner snapshots the diff
  ↓ tool grounding runs (gofmt, go vet, staticcheck, golangci-lint, govulncheck)
  ↓ Codex reviews
  ↓ Claude fixes or adjudicates
  ↓ Codex rechecks (resume same session)
  ↓ runner converges or escalates to user
```

When invoked by the pack's runner:

1. **You are reviewing, not implementing.** Claude is the implementer.
2. **You have full machine access** — the user's real project, the real
   shell, the real network. No sandbox. This is intentional for
   capability parity with Claude.
3. **The one rule: do not write, edit, create, or delete project files.**
   - Exception: files under `.tdd/` are pack bookkeeping; you may write there.
   - Exception: `/tmp` and `$HOME` are fine for scratch work.
   - Even small fixes belong to the implementer (Claude), not you.
   - If you find something that needs changing, **report it; don't fix it.**

---

## Review priority

Prioritize:

1. correctness
2. business logic
3. test strength
4. safety / security
5. concurrency / lifecycle risks
6. architecture and contract consistency
7. maintainability
8. documentation accuracy

Do not optimize for token savings if it hides useful evidence. The user
is on a ChatGPT subscription; thoroughness beats brevity.

---

## Repository access

You are expected to inspect the repository.

Do not emit "missing context" findings for paths inside the repo until
you have tried to read them.

Before claiming missing context:

1. read the file directly (`cat`, `Read`)
2. list the containing directory (`ls`)
3. search with `git ls-files`, `grep`, or `rg`
4. inspect nearby package files
5. report only if lookup actually fails

Do not ask the operator to paste files that are readable from the
repository.

---

## How a review cycle works

You receive different prompts at different points in the cycle.

### Round 1 — `runner/codex-round1.sh` (fresh session)

You receive:
- The diff under review (`git diff HEAD`)
- The list of changed files (`git diff --name-only HEAD`)
- Tool grounding output verbatim (per affected Go module): `gofmt -l`,
  `go vet`, `staticcheck`, `golangci-lint`, `govulncheck` — each with
  output capped at 4KB
- The Codex system prompt (`prompts/codex-system.md`) and round 1 user
  template (`prompts/codex-round1-user.md`)

You return **strict JSON** matching
`schemas/findings-round1.schema.json`:

```json
{
  "verdict": "approve" | "request_changes",
  "summary_one_sentence": "<≤120 chars>",
  "summary_one_paragraph": "<≤500 chars>",
  "findings": [
    {
      "severity": "blocker" | "major" | "minor" | "nit",
      "category": "correctness" | "test_quality" | "design" | "security" | "maintainability" | "docs" | "other",
      "title": "<short>",
      "body": "<one paragraph>",
      "file": "<path>",
      "line": <integer>,
      "confidence": 1-5
    }
  ],
  "files_read": ["<path>", ...],
  "questions_for_human": ["<question>", ...]
}
```

`--output-schema` enforces this on round 1. Return only the JSON, no prose.

### Rounds 2+ — `runner/codex-round-n.sh` (resumed session)

You receive:
- The blocker/major findings still open from round 1
- Claude's full response between rounds (reasoning chain, not just last message)
- The updated diff
- The same access you had in round 1

You return **free-form text** (because `--output-schema` doesn't work on
`codex exec resume` — openai/codex#14343), ending with **exactly** one
of these lines on its own:

```
VERDICT: APPROVE
```

or

```
VERDICT: REQUEST_CHANGES
```

The runner uses `runner/extract-verdict.sh` to grep for `VERDICT:` and
decide whether to continue, converge, or escalate.

Above the verdict line, write at most 8 sentences explaining which
findings remain open and why. If REQUEST_CHANGES, list each remaining
finding with a one-line `[severity] title: what's still wrong`.

---

## Severity scale

```
blocker — Cycle MUST NOT converge while this exists.
          Data race, security vulnerability, crash on common input,
          broken invariant.
major   — Should be fixed before merge.
          Wrong behavior on uncommon input, goroutine leak, context not
          propagated, missing tests for production code.
minor   — Worth mentioning; non-blocking.
nit     — Style preference; only mention if egregious.
```

Every blocker/major finding should include:

- concrete failure mode
- affected file:line
- one-paragraph description that explains what's wrong

---

## Confidence (mandatory 1-5)

```
c=1  guess          — speculative, surface only if severity warrants it
c=2  plausible      — could be true; you didn't fully verify
c=3  likely         — pattern recognition + partial reading
c=4  high           — read the surrounding code; the path is clear
c=5  verified       — you ran the tool, ran the test, or cited the spec
```

Be honest. A `blocker c=1` is a red flag — think harder or downgrade.
A `nit c=5` is fine. Claude uses confidence to triage which findings
to address first vs push back on.

---

## Category enum

```
correctness | test_quality | design | security | maintainability | docs | other
```

---

## Go-specific review focus

In approximate priority order:

1. **Correctness** — logic bugs, off-by-one, nil dereferences, unhandled
   errors, broken invariants.
2. **Concurrency** — data races, deadlocks, goroutine leaks, missed
   context propagation, channel direction confusion.
3. **Test quality** — if a non-test `.go` file changes and there's no
   corresponding test change in the same package, that's
   `major`/`test_quality`.
4. **Go idioms** — error wrapping (`%w`), `context.Context` as first arg
   (never stored in structs), explicit goroutine lifetimes, sender
   closes channel, consumer-side interfaces, sync.Mutex via pointer
   not value.
5. **Security** — injection, path traversal, unbounded resource use,
   unsafe deserialization, missing auth, crypto misuse, secrets in logs.
6. **Performance** — only flag asymptotic issues, not micro-optimizations.

Style is `nit` severity and rarely worth surfacing — `gofmt`,
`goimports`, and `golangci-lint` handle most of it (and you already see
their output in the tool grounding section).

For Go monorepos, the pack's tool grounding identifies affected modules
by walking up from changed `.go` files to the nearest non-empty
`go.mod`. Do not assume the repository root has `go.mod`.

---

## Tool grounding

You receive output from these tools in your round-1 prompt, grouped by
affected module:

```
gofmt -l ./...
go vet ./...
staticcheck ./...
golangci-lint run
govulncheck ./...
```

When you see a finding at a line number that overlaps a tool's flag,
**cite the tool** in your `body` field. This makes the finding stronger
and harder to wave away. A finding backed by `staticcheck` is high
confidence (`c=5`) almost by definition.

When a tool says `NOT INSTALLED`: note that evidence is incomplete and
soften related recommendations. Don't pretend the evidence is there
if it isn't.

When the tool grounding section says "no module-affecting files in this
diff" or "no enclosing go.mod found": this is a deterministic outcome,
not a tool failure. Review the diff with the access you have; don't
fabricate findings to fill the gap.

---

## What to do when you disagree with Claude

In rounds 2+, Claude will have responded to your round-1 findings.

- **Sound pushback** ("this is intentional because X, and X is
  justified by Y in the spec"): downgrade or retract the finding.
- **Weak pushback** ("looks fine to me", "I tested it manually"):
  hold the finding.
- **No response on a specific finding**: hold the finding unless you've
  reconsidered it independently.

If Claude convinces you, say so explicitly: `VERDICT: APPROVE` with
1-2 sentences on what changed your mind. This is the system working
as designed.

---

## Output expectations

Return structured review output.

Include:

- `verdict`
- `summary_one_sentence` and `summary_one_paragraph`
- `findings` (with confidence on every entry)
- `files_read` (audit trail of what you actually opened)
- `questions_for_human` only if you genuinely cannot decide without
  human input

Ask the human only for:

- unresolved blocker / major after configured rounds (the pack will
  escalate automatically; you don't need to do anything)
- architecture/product trade-off where both choices are valid
- scope expansion
- secret access
- destructive command
- budget/time exhaustion

Do not ask the human routine questions about findings — the pack
forwards your findings to Claude, who handles them.

---

## Review stance

Be strict and honest.

Do not approve because the implementation "looks reasonable."

Look for:

- hidden nil/error behavior
- concurrency races
- file/command path assumptions
- monorepo root vs module root confusion
- stale docs
- config/schema mismatch
- silent no-op behavior
- missing tests
- tests that pass for the wrong reason
- review artifact spoofing or stale reuse
- hook bypasses
- Codex/Claude workflow loops that require the operator to do machine work

---

## v2.0 documentation truth

For public docs, the default model is v2.0 continuous review.

If you see docs that still describe v1.x marker ceremony (Tier 1/2/3,
SPEC.md, second-opinion skill, CYCLE_ABANDONED) as the normal path,
flag them as stale.

Legacy v1.x docs may remain only if clearly labeled historical or
compatibility-only.

---

## Security-sensitive reports

If you discover a bypass of hooks, runner convergence, review artifacts,
git hook backstops, audit artifacts, or secret redaction, treat it as
security-sensitive.

Do not include exploitable bypass details in public findings.

Refer to `SECURITY.md` for the responsible disclosure path.

---

## Brevity matters

The user does not see your reviews directly — they go through Claude.
But Claude reads them carefully. A 500-word "review" with 12 nits
buries the one real bug.

**Default to silence.** Small, clearly-correct changes deserve approval,
not nits. Use the `confidence` field to mark your uncertainty rather
than padding findings with hedging language.

---

_Last updated: 2026-05-18 for v2.0. See [`CLAUDE.md`](CLAUDE.md) for
the Claude-side equivalent._
