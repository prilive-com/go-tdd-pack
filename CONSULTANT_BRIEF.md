# Consultant Brief — go-claude-starter

**Date:** 2026-05-11
**Current release:** v1.8.0 (commit `2ab3d7b`)
**Repo:** go-projects-claude-starter
**Contact:** prilive.company@gmail.com

This document is the single entry point for a new consultant joining
the project. Read this top-to-bottom; it tells you what the project
is, why it exists, how we develop it, how it works, and where we
are now. Pointers at the end direct you into the codebase for
specific deep-dives.

---

## 1. What this project is

`go-claude-starter` is a **Go-language project starter pack for
teams using AI coding assistants** (Claude Code, Codex). It is NOT
a Go application or library. It is a **scaffold-style repo**:
developers clone it, customize a config file, and get a Go project
pre-wired with:

- **Safety hooks** that gate dangerous bash, secret leaks, and
  policy violations BEFORE they reach disk.
- **A four-marker TDD ceremony** with three explicit operator
  approval gates on high-stakes paths.
- **`/second-opinion` cross-model review** — invokes Codex CLI as an
  independent reviewer for Tier 1 cycles.
- **Skills** (`go-tdd-feature`, `go-tdd-bugfix`, `migration-review`,
  `negative-diff`, …) that drive the AI through proven workflows.
- **Reviewer subagents** (architecture, security, concurrency,
  test-quality, bloat) for focused critique.
- **A Go AST helper** (v1.8.0) that validates test-file edits at
  the parse-tree level — closes the "AI weakens a test to make it
  pass" failure mode.
- **A sha-chained audit log** of every typed exception grant,
  approval, and use within a cycle.

The deliverable for users of the pack: a `.claude/`, `.tdd/`,
`scripts/`, `docs/` directory tree that drops into their Go project
and runs autonomously inside Claude Code.

---

## 2. Why we develop it

### The problem

AI coding assistants (Claude, Codex, similar) are now capable of
shipping Go code end-to-end. But they have failure modes that
human-only workflows don't have:

1. **Test-weakening.** When tests fail, the AI may "fix" the tests
   instead of the production code — silently changing `require.Equal`
   to `require.NotEqual`, or deleting an assertion, or adding an
   empty `t.Run` placeholder. The visible diff is "now passing";
   the actual regression is invisible until production.
2. **Silent context drift.** AI agents take instructions from
   `CLAUDE.md`, project rules, and current conversation. A subtle
   rule change can change behavior across an entire codebase
   without anyone noticing.
3. **Confidence ≠ correctness.** AI proposes plausible-looking code
   for unfamiliar domains. A reviewer who is itself an AI is
   vulnerable to confirmation bias (anchoring on what the
   implementer proposed).
4. **Bypassing humans.** AI can `git commit --no-verify`, force-push,
   `rm -rf` production data, exfiltrate secrets via curl — all with
   plausible-sounding justifications. Without mechanical guardrails,
   the user trusts the explanation.

### Our approach

Make the human-in-the-loop **mechanically required, not advisory**:

- **Hooks fail closed.** Every dangerous action emits a deny on
  stderr with a `<claude-directive>` block telling the AI exactly
  how to recover. AI can't proceed silently.
- **Four-marker TDD ceremony for high-stakes paths.** Production
  edits to auth / money / migrations require operator approval at
  three explicit gates: spec, red proof, implementation review.
- **`/second-opinion` cross-model review.** Different AI families
  have different blind spots. Codex (OpenAI) reviews Claude's
  (Anthropic) work; findings get adjudicated round by round.
- **Audit trail with cryptographic chaining.** Every grant of an
  exception is recorded with a sha256-chained line; tampering is
  detectable.
- **Conservative-by-design validators.** False positives are
  preferred over false negatives — better that the operator clears
  a legitimate edit than that an illegitimate one slips through.

The goal isn't to slow AI down. It's to add friction at the points
where a silent regression would cause real damage (lost money,
exposed credentials, broken migrations). On non-Tier-1 paths,
there's no ceremony.

### Target users

- **Go developers using Claude Code** who want governance built-in
  rather than bolted on.
