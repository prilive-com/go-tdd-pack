# Feature Plan: v1.9.0-pack-no-discretion-second-opinion

Status: active
Cycle ID: v1.9.0-pack-no-discretion-second-opinion
Change type: governance hardening (removes AI discretion over
                /second-opinion invocation; ships PreToolUse triggers,
                Stop gate, and skill lock)
Tier: 1 (touches `.claude/hooks/*`, `.claude/skills/second-opinion/SKILL.md`,
         `scripts/tdd/*`, `CLAUDE.md` — all governance-critical)

<!-- TDD ceremony markers. Set each ONLY after the matching operator APPROVED reply. -->
Human approved spec: yes
Red phase confirmed: yes
Green phase authorized: yes
Implementation reviewed: yes

## Triggering evidence

Real conversation transcript 2026-05-12: AI developer skipped
/second-opinion four times in a single supervisor-race-fix cycle, each
skip technically defensible under v1.8.0 rules:

1. "Will I run /second-opinion? No — Tier 2 mechanical fix."
2. "No on new test file — Tier 2 test addition, no policy change."
3. "No on inspection pass — read-only investigation, no review needed."
4. "YES at end before commit — but three prior bypasses already shipped."

Per the v1.8.0 model, the AI gets to interpret what's "non-trivial."
v1.9.0 removes that discretion.

## Feature goal

The AI never decides whether /second-opinion is required. Authority
lives in three places only:

1. `.tdd/tdd-config.json` — declarative policy
2. PreToolUse trigger hooks (plan / test / production) — runtime enforcement
3. v1.8.0's `gate-tier1-commit.sh` — pre-commit final gate

Three semantic-event triggers (all PreToolUse, blocking before the
write lands):

- **plan_review** — `.tdd/current-plan.md`, `.tdd/plans/**`, `docs/specs/*.md`
- **test_review** — `*_test.go` (except pure-mechanical v1.7.0-typed diffs)
- **production_edit_review** — `*.go` outside test/governance/docs/scripts dirs;
  per-cycle-per-`base_git_sha` scope (one completion covers all
  production edits in cycle until next commit boundary)

Read-only operations (Grep, Read, read-only Bash) never trigger.

The system extends v1.7.0's typed-exception artifact and v1.8.0's
SHA-chained audit log. No parallel obligation engine.

## Business / domain invariants

The change MUST preserve:

1. **No discretionary skip path.** No code path inside the
   /second-opinion workflow is conditional on the agent's adjudication
   of its own change. Skill has `disable-model-invocation: true`;
   `Skill(second-opinion)` is blocked at the Claude Code runtime level.
2. **Scope-bound completions.** Completion is valid only for the exact
   (cycle_id, plan_path, plan_content_hash) for plan reviews;
   (cycle_id, test_file_path, package_files_hash) for test reviews;
   (cycle_id, base_git_sha, tier_level) for production-edit reviews.
   Any drift re-blocks.
