# Changes for code review

**Project:** `go-claude-starter` — opinionated Claude Code pack for Go projects
**Branch under review:** `feature/second-opinion`
**Diff baseline:** `main` (last stable: v1.3.1, commit `fbfafa7`)
**Bundle generated:** 2026-05-08
**Total commits since baseline:** 13
**Total files touched:** 33 (16 new, 17 modified)
**Smoke test count:** 26 (baseline) → 86 (current). All passing.

---

## What this bundle contains

Three layers:

1. **Changed files** preserving repo paths — every file modified or added since `main`. The actual review subject.
2. **Context files** — full `.claude/`, `.tdd/`, `scripts/`, root-level pack files. Included so you don't have to ask "can I see X?" — it's already here.
3. **`_meta/` directory** with machine-readable supplementary material:
   - `full-diff.patch` — complete `git diff main..feature/second-opinion` (5,751 insertions, 114 deletions)
   - `commits.txt` — short oneline log
   - `commits-full.log` — full commit messages with the "why this not that" rationale
   - `diff-stat.txt` — file-by-file change sizes
   - `file-changes.txt` — A/M/D status per file

---

## Why this branch exists (the trigger)

The `/second-opinion` skill was added in v1.4.0 as a manual cross-model review (Claude reviewed via Codex). Real-trial use surfaced multiple structural issues:

1. **Skill auto-invocation was bypassable** — Claude judged a non-trivial change as "obvious cleanup" and skipped the skill. Mechanical enforcement was needed.
2. **Trial-period feedback (D2 cycle)** found three concrete bugs in the redaction pipeline: comment lines crashed awk, missing empty-output validation, narrow discipline-marker scope.
3. **TDD gate doc/code drift** caused a real deadlock — docs described a 3-phase workflow with 3 operator approvals; the hook implemented a 2-phase workflow with 1 operator approval. Marker M3 was named "Human approved implementation" but used as "Green phase authorized." Operators paused at the boundary.
4. **Parasitoid trial-period feedback (separate downstream project)** found 3 P0/P1 cross-module integration bugs that plan-review missed because the diff didn't show the consumer side of stringly-typed contracts.
5. **Earlier consultant reviews** recommended anchoring-resistant review (Pass A blind independent design), structured disposition matrix, research-packet artifact — backed by 2025–2026 multi-agent review literature on confirmation bias and ensembling vs. debate.

---

## What was implemented (mapped to consultant recommendations)

### From the v1.6.0 consultant analysis

| Recommendation | Status | Where to look |
|---|---|---|
| Pass A blind independent design (Tier 1 only) | **Adopted**, opt-in via `second_opinion.require_pass_a_tier1` flag (default off) | `.claude/skills/second-opinion/SKILL.md` Pass A logic block; `.tdd/templates/independent-design-template.md` |
| Concern Disposition Matrix replaces free-form rebuttal | **Adopted**, opt-in via `second_opinion.require_disposition_matrix_tier1` flag (default off) | `.tdd/templates/disposition-matrix-template.md`; matrix step in SKILL.md Step 6b; row-count validation in `require-second-opinion.sh` |
| Research-packet artifact for Tier 1 plans | **Adopted**, opt-in via `second_opinion.require_research_packet_tier1` flag (default off) | `.tdd/templates/research-packet-template.md`; ≥3-source check in `require-second-opinion.sh` |
| Codebase-grep invitation in Pass B prompt | **Adopted** (always on for Tier 1) | `.claude/skills/second-opinion/SKILL.md` `CODEBASE GREP` section in prompt |
| Closure check in diff-review (verify accepted findings implemented) | **Adopted** (always on when prior matrix exists) | `.claude/skills/second-opinion/SKILL.md` `closure_check_block` |
| Patterns pre-pass before per-finding adjudication | **Adopted** (template addition) | `.tdd/templates/disposition-matrix-template.md` `## Cross-cutting observations` section |
| Round 3 / counter-review | **Rejected** — literature consensus on convergence/sycophancy | spec section 7 |
| 8-state machine | **Rejected** — over-engineering | kept the 4-marker model from v1.5.2 |
| 4th marker (`Deep review reconciled: yes`) | **Rejected** — matrix existence + row count IS the gate | spec section 9.1 |
| 3-tier classifier (Level 1/2/3) | **Rejected** — parallel to existing Tier system | spec section 7 |
| Role-theater subagents | **Rejected** — same model with different prompts adds no signal | spec section 7 |
| New hook proliferation | **Rejected** — composed into existing `gate-tier1-commit.sh` | section 4 |