- **Teams whose Go services have high-stakes paths** (fintech,
  health, infra). Without TDD ceremony there, the AI's failure
  modes are unbounded.
- **Engineering leads** who want to delegate routine work to AI
  but keep the audit trail and the human approval gates legible.

---

## 3. How we develop it

The starter itself is developed using its own discipline — we
practice what we ship. This is meta: changes to the pack go through
the same TDD ceremony the pack imposes on its users.

### The four-marker TDD cycle (M1 → M4)

For every Tier 1 change to the pack (touches
`.claude/hooks/require-tdd-state.sh`, `tdd-config.json`, or other
governance-critical files):

| Marker | State | Operator action |
|---|---|---|
| **M1** | `Human approved spec: yes` | After reading the plan; reply `APPROVED SPEC` |
| **M2** | `Red phase confirmed: yes` | After AI writes failing tests + captures verbatim red proof |
| **M3** | `Green phase authorized: yes` | After reading red proof; reply `APPROVED RED, go ahead with green` |
| **M4** | `Implementation reviewed: yes` | After reading the diff + `/second-opinion` adjudication; reply `APPROVED IMPLEMENTATION` |

Each gate is enforced by a hook (`require-tdd-state.sh` at edit
time, `gate-tier1-commit.sh` at commit time).

### The `/second-opinion` review loop

After green-phase implementation, we run `/second-opinion diff` —
invokes Codex CLI as a read-only external reviewer. Codex returns
JSON findings (severity P0/P1/P2/P3). For each finding:

1. We **write a RED test** that reproduces the bypass empirically.
2. We **fix the bug** so the RED transitions to GREEN.
3. We **adjudicate** in `.tdd/disposition-matrix.md` (ACCEPT or
   PUSHBACK with rationale).
4. We **re-run /second-opinion** to confirm the fix and surface
   any new findings the change introduced.

A typical Tier 1 cycle runs 5-10 rounds of `/second-opinion`. v1.7.0
ran 7 rounds, 24 ACCEPT. v1.8.0 ran 7 rounds, 25 ACCEPT + 2 PUSHBACK
(same codex false-positive flagged twice; the function in question
was actually defined correctly, verified by smoke).

### How a cycle ends

When findings stabilize (or operator says stop), we:
1. Write `.tdd/disposition-matrix.md` — per-finding ACCEPT/PUSHBACK
   with rationale.
2. Write `.tdd/green-proof.md` — final smoke output, AC coverage
   table, "why not fake green" section.
3. Hash-bind `.tdd/second-opinion-completed.md` to the final
   diff_sha256 + plan_sha256.
4. Operator replies `APPROVED IMPLEMENTATION`.
5. Commit (with `feat(vX.Y.Z): ...` or `fix(vX.Y.Z): ...`).
6. Push.

Total elapsed per cycle: 6-14 hours of human + AI time, mostly
review.

### Why this works

The discipline is its own dogfood: when we ship a v1.7.0 feature
("typed test-edit exceptions"), we use the v1.6.x ceremony to ship
it. When we ship v1.8.0 ("AST validator"), we use v1.7.0's typed
exceptions to make legitimate test-call-site updates during the
implementation. Every release validates the prior release in
production.

---

## 4. How it works (architecture)

### Layered defense

The pack is six layers; each catches what the layer above missed:

```
Layer 0 — Spec gate         specs/ + specify skill
Layer 1 — TDD ceremony      .tdd/current-plan.md + 4 markers + 2 hooks
Layer 2 — In-session        CLAUDE.md + rules + skills + subagents + safety hooks
Layer 3 — Mechanical CI     .gitlab-ci.yml / .github/workflows/ci.yml
Layer 4 — Review judgment   REVIEW.md + reviewer subagents
Layer 5 — Cleanup           negative-diff skill
```

A user typically only sees layers 1-2 day-to-day. Layer 0 fires on
new features, Layer 3 fires in CI, Layer 4 fires on demand, Layer 5
fires after each cycle.

### Components

#### `.claude/` (Claude Code auto-loaded)