3. **Schema-enforced verdicts with conformance verification.** Codex
   output uses `--output-schema` BUT runner verifies actual JSON
   conformance via jq (defends against openai/codex#4181 gpt-5-family
   gating and #15451 silent-ignore when MCP active).
4. **Single SHA-chained audit log** (v1.8.0 extended). No parallel.
5. **Skill body is reference, not workflow.** Zero "use your judgment"
   language. `disable-model-invocation: true` enforces this.
6. **Operator waiver via existing typed-exception flow.** Same
   `APPROVED EXCEPTION E-NNN`. Same `max_per_cycle` cap (v1.8.0).
7. **`--no-verify` paths.** v1.8.0's `guard-dangerous-bash.sh` catches
   AI-side `git commit --no-verify`. Local `prepare-commit-msg` is
   NOT bypassed by `--no-verify` per official Git docs — used as a
   defense-in-depth client-side gate.

The change MUST NOT:

1. Change v1.7.0 typed-exception schema in a breaking way (additive
   only — new `type` values).
2. Strip `set -euo pipefail` discipline from hooks.
3. Add EU / ISO / NIST regulatory language anywhere.
4. Introduce a parallel "obligation engine" runtime.
5. Use async hooks in the gating path.

## Acceptance criteria

### AC1 — Skill is invoke-only (PR 1)
- `disable-model-invocation: true` AND `user-invokable: true` in frontmatter.
- Skill body rewritten — first paragraph asserts hooks are authority;
  removes every "use your judgment" / "non-trivial" / "auto-invoke" /
  "fresh enough" phrase.

### AC2 — Schema extension + validator (PR 2)
- `.tdd/exceptions/post-red-test-edits.json` schema gains
  `plan_review_completion`, `test_review_completion`,
  `production_edit_review_completion` entry types.
- `.tdd/templates/review-completion.schema.json` is Codex
  `--output-schema` target. Required fields: `review_type`, `cycle_id`,
  `scope_hash`, `verdict`, `findings[]`, `required_actions[]`.
- `scripts/tdd/ast/validator.go` adds `review-completion-check`
  subcommand validating schema + binding + SHA-chain.
- `scripts/tdd/hash-review-scope.sh` computes deterministic scope hashes.

### AC3 — Runner script (PR 3)
- `scripts/tdd/run-second-opinion.sh <review-type> <cycle-id>` is the
  ONLY legitimate `codex exec` caller.
- Context pack via `scripts/tdd/build-second-opinion-context.sh`.
- Codex invocation: `--sandbox read-only --ephemeral --json
  --output-schema ... --output-last-message ... -m gpt-5.5`.
- **Conformance verification via jq, not flag-trust.** Defends against
  `--output-schema` silent-ignore caveats (#4181, #15451).
- Re-prompt up to 2 times on non-conformance; then
  `CODEX_OUTPUT_NON_CONFORMANT` typed exception; exit non-zero.
- Model-family check: refuse to run on family known to silently drop
  `--output-schema` → `MODEL_NOT_SCHEMA_COMPATIBLE`.
- P0/P1 unresolved → no completion entry written.

### AC4 — Plan-write trigger (PR 4)
- `.claude/hooks/second-opinion-plan-trigger.sh` PreToolUse on
  `Edit|Write|MultiEdit` for `.tdd/current-plan.md`, `.tdd/plans/**`,
  `docs/specs/*.md`.
- Computes `scope_hash = sha256(cycle_id|plan_path|proposed_plan_content_hash)`.
- Allows on matching `plan_review_completion`; otherwise denies with
  stable error code `PLAN_REVIEW_REQUIRED`.

### AC5 — Test-write trigger (PR 4)
- `.claude/hooks/second-opinion-test-trigger.sh` PreToolUse on `*_test.go`.
- `scope_hash = sha256(cycle_id|test_file_path|package_files_hash)`.
- Skip threshold: pure `mechanical_signature_propagation` or
  `import_only` diffs pass-through to v1.7.0 typed exceptions.
- Otherwise denies with `TEST_REVIEW_REQUIRED`.

### AC6 — Production-edit trigger (PR 4, per operator)
- `.claude/hooks/second-opinion-production-trigger.sh` PreToolUse on
  `*.go` outside test/governance/docs/scripts/vendor dirs.
- `scope_hash = sha256(cycle_id|base_git_sha|tier_level)`. Tier from
  `tier1_path_regexes` match.
- Per-cycle-per-`base_git_sha`: one completion covers all production
  edits until commit advances HEAD. Then re-blocks.
- **`PRODUCTION_SCOPE_DRIFT`** detection: file-list at completion-time
  recorded; if subsequent edit names a file outside the recorded list,
  block.
- Otherwise denies with `PRODUCTION_EDIT_REVIEW_REQUIRED`.

### AC7 — PostToolUse backstop + Stop gate (PR 5)
- `.claude/hooks/second-opinion-posttool-backstop.sh` PostToolUse on
  Bash, catches mutations PreToolUse couldn't classify.
- `.claude/hooks/session-stop-review.sh` Stop hook:
  - `stop_hook_active == true` → exit 0 immediately (loop guard).
    Verified semantics: FALSE on first Stop, TRUE on continuation.
  - Pending obligations exist → block.
  - `.tdd/CYCLE_ABANDONED.txt` signed by operator → allow stop.

### AC8 — Git commit gate (PR 6)
- v1.8.0 `gate-tier1-commit.sh` unchanged.
- v1.8.0 `guard-dangerous-bash.sh` continues to block
  `git commit --no-verify` via PreToolUse Bash matcher.
- Local `prepare-commit-msg` retained as defense-in-depth
  (NOT bypassed by `--no-verify` per official Git docs).

### AC9 — Operator waiver via extended typed-exception (PR 6)
- `plan_review_waiver`, `test_review_waiver`,
  `production_edit_review_waiver` use existing
  `APPROVED EXCEPTION E-NNN` flow.
- Same `max_per_cycle` cap (default 5).
- Same audit-chain entry with operator identity.

### AC10 — Documentation + transcript replay (PR 7)
- `.claude/rules/go-tdd.md` — new "v1.9.0 auto-review triggers" section.
- `docs/AI_DEVELOPER_GUIDE.md` — append stable error codes to table.
- `docs/RELEASE_GUIDE.md` — v1.9.0 entry.
- `CLAUDE.md` — append Second Opinion No-Discretion Rule.
- `AGENTS.md`, `code_review.md` — Codex review instructions per review type.
- Transcript replay tests (T-28 through T-34) ALL pass.

## Affected code

| File | Change | Est. LOC |
|---|---|---|
| `.claude/skills/second-opinion/SKILL.md` | Frontmatter `disable-model-invocation: true` + body rewrite | +60 / -120 |
| `.claude/hooks/second-opinion-plan-trigger.sh` | NEW PreToolUse | +100 |
| `.claude/hooks/second-opinion-test-trigger.sh` | NEW PreToolUse | +100 |
| `.claude/hooks/second-opinion-production-trigger.sh` | NEW PreToolUse | +150 |
| `.claude/hooks/second-opinion-posttool-backstop.sh` | NEW PostToolUse | +80 |
| `.claude/hooks/session-stop-review.sh` | NEW Stop | +70 |
| `.claude/settings.json` | Hook registration | +30 |
| `scripts/tdd/run-second-opinion.sh` | NEW runner | +200 |
| `scripts/tdd/build-second-opinion-context.sh` | NEW context pack builder | +120 |
| `scripts/tdd/hash-review-scope.sh` | NEW scope-hash util | +50 |
| `scripts/tdd/validate-review-completion.sh` | NEW completion validator | +80 |
| `scripts/tdd/ast/validator.go` | Add `review-completion-check` subcommand | +150 |
| `.tdd/templates/review-completion.schema.json` | NEW Codex output schema | +100 |
| `.tdd/exceptions/post-red-test-edits.json` (schema) | Schema extension (3 new types) | +30 |
| `scripts/git-hooks/prepare-commit-msg` | Defense-in-depth gate | +40 |
| `.tdd/tdd-config.json` | `second_opinion.no_discretion` block | +40 |
| `CLAUDE.md` | §1.1 inviolable rule | +30 |
| `AGENTS.md`, `code_review.md` | Codex review instructions | +80 |
| `.claude/rules/go-tdd.md` | v1.9.0 triggers section | +80 |
| `docs/AI_DEVELOPER_GUIDE.md` | Stable error codes appended | +40 |
| `docs/RELEASE_GUIDE.md` | v1.9.0 entry | +120 |
| `scripts/tdd-test-hooks.sh` | ~34 new tests | +800 |

Estimate: ~2,500 LOC additions, ~120 LOC deletions.

## Stable error codes (added in v1.9.0)

- `PLAN_REVIEW_REQUIRED`
- `TEST_REVIEW_REQUIRED`
- `PRODUCTION_EDIT_REVIEW_REQUIRED`
- `REVIEW_SCOPE_MISMATCH`
- `REVIEW_TYPE_MISMATCH`
- `REVIEW_COMPLETION_EXPIRED`
- `PRODUCTION_SCOPE_DRIFT`
- `CODEX_OUTPUT_NON_CONFORMANT`
- `CODEX_UNREACHABLE`
- `MODEL_NOT_SCHEMA_COMPATIBLE`
- `WAIVER_REQUIRED`
- `WAIVER_SCOPE_MISMATCH`

## Implementation order (7 PRs)

| PR | Files | Risk | Reasoning |
|---|---|---|---|
| PR 1 — Skill lock | SKILL.md, CLAUDE.md §1.1 | Zero side-effects | Ships first; cannot break anything. |
| PR 2 — Schema + validator | schema.json, hash-review-scope.sh, validate-review-completion.sh, AST subcommand | Low | Pure data-layer additions. |
| PR 3 — Runner | run-second-opinion.sh, build-second-opinion-context.sh, validate-review-output.jq | Medium | Operator can manually run; hooks not yet wired. |
| PR 4 — PreToolUse triggers (plan + test + production) | 3 hook scripts, settings.json | **High — enforcement turns on** | Pack dogfoods itself starting here. |
| PR 5 — Backstop + Stop gate | posttool-backstop.sh, session-stop-review.sh | Medium | Belt-and-braces. |
| PR 6 — Git hooks + commit gate | prepare-commit-msg, .github/workflows | Medium | Defense-in-depth. |
| PR 7 — Docs + transcript replay | rules/go-tdd.md, AI_DEVELOPER_GUIDE.md, RELEASE_GUIDE.md, T-28..T-34 | Low | Closes the cycle. |

## Failing tests that capture the feature (34 total)

| Test | What it pins |
|---|---|
| **T-1..T-15** (unit/hook) | AC4, AC5, AC6 trigger logic; AC2.4 validator; AC2.5 scope-hash util |
| **T-16..T-22** (runner+Codex) | AC3.1-3.9 runner; `--output-schema` caveats; P0/P1 gating |
| **T-23..T-27** (skill+Stop) | AC1; AC7 Stop gate semantics |
| **T-28..T-34** (transcript replay) | All four 2026-05-12 transcript bypasses closed; scope-widening; commit-boundary expiry |

## Smoke test growth target

520 baseline (post v1.8.0) + ~34 new = **~554 passing, 0 failing**.

## Risk register

| Risk | Mitigation |
|---|---|
| Production-edit trigger creates one block per commit boundary | Per-cycle scope, not per-file. Operator UX is one-line runner script. |
| `--output-schema` silently ignored under MCP / gpt-5-codex | AC3.4 jq conformance check, not flag-trust |
| Stop-hook infinite loop | AC7.2.1 `stop_hook_active` check (canonical idiom) |
| File-list drift between obligation and execution | AC6.4 `PRODUCTION_SCOPE_DRIFT` detection |
| Operator fatigue with per-commit blocks | Mode B deferred to v1.10 if 30-day window shows fatigue |
| Codex API spend | Bounded by N(plan+test+commit) per cycle (<15). `CODEX_BUDGET_PER_CYCLE` hard cap. |
| Hash collisions on scope_hash | SHA-256 over canonical inputs; cryptographically negligible |

## Non-goals (out of scope)

- No regulatory mapping doc (EU AI Act / ISO 42001 / NIST). Operator instruction.
- No forbidden-phrases list. Brittle theatre; the lock IS `disable-model-invocation: true`.
- No parallel obligation-engine runtime. Single extended typed-exception artifact.
- No Mode B (auto-invoke from PreToolUse). Defer to v1.10 if fatigue measurable.
- No async hooks in gating path.
- No telemetry to Anthropic / OpenAI.
- No port to Cursor / Aider / Cline.
- No third reviewer beyond Codex.

## Effort estimate (honest)

| Phase | Time |
|---|---|
| Cycle plan (done) | ~1h |
| Red phase (~34 RED tests) | 3h |
| Green phase (PR 1 → PR 7) | 8h |
| /second-opinion review (~6-8 rounds expected) | 6-8h |
| Adjudication artifacts | 1.5h |
| Total elapsed | **~20-22h** |

Larger than v1.7.0/v1.8.0 (each ~16-18h) because of the PR count and
the variety of integration surfaces (hooks + runner + schema +
validator + docs).
