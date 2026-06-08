# AI Developer Guide — Prilive Go TDD Pack v2.0

> **Audience:** Claude Code (and other AI coding assistants) working in
> a Go project where the Prilive Go TDD Pack is installed.
>
> Companion to [`CLAUDE.md`](../CLAUDE.md) and [`AGENTS.md`](../AGENTS.md)
> at the repo root. Those are the rule files; this is the explainer of
> *why* the rules exist and *how* the pieces fit together.

---

## High-level mental model

You (Claude Code) are the implementer. Codex CLI is your peer reviewer.
The pack invokes Codex automatically in the background after every
meaningful Go edit you make. Codex's findings are injected into your
next turn as system reminders — invisible to the user.

Your job is to address findings silently. Either fix the code, or push
back with a short rationale. Don't ask the user. Don't narrate. Just
incorporate the review and move on. The user sees your finished work;
the back-and-forth between you and Codex stays internal.

The whole point of the design is **silent quality improvement**. The
user should rarely know review happened. They should notice that the
code you produce has fewer bugs than it used to.

---

## Why this design exists

### 1. You are sycophantic toward your own code

Models reviewing their own output are biased toward agreement. You
catch fewer of your own mistakes than a different model would. This is
well-documented in the cross-model judge literature and is the same
reason "second-opinion" review patterns exist across IDE plugins.

Codex is a different model from a different vendor. Its blind spots
differ from yours. When you and Codex agree, the agreement is
meaningful. When you disagree, the disagreement is information.

### 2. Per-PR review is too late and too coarse

Tools that review the whole diff at PR-open time are fine for catching
big problems, but they miss the natural moment: when you just wrote
the code, before you've moved on. The pack reviews after every
meaningful edit, so the feedback loop is seconds, not days.

### 3. Per-keystroke review is too disruptive

Plugins that block edits via PreToolUse hooks make every typo a
confrontation. The user hates this. So do you.

The pack uses async PostToolUse hooks. The review runs in the
background while you keep working. Findings catch up to you on your
next turn, not in the middle of one.

---

## What changes in your workflow

### Before the pack

```
User: please add a Retry function to internal/http/client.go
You:  <writes code>
You:  Done. Here's the new function.
```

### With the pack

```
User: please add a Retry function to internal/http/client.go
You:  <writes code>
[5s pass; pack runs Codex in background]
[Codex finds: missing context propagation on retry calls]
[inject-findings.sh injects: "[major/correctness c=4] Retry doesn't honor ctx.Done()
 ... Suggested fix: select on ctx.Done() in the backoff sleep."]
You:  <reads finding silently, agrees, fixes the code>
[Stop hook captures your response; runner re-fires Codex for round 2]
[Codex round 2: VERDICT: APPROVE]
You:  Done. Here's the new function.
```

The user sees the second flow but not the Codex parts. From their
perspective, you just write better code now.

---

## How to read a findings injection

When `additionalContext` contains a Codex review block:

```
[Codex review — cycle <id>, round 1, status: changes requested]

Summary: Retry function does not propagate context cancellation correctly.

Findings:
- [major/correctness c=4] Retry doesn't honor ctx.Done()
  When the caller cancels the context, the retry loop continues until
  max_attempts. Should select on ctx.Done() in the backoff sleep.
  at internal/http/client.go:42

- [minor/test_quality c=3] Test for Retry doesn't cover ctx cancellation
  Add a test where the context is cancelled mid-retry.
  at internal/http/client_test.go:88

What to do next:
- If you agree with a finding, fix the code silently. The runner will re-review.
- If you disagree, write a one-line rationale in a code comment or in your response.
- Do NOT ask the user about review issues. Continue working.
```

Each finding has:
- **severity** — `blocker` / `major` / `minor` / `nit`
- **category** — `correctness` / `test_quality` / `design` / `security` /
  `maintainability` / `docs` / `other`
- **confidence (`c=N`)** — 1=guess, 5=verified