```
.claude/
├── settings.json    # Permissions + hook registration + MCP allowlist
├── allowed-modules.txt   # Slopsquat allowlist (org-prefix on first line)
├── rules/           # On-demand guidance referenced from CLAUDE.md
│   ├── go-tdd.md       # TDD discipline + ceremony rules
│   ├── go-style.md     # Go style + idioms
│   ├── go-testing.md   # Test patterns + table-driven tests
│   ├── go-security.md  # Crypto + secrets + input validation
│   ├── go-pgx.md       # pgx/v5 patterns (database access)
│   ├── go-ai-bloat.md  # AI-bloat detection patterns
│   ├── go-integration-guards.md  # Decision tree for guards vs tests
│   └── ...
├── agents/          # Reviewer subagents (discovered as Task subagents)
│   ├── go-reviewer.md
│   ├── go-architect.md
│   ├── go-security-reviewer.md
│   ├── go-concurrency-reviewer.md
│   ├── go-test-engineer.md
│   └── go-bloat-reviewer.md
├── skills/          # Workflow skills (invoked via /<skill-name>)
│   ├── go-tdd-feature/SKILL.md
│   ├── go-tdd-bugfix/SKILL.md
│   ├── second-opinion/SKILL.md
│   ├── specify/SKILL.md
│   ├── go-code-review/SKILL.md
│   ├── go-modernize/SKILL.md
│   ├── go-debug/SKILL.md
│   ├── go-test-writer/SKILL.md
│   ├── go-release-check/SKILL.md
│   ├── migration-review/SKILL.md
│   ├── new-module-scaffold/SKILL.md
│   ├── negative-diff/SKILL.md
│   ├── postmortem-fix/SKILL.md
│   └── minimal-go-change/SKILL.md
└── hooks/           # Safety + TDD enforcement (registered via settings.json)
    ├── require-tdd-state.sh        # Tier 1 file gate (M1-M3 at edit time)
    ├── gate-tier1-commit.sh        # Commit gate (M4 + green-proof + adjudication)
    ├── require-second-opinion.sh   # Tier 1 requires fresh /second-opinion
    ├── route-to-tdd.sh             # Advisory: routes work to right skill
    ├── guard-dangerous-bash.sh     # Denies --no-verify, force-push, terraform destroy, etc.
    ├── guard-protected-files.sh    # Denies edits to permissions.deny paths
    ├── guard-bash-pipefail.sh      # Denies piped Go commands without pipefail
    ├── scan-for-secrets.sh         # Content-based secret detection (uses gitleaks if available)
    ├── gofmt-after-edit.sh         # PostToolUse: auto-formats Go files
    ├── detect-ai-bloat.sh          # Detects AI-bloat patterns
    └── session-context.sh          # SessionStart: prints state context
```

#### `.tdd/` (TDD ceremony state machine)

```
.tdd/
├── tdd-config.json    # Tier 1 path regexes + required markers + caps + integration_guards
├── current-plan.md    # Active cycle plan (git-tracked)
├── red-proof.md       # Captured failing-test output (gitignored)
├── green-proof.md     # Captured passing-test output (gitignored)
├── second-opinion-completed.md   # Codex review adjudication (gitignored)
├── disposition-matrix.md         # Per-finding ACCEPT/PUSHBACK (git-tracked at cycle end)
├── exceptions/        # Per-cycle typed test-edit exceptions (gitignored)
│   └── post-red-test-edits.json
├── audit/             # Sha-chained audit log (gitignored)
│   └── <cycle-id>.jsonl
├── codex/             # /second-opinion JSON output + raw transcripts (gitignored)
│   ├── round*.json
│   └── v18r*.raw      # /second-opinion stdout per round
├── templates/         # feature-plan / bugfix-plan / red-proof / disposition-matrix / ...
└── presets/           # tier1_path_regexes presets: library.json, cli.json, service.json
```

#### `scripts/` (CI utilities + TDD smoke tests + AST helper)