### From the parasitoid trial feedback

| Bug reported | Status | Where to look |
|---|---|---|
| `cat ... 2>/dev/null` false-positive in mutating-Bash detector | **Fixed** — regex requires non-digit before `>+` | `.claude/hooks/require-second-opinion.sh` line ~160 |
| AI-bloat hook fires on `.md` TODO discussion | **Fixed** — TODO scan restricted to `*.go` | `.claude/hooks/detect-ai-bloat.sh` |
| `green-proof.md` template missing | **Added** | `.tdd/templates/green-proof.md` |
| Agent-applied governance patches without consulting maintainer | **Documented as Forbidden rule** | `.claude/rules/go-tdd.md` "Forbidden" section |
| 3 cross-module integration bugs (orderLinkId case mismatch, GenerateGridOrderLinkId only-bear-grid, orchestrator bypass) | **Mechanism added** — `integration_guards` array in `tdd-config.json` + commit-time check in `gate-tier1-commit.sh` | `.claude/rules/go-integration-guards.md` for design rationale |
| Tier detection bug in plan-mode (`\.go$` doesn't match paths in prose) | **Deferred** — workaround: v1.6.0 defaults non-Tier-1 to `gpt-5.5` so misclassification is cosmetic | noted in `docs/DEVELOPER_UPDATE_NOTES.md` |
| Per-cycle Pass A opt-out | **Deferred** — workaround: env-var prefix on single invocation | noted in `docs/DEVELOPER_UPDATE_NOTES.md` |

### TDD gate redesign (separate from consultant analyses, internal trigger)

| Change | Why | Where to look |
|---|---|---|
| 4-marker model (was 3) | Resolved doc/code drift that caused operator deadlock at green-phase boundary | `docs/specs/tdd-gate-conflict-resolution-spec.md` for full rationale; `.tdd/tdd-config.json` `required_markers_edit_time` and `required_markers_commit_time` |
| New `gate-tier1-commit.sh` hook | Mechanical enforcement of M4 (`Implementation reviewed: yes`) at `git commit` | `.claude/hooks/gate-tier1-commit.sh` |
| Phase-aware test policy | Old `allow_test_file_edits_without_gate: true` flag contradicted documented "no editing tests in green phase" rule | `.tdd/tdd-config.json` `test_file_policy`; `.claude/hooks/require-tdd-state.sh` |
| Distinct `APPROVED SPEC` / `APPROVED GREEN` / `APPROVED IMPLEMENTATION` operator commands | Doc-layer disambiguation matching code-layer 3-gate model | `.claude/rules/go-tdd.md` "What APPROVED means" section |
| Backwards-compat alias for old M3 name | In-flight v1.5.x plans don't break | `.tdd/tdd-config.json` `marker_aliases`; alias-with-warning in `require-tdd-state.sh` |
| Migration script `scripts/migrate-tdd-markers.sh` | Idempotent rename + M4 insertion for in-flight plans | `scripts/migrate-tdd-markers.sh` |

### CI fix (incidental but in scope)

`.gitlab-ci.yml` `agents-md-sync` job — pre-existing YAML parsing bug surfaced by the first MR pipeline. Single quote added to line 44 so the script item parses as a string instead of a key/value map.

---

## What's empirically PROVEN vs MECHANISM-VALIDATED vs UNPROVEN

Honest status of each component:

| Component | Status |
|---|---|
| Mandatory `/second-opinion` enforcement (`require-second-opinion.sh`) | **Proven** — caught real bypass attempts in trial use |
| Pipefail guard | **Proven** — caught real `go build \| head` masking exit code |
| Redact-patterns hardening | **Proven** — fixed actual silent-failure bug in trial |
| PARTIAL discipline check | **Proven** — catches real label drift |
| TDD gate redesign (4 markers, 3 gates) | **Proven** — resolved real operator deadlock |
| Phase-aware test policy | **Mechanism proven**; operationally untested at scale |
| Disposition matrix (structural improvement on rebuttal) | **Mechanism proven**; LLM behavior unchanged so safe |
| Research packet (spec-phase discipline) | **Mechanism proven**; LLM behavior unchanged |
| Codebase-grep invitation | **Mechanism in place**; effectiveness depends on Codex's actual tool use in production repos |
| Closure check | **Mechanism proven**; correctly composes with prior matrix |
| Integration guards | **Mechanism proven** on synthetic tests; project-specific guard quality is the consumer's responsibility |
| **Pass A blind independent design** | **Mechanism validated on one synthetic scenario** (live codex run on JWT refresh-token rotation plan; Pass A caught security gaps Claude's plan missed — token hashing, generation field, status enum). **Codebase-specific value unproven** for production cycles. Default off; spec §8 includes validation plan. |

---

## Areas I would specifically welcome scrutiny on

In rough order of "how much I'd value an outside opinion":

### 1. Pass A's blast radius

Pass A runs an extra Codex round (~+60-90s, ~+5k tokens) per Tier 1 cycle when the flag is on. The mechanism is empirically motivated by 2025–2026 literature on anchoring bias and ensembling-over-debate, but I cannot prove value-for-cost on real cycles.

**Specific question:** is the validation plan in `docs/specs/second-opinion-v1.6.0-spec.md` §8 sufficient? It says "flip the flag on next Tier 1 cycle and observe; if Pass A's independent design proposes anything Claude missed, keep flipped." That's lower rigor than a fixture-based eval harness with seeded defects. Should a real eval harness ship before Pass A is recommended for adoption?

### 2. The skill/hook semantic mismatch the developer reported

Two separate "trivial paths" lists drift independently:

- `require-tdd-state.sh` always-allow paths (`*/.tdd/*`, `*/.claude/*`, `*.md`, etc.)
- `/second-opinion` SKILL.md `skip_globs` (subset overlap, includes `go.sum` but NOT `go.mod`)

Developer hit this when trying to land a 1-line `go.mod` toolchain pin: hook denied because `go.mod` isn't in the always-allow list. Skill would have skipped the review (3-line pin in skip_globs heuristics) but skill never ran because hook blocked first.

**Specific question:** is the right fix a single source of truth in `tdd-config.json` (`trivial_paths.always_allow_globs` array) that both hooks and the skill read? Or is the right fix to make hooks delegate to the skill's heuristics? I lean single-source-of-truth.

### 3. `is_bash_mutating()` path-blindness

Same root cause as #2. The detector matches `cat > X` regex without extracting and validating X. So the skill's own internal machinery (`cat > .tdd/codex/round1.json`) trips the hook even though `.tdd/codex/` is supposed to be allow-listed everywhere.

**Specific question:** is path-aware extraction (parse the redirect target, check against allow-list) the right fix? My alternatives: skill-internal env var that the hook respects (less elegant); rewrite skill to use `printf > /dev/stderr | tee` patterns (uglier); add a per-redirect "allow" comment marker (too clever).

### 4. The parasitoid leakage in active code comments

The `integration_guards` rule file uses `ExchangeService.PlaceOrder` / `IntentTracker` as illustrative examples — those are parasitoid-specific. The hook scripts contain comments like "Reported by the parasitoid trial." The starter pack ships to many downstream projects; naming a specific consumer in active code is questionable.

I created `docs/ADOPTION_GUIDE.md` with generic examples to give to fresh-project developers. Did NOT clean up the rule docs and hook comments — partial cleanup is in scope.

**Specific question:** is partial cleanup (active code generic, historical specs preserve project-name as audit trail) the right balance? Or should EVERYTHING be genericized?

### 5. The 4-marker / 3-gate model — was a 4th marker the right call?

v1.5.2 had 3 markers; v1.6.0 added M4 (`Implementation reviewed: yes`) gated by `gate-tier1-commit.sh`. The earlier consultant analyses were split — one wanted 4 markers + new commit hook, one said matrix existence + row-count check could be the gate without a new marker.

I shipped both: 4 markers (with M4 gating commits) AND matrix discipline (gating Tier 1 edits). They're complementary but there's some redundancy.

**Specific question:** is M4 carrying its weight, or is matrix discipline + green-proof + fresh adjudication enough? The argument for keeping M4 is human gate-3 catches "is this the right thing to ship?" judgment that AI review misses. The argument against is operator burden + redundancy with the disposition-matrix gate.

---

## Hot links — start here

| Doc | What it covers |
|---|---|
| `docs/specs/second-opinion-v1.6.0-spec.md` | Full v1.6.0 design rationale, consultant synthesis, rejected alternatives, validation plan |
| `docs/specs/tdd-gate-conflict-resolution-spec.md` | Why the 4-marker model exists; what the original deadlock was |
| `docs/DEVELOPER_UPDATE_NOTES.md` | What developers updating from v1.3.1 need to know |
| `docs/ADOPTION_GUIDE.md` | What developers on fresh projects need to know |
| `MAINTAINING.md` | Pack maintenance philosophy + design choices |
| `_meta/full-diff.patch` | Complete diff vs main |
| `_meta/commits-full.log` | Commit-by-commit reasoning |

---

## What I'm asking you for

Not a yes/no on each component. I need you to:

1. **Push back on the Pass A flag** — do you trust the validation plan, or is a fixture-based eval harness needed before recommending adoption?
2. **Push back on the skill/hook drift** — single source of truth or hook-delegates-to-skill? Which is the correct architectural fix?
3. **Calibrate the parasitoid-leakage cleanup** — partial or total?
4. **Stress-test M4** — is it carrying its weight or is it redundancy?
5. **Anything else you see that we missed.**

If you find bugs, label them by severity (P0/P1/P2/P3) and category. The disposition matrix format documented in `.tdd/templates/disposition-matrix-template.md` is what we'll use to adjudicate your findings.

---

## Smoke test summary

```
Run: bash scripts/tdd-test-hooks.sh
Expected: Results: 86 passed, 0 failed
```

Test growth across the branch:
- 26 (baseline / main / v1.3.1)
- 35 (after mandatory enforcement hooks)
- 43 (after trial-feedback hardening)
- 61 (after TDD gate redesign + integration guards)
- 68 (after model defaults + integration guards complete)
- 81 (after v1.6.0 anchoring-resistant review)
- 86 (after parasitoid trial-feedback fixes — current)

Every test name maps to either a real bug caught in trial OR a documented contract. No "added for line coverage" tests.

---

## Honest meta-disclaimer

The 2025–2026 multi-agent review literature citations (anchoring bias, ensembling > debate, confirmation bias in LLM code review, sparsification) come from prior consultant analyses. I (the agent that implemented this) have a January 2026 knowledge cutoff and cannot independently verify specific paper-by-paper claims. The directional claims are consistent with the literature I do know; the specific arXiv IDs were provided by external consultants. Design decisions in `docs/specs/second-opinion-v1.6.0-spec.md` rest on directions, not paper-by-paper. If a citation is hallucinated, the design still stands.