**Triage by both severity AND confidence.** A `blocker c=1` is a red
flag (Codex is uncertain). A `nit c=5` is a paper cut Codex actually
verified. Fix high-confidence findings first; push back on
low-confidence high-severity ones with evidence.

Decide per finding:

- **Agree** → fix the code in your next turn.
- **Disagree** → write a one-line rationale either as a code comment
  near the disputed code, or in your response prose. Codex sees both
  on the next round.
- **Partial** → fix some, push back on others. State which is which.

**Do not summarize findings for the user.** Don't say "Codex says...".
Just incorporate the feedback as if it were your own thinking.

---

## When you should push back on Codex

Codex is not always right. Reasons you might legitimately disagree:

1. **Codex misread project context.** If a comment, README, or doc
   says "we intentionally do X because Y" and Codex flags it, push
   back citing the source.
2. **The fix is worse than the bug.** Codex sometimes suggests
   defensive code (nil checks, error wrapping) where surrounding code
   has stronger invariants.
3. **Codex is wrong on Go idioms.** Cite the language spec or stdlib
   pattern.
4. **Confidence is low.** `c=1` or `c=2` means Codex itself is
   uncertain. Weigh against your own knowledge.

A good pushback is a code comment:

```go
// Note: not propagating ctx here is intentional. This is called from a
// signal handler where ctx is already cancelled; we want the cleanup to
// complete regardless. See cmd/shutdown.go for the calling pattern.
```

Codex reads code comments. A well-placed comment converts a finding
from "open" to "resolved with rationale" on the next round.

A bad pushback is just denial — Codex will hold the finding.

---

## When to escalate

You shouldn't actively escalate; the pack does it. Escalation triggers
automatically:

- After `max_rounds` (default 5) without convergence
- When Codex returns `failed` on a tool error
- When you explicitly tell the runner to abandon (via the user)

When the runner emits `status=escalated`, `inject-findings.sh` calls
`runner/escalate.sh` to render an A/B/V message:

```
[REVIEW ESCALATION — cycle <id>]

Claude and Codex did not converge after 5 rounds.
The disagreement is about: <one-sentence summary>

Claude's final view:
<your view, one paragraph>

Codex's final view:
<Codex's view, one paragraph>

Choose how to proceed:
  [A] ship Claude's version — tell me 'go with Claude'
  [B] apply Codex's recommendations — tell me 'go with Codex'
  [V] view full transcripts
```

**Your job: forward this verbatim.** Don't add commentary. Don't
suggest A or B. The message is calibrated to be neutral.

When the user replies:

- **A:** Keep your code as-is. Update `.tdd/reviews/state.json` to
  `abandoned` if you want to clear the cycle.
- **B:** Read `.tdd/reviews/<cycle>/round-<max>.json` and apply
  Codex's recommendations.
- **V:** Show the user the full cycle directory contents
  (`round-1.json`, `round-2.txt`, etc.).

---

## Tool grounding — what Codex sees

Before Codex reviews, the pack runs:

- `gofmt -l ./...` (per affected module)
- `go vet ./...`
- `staticcheck ./...`
- `golangci-lint run`
- `govulncheck ./...`

Output is included **verbatim in Codex's prompt**.

This means:

1. If `go vet` flagged something at the same line as a Codex finding,
   the finding is tool-corroborated. Don't push back on tool-cited
   findings without strong evidence.
2. If a tool is missing (`### staticcheck — NOT INSTALLED`), Codex
   knows its evidence is incomplete and softens accordingly.
3. In a monorepo, tool grounding runs per affected module — Codex sees
   one section per `## Module: <path>` instead of a global blob.

Tool grounding is the single highest-leverage quality improvement. A
finding backed by `staticcheck` + Codex's own analysis is much stronger
than a finding from Codex alone.

---

## What happens between rounds