```
scripts/
├── doctor.sh                       # Verify required + recommended tools
├── tdd-test-hooks.sh               # 520-test smoke suite (THE source of truth)
├── ci-go.sh                        # CI sequence: gofmt, vet, staticcheck, govulncheck, deadcode
├── check-tdd-ceremony.sh           # CI: verifies completed cycles have all four markers
├── check-tdd-state-clean.sh        # CI: verifies .tdd/current-plan.md is at idle state
├── check-allowed-modules.sh        # CI: rejects go.mod requires outside allowlist
├── changed-go-files.sh             # CI utility: emits changed .go files
├── install-go-tools.sh             # Bootstraps recommended Go tools
├── install-git-hooks.sh            # Installs git pre-commit + prepare-commit-msg
├── git-hooks/                      # Git-side hooks (defense at a different layer)
├── migrate-tdd-markers.sh          # Migrates plans from M3 rename (v1.5 → v1.6)
├── migrate-rebuttal-to-matrix.sh   # Migrates v1.5 rebuttal text → disposition matrix
└── tdd/
    ├── ast/
    │   └── validator.go            # v1.8.0 Go AST helper (4 subcommands)
    ├── grant-test-edit-exception.sh  # Operator-facing grant tool
    ├── verify-audit-chain.sh         # Audit-chain integrity checker
    ├── build-second-opinion-context.sh   # Generates schema-context for /second-opinion
    ├── _lib_commit_mode.sh            # Shared commit-mode classification
    ├── _lib_marker_drift_preprocessor.sh   # Marker-drift detection in codex findings
    └── _lib_test_edit_exception.sh    # Validator library (regex + AST AND-gate)
```

### Hook contract

Every hook in `.claude/hooks/*.sh` follows a strict protocol:

- **Input:** single JSON object on stdin (`tool_name`,
  `tool_input.command`, `tool_input.content`,
  `tool_input.new_string`, `tool_input.edits[]`, etc. depending on
  tool).
- **Output:** JSON decision on stdout with shape
  `{hookSpecificOutput:{hookEventName, permissionDecision,
  permissionDecisionReason}}`. Empty `{}` means pass.
- **Exit code:** always `0`. Never signal via non-zero. Decision
  goes in the JSON body.
- **Stderr:** human-readable deny message with
  `<claude-directive>` block telling the AI how to recover.
- **Registration:** Hooks register via `.claude/settings.json`
  (PreToolUse / PostToolUse / SessionStart). Claude Code loads this
  automatically when the project is opened.

When adding a hook: update `settings.json`, add deny/ask/pass test
cases to `scripts/tdd-test-hooks.sh`, keep `chmod +x` (CI verifies).

### Typed test-edit exception system (v1.7.0+)

The mechanism by which the AI is permitted to edit test files AFTER
`Red phase confirmed: yes`. Four types:

| Type | What it allows |
|---|---|
| `mechanical_signature_propagation` | Call-site widening when a signature changes (`Do(ctx)` → `Do(ctx, opts)`) |
| `compile_fix_only` | Type rename / import path / struct field rename — pure mechanical |
| `import_only` | Adding / removing imports without changing test semantics |
| `schema_predicate_correction` (v1.8.0) | AST-validated pure rename in test predicates (`got.OldField` → `got.NewField`) |

Each exception is granted via `scripts/tdd/grant-test-edit-exception.sh`,
operator approves with `APPROVED EXCEPTION E-NNN`, hook validates
matching edits via the validator library, audit-log line is
appended with `prev_sha` chained for integrity.

Auto-expiry on next git commit (HEAD-bound via
`binding.head_at_approval`). Killswitches:
`TEST_EDIT_EXCEPTION_DISABLE=1` (bypass entire system),
`TDD_AST_VALIDATOR_DISABLE=1` (regex-only fallback).

### AST helper (v1.8.0)

`scripts/tdd/ast/validator.go` is a single-file Go program invoked
via `go run` from the bash validator library. Four subcommands:

| Subcommand | Validates |
|---|---|
| `import-block-check --paths a,b` | Every +/- line falls inside a Go `import (...)` block in the synthesized new file |
| `mech-sig-prop-check --paths a,b` | Assertion helper sequence (full chain) preserved between -/+ sides |
| `compile-fix-scope-check --symbols X,Y --paths a,b` | Every changed line's AST identifiers include at least one declared scope symbol (no substring match) |
| `schema-predicate-check --old-name X --new-name Y --paths a,b` | Tokenize via `go/scanner`; only IDENT tokens may rename `oldName → newName`; all other tokens (literals, operators, strings, comments) must match exactly |

Each emits a JSON `Report` on stderr with `ok`, `reason`,
`evidence` and exits 0 (pass) / 1 (reject) / 2 (hard error).

When `go` is absent or `TDD_AST_VALIDATOR_DISABLE=1`, validator
library emits a stderr warning and falls back to regex-only
(v1.7.0 behavior). The `schema_predicate_correction` type has NO
regex fallback and fails closed when AST is unavailable.

### Audit chain (v1.8.0)

`.tdd/audit/<cycle-id>.jsonl` is append-only JSON-lines. Each line:
`{"ts": "...", "event": "granted|used|denied|expired",
"exception_id": "E-NNN", "cycle_id": "...", "prev_sha":
"<sha256-of-prior-line>"}`.

First line has `prev_sha: ""`. Subsequent lines chain via
`sha256(prior line text)`. The hook
(`.claude/hooks/require-tdd-state.sh`) calls
`scripts/tdd/verify-audit-chain.sh <cycle-id>` at typed-exception
dispatch:

- Chain mismatch → fail closed for typed exceptions in this cycle
  (legacy boolean path unaffected).
- Audit log missing while approved exceptions exist → fail closed.
- Mismatched ID set (artifact has E-002 approved but log only has
  grants for E-001) → fail closed.

These three checks were added in v1.8.0 across rounds 4, 5, 6, 7
of `/second-opinion` — each closing a specific tamper class codex
identified.

---

## 5. Where we are now

### v1.8.0 (current, shipped 2026-05-11)

**Codename:** AST validator + audit-log chain integrity.
**Commit:** `2ab3d7b`.
**Smoke:** 520 / 0 (483 v1.7.0 baseline + 14 AC tests + 23 round-derived RED→GREEN).
**Review history:** 7 rounds, 25 ACCEPT + 2 PUSHBACK (sha256 false-positive flagged twice).

What this closes (5 deferred items from v1.7.0):
- AST-based validation (regex limitations).
- `schema_predicate_correction` exception type.
- `compile_fix_only` AST scope.
- Per-cycle exception count caps.
- Audit-log integrity (was trust-only).

Full disposition matrix in
[`.tdd/disposition-matrix.md`](.tdd/disposition-matrix.md). Full
green proof in [`.tdd/green-proof.md`](.tdd/green-proof.md).

### Release history

| Version | Shipped | Codename |
|---|---|---|
| v1.8.0 | 2026-05-11 | AST validator + audit chain |
| v1.7.0 | 2026-05-10 | Typed test-edit exceptions |
| v1.6.2 | 2026-05-10 | Reduce per-cycle review friction (marker drift + Pass A docs) — 27 /second-opinion rounds |
| v1.6.1 | 2026-05-10 | Close 21 release-blocker bypasses via shared commit-mode lib |
| (earlier git-hooks work) | 2026-05-08+ | Git-side hooks + `--no-verify` bypass closure |
| v1.6.0 | 2026-05-08 | `/second-opinion` v1.6 — Pass A blind independent design, anchoring-resistant review |
| v1.5.x | earlier | Marker rename M3, integration guards |
| v1.3.x | earlier | First versioned baseline |

Full git log: `git log --oneline` (59 commits total).

### v1.9 backlog

| Item | Why deferred from v1.8.0 |
|---|---|
| Pre-built AST binary detection | `go run` cold-start ~300ms acceptable for v1.8.0; v1.9 will detect a pre-built binary at `scripts/tdd/ast/validator` |
| Multi-line schema renames | v1.8.0's `schema-predicate-check` is line-by-line; multi-line refactors must be split |
| External audit head pin | Sha-chain + grant-ID-set check covers most truncation; an external head hash would close the last-line edit edge case completely |
| Audit log archival / rotation | Log grows unbounded per cycle; v1.9 candidate: `cycle_close` event + auto-archive on green commit |
| Encrypted/signed audit log | Sha-chain detects unsophisticated tamper; doesn't defend against a compromised host. v2.0+. |
| AST helper sandboxing | `CLAUDE_PLUGIN_ROOT`-based path resolution for `go run` script discovery |
| Removal of legacy `allow_after_red_confirmed` boolean | v2.0.0 |