- **Round 1:** Codex sees the diff, changed-files list, tool grounding
  output, system prompt, round-1 user template. Returns strict JSON via
  `--output-schema`.
- **You:** Read findings, address them in your next turn.
- **Stop hook:** captures your full assistant response (reasoning chain,
  not just last message) into `claude-response-<next>.txt`.
- **Round 2+:** runner detects state.json says `request_changes` and the
  response file exists → fires `codex-round-n.sh`, which uses
  `codex exec resume <session-id>` so Codex remembers its prior
  analysis. Returns free-form text ending with `VERDICT: APPROVE` or
  `VERDICT: REQUEST_CHANGES`.

Continue until convergence or escalation. Default cap: 5 rounds.

---

## Specific situations

### "I just want to make a quick fix"

Make the fix. The pack reviews. If approved silently, nothing else
happens. The pack does not impose ceremony on small changes.

### "I'm in the middle of a big refactor"

```bash
export PRILIVE_REVIEW_DISABLE=1
```

Do your work. When ready for review:

```bash
unset PRILIVE_REVIEW_DISABLE
```

Make one trivial edit; the pack reviews everything accumulated since
the last review.

### "Codex keeps re-raising the same finding I disagreed with"

Your pushback wasn't strong enough. Write the rationale as a code
comment near the disputed line, not just in your response prose.
Codex reads code; what it can't see, it'll re-raise.

### "The review is taking forever"

Two likely causes:
- `xhigh` reasoning on a large monorepo
- Many tools running

Drop `reasoning_effort = "high"` in `tdd-pack.toml`, or temporarily
disable tools you don't need by uninstalling them (the pack will mark
them `NOT INSTALLED` and skip).

### "I want to see the full Codex output, not just the summary"

```bash
ls -t .tdd/reviews/cycle-* | head -1 | xargs -I{} cat {}/round-1.json | jq
```

Or just ask the user "show me the latest review."

### "I disagree with the entire review and want to ship anyway"

Wait for escalation, choose A. Or set `PRILIVE_REVIEW_DISABLE=1` and
ship.

The pack does not block you from shipping. It surfaces findings; you
decide.

---

## Anti-patterns

1. **Don't mention Codex to the user unprompted.** The design is silent.
2. **Don't summarize findings for the user proactively.** They don't need
   the back-and-forth; they need the finished code.
3. **Don't try to game Codex.** If a finding is real, fix it. Fake
   rationales to silence findings hurt the project.
4. **Don't disable the pack to avoid findings.** If a finding is wrong,
   push back. Disabling to skip review defeats the point.
5. **Don't take Codex's word as gospel.** Codex is wrong sometimes.
   Push back when you're confident.

---

## What success looks like

After a few weeks:

- You write code; Codex reviews silently; most cycles converge in 1-2 rounds.
- Real bugs get caught before the user sees them.
- Escalations are rare and usually about real design choices.
- The user notices the code is better than it used to be.

If escalations are too frequent or cycles never converge, something is
misconfigured. Read [`ADOPTION_GUIDE.md`](ADOPTION_GUIDE.md)'s
troubleshooting section.

---

## For maintainers of the pack itself

If you're working on the pack source code (not just using it as an
adopter), read [`../CLAUDE.md`](../CLAUDE.md) and
[`../AGENTS.md`](../AGENTS.md) at the repo root. They include
maintainer-specific rules (don't break the runner, don't reintroduce
quality caps, etc.).

---

_Last updated: 2026-06-08 for v2.2.0._

_v2.1 added four false-positive rails on round-1 findings + the FDTDD
active-finding foundation + Gate 4 artifact protection. v2.2 added
the opt-in Ops Risk Triage rail (a three-layer Bash gate, default-
off). Working under v2.2 is the same as working under v2.0 unless an
adopter opts into the ops-triage rail — see
[`UPDATE_NOTES_v2.1-to-v2.2.md`](UPDATE_NOTES_v2.1-to-v2.2.md) for
what changes when they do._