---

## 6. Codebase tour — where to look for what

### Start here

1. **`README.md`** — first-time user overview, runtime requirements,
   first-run MCP approval.
2. **`docs/AI_DEVELOPER_GUIDE.md`** — comprehensive onboarding
   (711 lines). Install, setup, daily workflows, stable error
   codes, killswitches.
3. **`docs/RELEASE_GUIDE.md`** — current release notes, update
   paths from prior versions.
4. **This file (`CONSULTANT_BRIEF.md`)** — you're here.

### Layer-specific deep dives

| Topic | File |
|---|---|
| TDD discipline rules | `.claude/rules/go-tdd.md` |
| Full TDD workflow (21-step) | `docs/process/tdd_workflow.md` |
| Hook contracts + structure | `.claude/hooks/*.sh` + `scripts/tdd-test-hooks.sh` (smoke) |
| Typed exception system (v1.7.0) | `docs/specs/typed-test-edit-exceptions-v1.7.0-spec.md` |
| AST validator + audit chain (v1.8.0) | `docs/specs/ast-validator-and-audit-integrity-v1.8.0-spec.md` |
| `/second-opinion` design | `docs/specs/second-opinion-v1.6.0-spec.md` |
| TDD gate redesign rationale | `docs/specs/tdd-gate-conflict-resolution-spec.md` |
| Integration guards | `.claude/rules/go-integration-guards.md` |
| Pack maintenance | `MAINTAINING.md` |
| For Codex / cross-agent | `AGENTS.md` |
| Reviewer subagents | `.claude/agents/*.md` |
| Skills (workflows) | `.claude/skills/*/SKILL.md` |

### Implementation files (the actual logic)

| File | What it does | LOC |
|---|---|---|
| `.claude/hooks/require-tdd-state.sh` | The Tier 1 file gate; enforces M1-M3 + typed-exception dispatch + audit chain verify + per-cycle cap | ~700 |
| `.claude/hooks/gate-tier1-commit.sh` | Commit gate; enforces M4 + green-proof + fresh adjudication | ~250 |
| `scripts/tdd/_lib_test_edit_exception.sh` | Validator library; AND-gates regex + AST per exception type | ~500 |
| `scripts/tdd/grant-test-edit-exception.sh` | Operator-facing grant tool; writes pending → approved transitions | ~250 |
| `scripts/tdd/ast/validator.go` | Go AST helper (v1.8.0); 4 subcommands; ~700 LOC of single-file Go |
| `scripts/tdd/verify-audit-chain.sh` | Audit-chain integrity walker | ~90 |
| `scripts/tdd-test-hooks.sh` | 520-test smoke suite (THE source of truth) | ~7900 |

### Test discipline

`scripts/tdd-test-hooks.sh` is structured as:
- Phase 1: per-hook integration tests (each hook tested in isolation).
- Phase 2: cross-hook orchestration tests.
- Phase 3: round-derived RED tests (one per /second-opinion finding
  across v1.6.1, v1.7.0, v1.8.0 rounds).
- Phase 4: self-tests (timeout wrapper, hook prerequisites).

To run all: `bash scripts/tdd-test-hooks.sh`. To filter: `bash
scripts/tdd-test-hooks.sh 2>&1 | grep -E '(v18_|^Results:)'`.

---

## 7. How to read the rest

### If you want to understand the architecture

Read in this order:
1. `docs/AI_DEVELOPER_GUIDE.md` (this is the user perspective).
2. `MAINTAINING.md` (this is the maintainer perspective — design
   decisions, why each layer exists).
3. `docs/specs/tdd-gate-conflict-resolution-spec.md` (rationale for
   the four-marker model — a prior version had a workflow conflict
   that surfaced in real cycles).
4. `docs/specs/second-opinion-v1.6.0-spec.md` (the
   anchoring-resistant review design; explains why we use TWO LLM
   families for review).
5. `docs/specs/typed-test-edit-exceptions-v1.7.0-spec.md` (the
   problem: AI can weaken tests; the solution: typed exceptions
   with explicit operator authorization).
6. `docs/specs/ast-validator-and-audit-integrity-v1.8.0-spec.md`
   (closes 5 deferred items from v1.7.0; introduces Go AST as
   strict additional layer).

### If you want to audit specific code paths

Use `grep -n` or `git log -p` against:
- `.claude/hooks/require-tdd-state.sh` — the largest hook;
  contains all Tier 1 gate logic.
- `scripts/tdd/_lib_test_edit_exception.sh` — the validator
  library. Each exception type has its own check block.
- `scripts/tdd/ast/validator.go` — the AST helper. Four `run*`
  functions, one per subcommand.

### If you want to see real cycle artifacts

Look at the most recent commits:
- `git show 2ab3d7b` — v1.8.0 commit.
- `git show e365bf7` — v1.7.0 commit.

For each cycle, the working artifacts (gitignored after merge but
useful for context) are in `.tdd/`:
- `.tdd/current-plan.md` — the spec we approved.
- `.tdd/red-proof.md` — verbatim failing-test output we captured.
- `.tdd/green-proof.md` — verbatim passing-test output we captured.
- `.tdd/disposition-matrix.md` — per-finding adjudication.
- `.tdd/codex/round*.json` + `v18r*.raw` — every codex review
  round's raw output.

### If you want to understand a specific decision

Each decision should be traceable to either:
- A `<codex finding> + <our disposition>` in the disposition matrix.
- A `<spec doc> + <APPROVED SPEC>` operator approval in git history.
- A `<rule file>` in `.claude/rules/` (which itself cites the
  incident or CVE that motivated the rule).

Where we couldn't trace a decision, we treat it as advisory; where
we could, we treat it as load-bearing.

---

## 8. Known limits + open questions

We're honest about what doesn't work:

### Validator limits (regex-style + AST hybrid)

- **AST cold-start ~300ms per `go run` invocation.** A power user
  edits many files; the cumulative cost is real. v1.9 will detect
  a pre-built binary.
- **`schema_predicate_correction` is line-by-line.** A multi-line
  refactor that legitimately renames across hunks isn't supported;
  operator splits the change. Real-world impact: most renames are
  single-line so this rarely bites.
- **AST helper sandboxing.** The validator's path resolution
  follows `BASH_SOURCE`; a malicious project could in principle
  craft a `validator.go` via PATH manipulation. Not a
  realistic threat for our user base (Go developers, project-trust
  model) but tracked for v1.9.

### Audit chain limits

- **Sha-chain doesn't defend against a compromised host.** An
  attacker with shell access can recompute the chain after editing.
  We chose this trade-off: protecting against operator mistakes and
  AI overreach (the realistic threat) without claiming to protect
  against a compromised host (which would require a co-located
  signing service we're not willing to maintain).
- **Last-line tamper.** Currently detected via grant-ID-set
  comparison (v1.8.0 round-7 F3) but an external head pin would be
  stronger. v1.9 candidate.

### `/second-opinion` limits

- **Codex's findings are not authoritative.** Codex has different
  blind spots than Claude, but it's still an AI. We've had 7
  rounds of v1.8.0 produce 2 false positives (the `sha256` function
  reading). Codex sees what's in the diff; it can miss context that
  exists in adjacent files.
- **`/second-opinion` doesn't add tests on its own.** When codex
  flags a finding, the IMPLEMENTER (us, Claude) writes the RED
  test that reproduces it. Codex doesn't write code, only
  describes findings.
- **OpenAI's data policy.** When `/second-opinion` runs, the
  redacted target (plan or diff) goes to OpenAI's inference
  servers. We redact via patterns in `.claude/redact-patterns.txt`
  but the canonical mitigation is "don't put secrets in code in
  the first place".

### TDD ceremony limits

- **Friction is the point — but friction backfires when
  misapplied.** Setting `tier1_path_regexes` too broadly creates
  ceremony fatigue. Setting too narrowly leaves blind spots.
  Operators must calibrate.
- **The four-marker model assumes good-faith operator approval.**
  An operator who rubber-stamps `APPROVED IMPLEMENTATION` without
  reading the diff defeats the system. We don't have a mechanism
  to enforce reading; we rely on operator discipline.

### Open questions for the consultant

The questions we'd most value an external view on:

1. **Is the friction proportionate?** v1.7.0 took 7 rounds (24 P0/P1
   findings). v1.8.0 took 7 rounds (25 ACCEPT). Is this a sign of
   genuine complexity, or are we over-engineering? When should a
   cycle stop?
2. **Are we biased toward our own approach?** We chose four-marker
   TDD because it surfaced the real workflow we already used. But
   we haven't compared empirically against alternatives (e.g.,
   pre-flight ADR + post-hoc review, or BDD + spec-by-example).
3. **Is the dogfood signal real?** v1.7.0 was developed using v1.6.x
   ceremony; v1.8.0 was developed using v1.7.0's typed exceptions.
   That's a strong signal but also a small sample (2 self-validations).
4. **Are we chasing AI-specific failure modes that have already
   been mitigated?** Our hooks were motivated by specific
   incidents (#40117 `--no-verify` bypass, DataTalks.Club `terraform
   destroy`, #45893 unauthorized push). Have model improvements
   since (Claude 4.6 / 4.7 / Sonnet 4.6) reduced the realistic
   frequency of these failure modes?
5. **Where would we get the biggest leverage from external
   review?** Architecture? Test coverage? Documentation? The AST
   validator's design? The audit-chain design? The `/second-opinion`
   anchoring-resistance?

---

## 9. Practical info for the consultant

### To run the project locally

You don't need to actually USE the pack to review it. To verify the
smoke suite:

```bash
cd go-projects-claude-starter
bash scripts/tdd-test-hooks.sh 2>&1 | tail -3
# Expect: Results: 520 passed, 0 failed
```

Prerequisites: bash 5+, jq, git, Go 1.26.2+. macOS users:
`brew install bash jq go`.

### To exercise `/second-opinion` yourself

```bash
codex login   # or set CODEX_API_KEY
bash /tmp/run-second-opinion-v180.sh   # the v1.8.0 review driver
```

Output saved to `.tdd/codex/v18r*.raw`.

### To trace a specific finding

```bash
ls .tdd/codex/   # find the round
cat .tdd/codex/v18r5.raw   # the raw output of round 5
grep -A 20 'F1' .tdd/codex/v18r5.json   # the structured finding
git log --grep='v18.*round-5' --oneline   # the fix commits (if any)
```

### To see the discipline in action

```bash
# Read the v1.8.0 cycle artifacts (chronological):
cat .tdd/current-plan.md           # the spec
cat .tdd/red-proof.md              # red-phase capture
cat .tdd/codex/v18r1.raw           # first /second-opinion round
cat .tdd/codex/v18r7.raw           # final round
cat .tdd/disposition-matrix.md     # per-finding adjudication
cat .tdd/green-proof.md            # green-phase capture
cat .tdd/second-opinion-completed.md   # final adjudication
```

These artifacts are the heart of the project. They show exactly
what was reviewed, what we accepted, what we pushed back on, and
why.

---

## 10. Summary in one paragraph

`go-claude-starter` is a Go-project starter pack that gives teams
using AI coding assistants a pre-wired governance layer — four-marker
TDD ceremony, `/second-opinion` cross-model review, typed test-edit
exceptions with Go-AST validation, sha-chained audit log. We
develop it using its own discipline (dogfood); v1.7.0 closed the
"AI weakens a test" failure mode with typed exceptions; v1.8.0
closed v1.7.0's regex limitations with a Go AST helper and added
audit-chain integrity. Current state: v1.8.0, 520/0 smoke, 59
commits, 7 rounds of cross-model review on the latest cycle.
What we'd value from an external consultant: an honest read on
whether the friction is proportionate to the failure modes we're
mitigating, and where the highest-leverage improvements lie.
