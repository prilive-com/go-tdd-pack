# /second-opinion v1.6.0 — Anchoring-Resistant Review Spec

**Status:** Proposed
**Date:** 2026-05-08
**Trigger:** Consultant push-back on my v1.5.x analysis surfaced empirical evidence I had under-weighted; combined with parasitoid trial gaps not addressed by either consultant.
**Synthesized from:** Claude (this assistant) + 2nd consultant review + literature direction (2025–2026)
**Branch:** `feature/second-opinion`
**Predecessor:** v1.5.2 (4-marker TDD gate + integration guards)

---

## 0. TL;DR

v1.6.0 closes the **anchoring** failure mode in cross-model code review without breaking the load-bearing single-pass design.

Six adopted changes (three from consultant, three from parasitoid trial gaps):

| # | Change | Source | Effort |
|---|---|---|---|
| 1 | **Pass A blind independent design** for Tier 1 | Consultant | ~30 min |
| 2 | **Concern Disposition Matrix** replaces free-form rebuttal | Consultant | ~30 min |
| 3 | **Research-packet artifact** for Tier 1 plans | Consultant | ~20 min |
| 4 | **Codex prompt invites codebase grep** for cross-file consistency | Mine (Gap 1) | ~10 min |
| 5 | **Closure check** — diff-review prompt includes prior matrix | Mine (Gap 4) | ~10 min |
| 6 | **Patterns pre-pass** before per-finding adjudication | Mine (Gap 3) | ~10 min |

Six rejected changes (ship neither in v1.6.0 nor later without new evidence):

| Rejected | Why |
|---|---|
| Round 3 / counter-review | Literature is unambiguous — round 3+ amplifies sycophancy/convergence |
| 8-state machine | Over-engineering for Tier 1 cycle volume |
| 4th marker (`Deep review reconciled: yes`) | Disposition matrix existence gates Pass A; no new marker needed |
| 3-tier classifier (Level 1/2/3) | Parallel to the existing Tier system; redundant |
| Role-theater subagents (primary-architect / reconciler / final-spec-author) | Same model with different prompts; no independent signal |
| General internet research as default review step | Latency + hallucination > value for Go code review |

**File delta:** 3 new templates, 3 edited files, no new hooks, no new agents, no new markers. Total ~2 hours of implementation, ~5 new smoke tests.

**Cost impact:** +60–90s and ~+5–7k tokens per Tier 1 cycle (Pass A only). Non-Tier-1 cycles unchanged. Within current cost envelope.

**Critical:** ship behind a feature flag, run the eval harness against v1.5.2 on the same 30-fixture set, drop Pass A if it doesn't catch more defects than v1.5.2 baseline. Pass A is empirically motivated but unproven for parasitoid-class cycles.

---

## 1. The problem v1.6.0 addresses

### 1.1 Anchoring bias in single-pass review

The v1.5.x design has Codex review Claude's plan/diff in a single pass. Codex's response is anchored on Claude's framing. When Claude's plan presents a confident solution, Codex's review tends to validate that solution rather than challenge its premises.

The 2025–2026 literature (anchoring in AI peer review, confirmation bias in LLM code review, ensembling vs. debate findings) converges on a structural lesson: **independent generation captures different blind spots; review-after-exposure-to-framing erodes them.** This is not the same as iterative debate (which has its own well-documented sycophancy problem). It is a separate failure mode upstream of debate.

The v1.5.x design closes the iterative-debate failure (single-pass, no Round 2). It does NOT close the anchoring failure (Codex sees Claude's plan as input).

### 1.2 The parasitoid trial integration-bug class

Three real bugs slipped through `/second-opinion` in the parasitoid trial:
- `orderLinkId` (camelCase) vs `order_link_id` (snake_case) cross-module mismatch
- `GenerateGridOrderLinkId` helper exists but only called for bear grid; spot grid passes empty string
- `strategy_orchestrator.go` calls `ExchangeService.PlaceOrder` directly, bypassing the new `IntentTracker`

All three are visible from a wide-angle codebase read. None are visible from the diff/plan that the current prompt feeds to Codex.

### 1.3 Lossy adjudication

The current adjudication artifact records per-finding decisions (ACCEPT / PARTIAL / REJECT / PUSHBACK) with discipline markers for P0 ACCEPT and PARTIAL. It does not enforce structure for P1/P2 REJECTs (which can hide without explicit reason), and it does not check at COMMIT time that the implementation actually addressed the ACCEPTED findings.

---

## 2. Design

### 2.1 Pass A — blind independent design (Tier 1 only)

**What it is:** Codex generates its own independent design for the same problem statement BEFORE seeing Claude's plan. Output goes to `.tdd/codex/independent-design.md`.

**Why it works:** Independent generation is the structural equivalent of ensembling. The reviewer's reference is its OWN solution, not the proposer's framing. Anchoring bias is reduced because there is no anchor to bias toward at the moment of independent generation.

**What it is not:** A second round of debate. Pass A happens BEFORE Pass B, not as a response to Pass B. The reviewer never sees an exchange — it generates its own design once, then critiques the proposed plan once.

**Implementation shape:**

```bash
# Pass A — independent generation. Codex sees:
#   - The original problem statement (from .tdd/current-plan.md "Problem" section)
#   - Constraints (from "Constraints" section, if present)
#   - The research packet (.tdd/research-packet.md)
#   - NO Claude plan, NO Claude rationale, NO Claude code

prompt_A="$(cat <<EOF
You are an external technical reviewer for a Go codebase.

Generate your own independent design for the following problem. Do NOT
look for a proposed solution; there is none in this prompt. Your output
is your reference for a later comparison review.

PROBLEM:
$(extract_problem_section .tdd/current-plan.md)

CONSTRAINTS:
$(extract_constraints_section .tdd/current-plan.md)

RESEARCH PACKET (what the implementer consulted):
$(red_full < .tdd/research-packet.md)

OUTPUT — your own design as Markdown:
- Goals (3 sentences)
- Approach (3-5 sentences)
- Key decisions (with reasoning)
- Trade-offs (what you'd accept and what you'd reject)
- Test strategy
EOF
)"

session_id="$(codex exec -m "$model" -s read-only ... --ephemeral - <<<"$prompt_A" \
  | tee .tdd/codex/independent-design.md \
  | extract_session_id)"

# Pass B — comparison review. Codex resumes the SAME session (so its
# independent design stays in context as anchor) and now receives Claude's
# plan plus existing prompt content.
prompt_B="$(cat <<EOF
You have written your own design above. Now compare it to the
implementer's plan below. Where do they diverge? Which divergences
matter? Which divergences are stylistic and don't matter?

[existing v1.5.x prompt content: anti-sycophancy, severity rubric,
 JSON output format]

IMPLEMENTER'S PLAN:
$(red_full < .tdd/current-plan.md)
EOF
)"

codex exec resume "$session_id" - <<<"$prompt_B" > .tdd/codex/round1.json
```

**Single Codex session** for both passes. Pass A's output stays in Codex's context for Pass B. Cost stays bounded (Pass A's tokens are cached for Pass B); reference for review is Codex's OWN design, not Claude's plan.

**Tier 1 only.** Non-Tier-1 cycles use the v1.5.x single-pass flow unchanged. Reasoning: Pass A's value-per-cost ratio justifies the +60s latency for security/money/auth/migration paths, not for routine cycles.

### 2.2 Concern Disposition Matrix

**What it is:** A structured table replacing the free-form rebuttal artifact. Every Codex finding gets a row; every row has a mandatory Disposition column.

**Why it's sharper than v1.5.x:**
- Mandatory disposition for EVERY finding, not just P0 ACCEPT and PARTIAL (closes the slot where P1/P2 REJECTs hide without explicit reason).
- Explicit "Spec change" column forces commitment to action, not just rationale.
- Row-per-finding count is mechanically checkable against the Codex JSON output (smoke test enforces 1:1 mapping).

**Format:**

```markdown
# Concern Disposition Matrix
date: <ISO timestamp>
cycle_id: <slug>
findings_total: <N>
codex_session: <session-id>
codex_model: <model name>

| ID | Source | Severity | Concern (1 line) | Disposition | Reason | Spec change |
|----|--------|----------|------------------|-------------|--------|-------------|
| F1 | Codex  | P0       | ...              | ACCEPT      | ...    | yes         |
| F2 | Codex  | P1       | ...              | PARTIAL     | ...    | partial     |
| F3 | Codex  | P2       | ...              | REJECT      | ...    | no          |
| F4 | Codex  | P3       | ...              | ACCEPT      | ...    | yes         |
```

Disposition values: `ACCEPT | PARTIAL | REJECT | PUSHBACK`.

**PARTIAL discipline** (carried forward from v1.5.1): the "Reason" column for any PARTIAL row must contain the three sub-sections inline:

```
What I am accepting: <concrete change>
What I am rejecting: <concrete claim — NOT "nothing"/"n/a"/"none"/blank>
Why this split is correct: <≥2 sentences>
```

**P0 ACCEPT discipline** (carried forward from v1.5.0): the "Reason" column for any P0 ACCEPT row must contain the literal phrase `Why this is correct:` followed by ≥3 sentences.

**Smoke test:**
- Count rows in matrix; count finding IDs in Codex JSON; assert equality.
- For each PARTIAL row, verify all three sub-sections present and non-empty.
- For each P0 ACCEPT row, verify `Why this is correct:` marker.

**File:** `.tdd/codex/disposition-matrix.md`. Replaces v1.5.x's free-form rebuttal area.

### 2.3 Research-packet artifact (Tier 1 plans)

**What it is:** A short structured document Claude writes BEFORE the plan, listing what it consulted to write the plan.

**Why it matters:**
- Anchors Pass A and Pass B against the same evidence Claude consulted.
- Codex can see whether Claude's research was thin or solid; thin research → harsher review.
- Forces Claude to commit to the sources of its design choices, surfacing uncertainty.

**Format:**

```markdown
# Research packet — <cycle-id>
date: <ISO timestamp>

## Question
<the open question(s) the plan addresses>

## Sources
<≥3 authoritative sources, with URL/file path for each>

## Findings
<what each source said; one paragraph per source>

## Impact on the plan
<how each finding shaped the plan; cite plan sections>

## Uncertainty
<what's still unknown; what assumptions the plan makes>
```

**File:** `.tdd/research-packet.md`.

**Required for Tier 1 plans only.** Non-Tier-1 cycles can skip. The hook (see §3) checks for the file's existence and section completeness on Tier 1 cycles.

**Codex receives the packet** as context in both Pass A and Pass B prompts.

### 2.4 Codex prompt invites codebase grep (Gap 1 from parasitoid trial)

**What changes:** The plan-review prompt gains explicit invitation to use Codex's read-only tool access to grep the rest of the codebase before reviewing.

**Why it matters:** Three of the parasitoid trial's slip-throughs were cross-file integration assumptions (orderLinkId case, spot-grid empty key, orchestrator bypass). All visible from a wide-angle codebase read. Pass A produces an independent DESIGN; codebase grep checks the design's assumptions against existing code. Pass A and codebase grep are complementary, not redundant.

**Prompt addition (Pass B):**

```
You have read-only access to the rest of the codebase via standard Unix
tools (grep, find, cat). Before writing your final review:

1. Identify the public surface this plan newly depends on (interfaces
   newly implemented, public functions newly called from outside the
   plan's files).
2. For each, grep the rest of the codebase for cross-file consistency:
   - Are all writers and readers of any new map key / metadata field
     using the same string literal?
   - Does the new code's API match what existing call sites expect?
   - Are there sanctioned-wrapper invariants the new code assumes
     ("only X may call Y")? If so, grep for direct Y calls outside X.
3. Findings from this audit get severity P0/P1 if they would silently
   fail in production. Tag location: file:line.
```

**No new tooling.** Codex `--sandbox read-only` already grants this access. The change is in the prompt only.

### 2.5 Closure check on Tier 1 commit (Gap 4)

**What changes:** The diff-review pass at commit time receives the prior plan-review's Disposition Matrix as context, with explicit instruction to verify each ACCEPTED finding has been addressed.

**Why it matters:** Today, `gate-tier1-commit.sh` requires a fresh `/second-opinion diff` adjudication. The diff-review prompt is generic ("review this diff"). It doesn't check that the diff resolved the prior matrix's ACCEPTED findings. A finding can be accepted at plan time and silently dropped during implementation; the current flow doesn't catch this.

**Prompt addition (diff-review):**

```
PRIOR PLAN REVIEW DISPOSITION:
$(cat .tdd/codex/disposition-matrix.md)

Your task includes verifying that each ACCEPTED finding in the prior
matrix has been addressed in this diff. For each row with Disposition =
ACCEPT or PARTIAL:
- Was the spec change actually implemented?
- If yes, locate the implementation in this diff (file:line).
- If no, raise a P1 finding: "Plan-review finding F<N> was accepted but
  not implemented."
```

**Smoke test:** synthetic fixture with matrix listing F1 ACCEPT but diff not addressing it; expect a P1 finding for the dropped finding.

### 2.6 Patterns pre-pass before per-finding adjudication

**What changes:** Before Claude writes the disposition matrix row-by-row, an optional one-paragraph "patterns" preamble surfaces cross-cutting observations across findings.

**Why it matters:** Three findings about error handling might mean "your error-handling style is wrong" — a single deeper conclusion the per-finding adjudication misses. The per-finding loop pulls Claude into local decisions; the pre-pass keeps the global view.

**Format addition** (top of `disposition-matrix.md`):

```markdown
## Cross-cutting observations

<0-3 sentences. Empty if no cross-cutting pattern. Examples:
- "Three findings (F2, F5, F7) point at error handling. Style change in
  cycle scope: stop wrapping errors with %w in lib code; use sentinel
  errors instead. Affects F2/F5/F7 simultaneously."
- "Two findings (F1, F4) are about the same goroutine spawn. Single fix
  in plan resolves both.">
```

**Optional.** If Claude writes nothing, the section says "No cross-cutting patterns." No discipline check; this is a hint, not an enforcement.

---

## 3. Hook changes

### 3.1 `require-second-opinion.sh` — Tier 1 leg additions

For Tier 1 paths only, the hook additionally requires:

1. `.tdd/research-packet.md` exists, is non-empty, has ≥3 source entries (count `^- ` or `^1.` items in the Sources section).
2. `.tdd/codex/independent-design.md` exists (Pass A artifact). Mtime within 60 minutes (same freshness window as adjudication).
3. `.tdd/codex/disposition-matrix.md` row count == finding count in `.tdd/codex/round1.json` (mechanical 1:1 check).

**No new marker** in `.tdd/current-plan.md`. The disposition matrix's existence + row-count check IS the gating mechanism — there is no way to have a complete matrix without Pass B having run and Pass A having anchored it.

The 4-marker model from v1.5.2 is unchanged: M1 (spec), M2 (red), M3 (green-authorized), M4 (impl-reviewed).

### 3.2 `gate-tier1-commit.sh` — closure check addition

The existing commit-gate already requires fresh `/second-opinion diff` adjudication. v1.6.0 adds: the diff-review prompt template includes the prior matrix as context. The hook itself doesn't change; the prompt template inside SKILL.md does.

### 3.3 No new hooks

`require-tdd-state.sh`, `require-second-opinion.sh`, `gate-tier1-commit.sh` cover all the gates. v1.6.0 does not add a hook.

---

## 4. Files

### 4.1 Add (3 templates)

```
.tdd/templates/research-packet-template.md
.tdd/codex/independent-design.template.md
.tdd/codex/disposition-matrix.template.md
```

The runtime artifacts (`.tdd/research-packet.md`, `.tdd/codex/independent-design.md`, `.tdd/codex/disposition-matrix.md`) are created per-cycle, gitignored.

### 4.2 Edit (3 files)

```
.claude/skills/second-opinion/SKILL.md
  + Pass A logic (Tier 1 branch)
  + Codex prompt: codebase grep invitation (in Pass B)
  + Disposition matrix template + write step
  + Diff-review prompt: closure check on prior matrix
  + Patterns pre-pass section in adjudication template

.claude/rules/go-tdd.md
  + Document Pass A, research packet, disposition matrix as Tier 1 requirements
  + Update "two gates" framing if not yet caught up to 4-marker model

scripts/tdd-test-hooks.sh
  + ~5 new smoke fixtures
```

### 4.3 No new

No new hooks. No new agents. No new markers. No new top-level config knobs.

---

## 5. Cost and latency

| Stage | v1.5.2 (current) | v1.6.0 | Delta |
|---|---|---|---|
| Codex Pass A (Tier 1, NEW) | — | 30–60s, ~3–5k tokens | +60s, +5k tokens |
| Codex Pass B (formerly Round 1) | 25–70s, ~4–7k tokens | 30–90s, ~6–9k tokens | +20s, +2k tokens |
| Round 2 | 15–45s | 15–45s | 0 |
| Diff-review (closure check) | same | same + matrix in prompt | +200 tokens |

**Per Tier 1 cycle:** ~+90s and ~+7k tokens. Within ChatGPT-Pro plan headroom; ~$0.10 extra on direct API billing.

**Per non-Tier-1 cycle:** unchanged.

This is the right cost/quality tradeoff because Tier 1 is exactly where confirmation bias matters most.

---

## 6. Acceptance criteria

| Item | Verification |
|---|---|
| Pass A produces `independent-design.md` before Pass B for Tier 1 | Smoke fixture: Tier 1 Edit denied if file missing |
| Pass A and Pass B share a Codex session | Manual: trace `codex exec resume <id>` is used |
| Disposition matrix row count == finding count | Smoke: jq count on round1.json vs row count |
| PARTIAL rows have all three sub-sections | Existing v1.5.1 smoke test extended to matrix format |
| P0 ACCEPT rows have `Why this is correct:` marker | Existing v1.5.0 smoke test extended to matrix format |
| Research packet has ≥3 sources for Tier 1 | Smoke: Tier 1 Edit denied if section count <3 |
| Codex prompt invites codebase grep | Manual: prompt contains the invitation block |
| Diff-review prompt includes prior matrix | Manual: SKILL.md generates prompt with matrix included |
| Non-Tier-1 cycles unchanged | Existing smoke tests pass; no Pass A artifact required |
| All v1.5.2 smoke tests still pass | 68 → 73+ (5 new) |

---

## 7. Migration

### 7.1 In-flight cycles

Cycles in progress at v1.6.0 release time:
- **Pre-Tier-1 phases (spec, red):** affected. Operator should stop, write the research packet, restart Tier 1 cycle to pick up Pass A.
- **Mid-green-phase Tier 1:** unaffected this cycle. Disposition matrix produced from existing rebuttal text via one-shot conversion (provide `scripts/migrate-rebuttal-to-matrix.sh`).
- **Non-Tier-1:** unaffected.

### 7.2 Rollback

Tag `v1.5.2-stable` BEFORE merging v1.6.0 to main. Rollback path: revert the v1.6.0 commit. Existing v1.5.2 artifacts (free-form rebuttal) remain valid.

### 7.3 Feature flag

Ship Pass A behind `SECOND_OPINION_PASS_A_DISABLE=1` env var for the first two weeks. Operators who hit friction can opt out per-cycle without rolling back the whole release.

---

## 8. Validation plan (the load-bearing decision)

**Pass A is empirically motivated but unproven for this codebase.** The literature supports anchoring-resistance via independent generation; whether Pass A catches more *real defects* than v1.5.2 on parasitoid-class cycles is a hypothesis until measured.

### 8.1 Eval harness

Run on the same 30-fixture set used to validate v1.5.x:
- 30 historical Tier 1 plans from real cycles
- Known seeded defects (defect-injection set)
- Compare Pass A output against v1.5.2 baseline

**Pass criterion:** Pass A catches ≥1 additional real defect per 10 fixtures vs. baseline, AND adds ≤1 false positive per 10 fixtures.

If Pass A clears the bar: keep, ship to all Tier 1 cycles.

If Pass A fails the bar: drop Pass A; keep the disposition matrix + research packet + closure check + codebase grep + patterns pre-pass (all 5 are independently motivated and don't depend on Pass A).

### 8.2 Two-week trial period

After v1.6.0 ships:
- Operators run real Tier 1 cycles with Pass A enabled.
- Track: latency, token cost, operator-perceived value (subjective rating), real defects caught that v1.5.2 missed.
- Decision review at end of week 2.

### 8.3 Definition of done for the spec itself

The spec is "done" when:
- All 6 adopted changes are implemented and pass acceptance criteria
- v1.5.2-stable tag exists for rollback
- Eval harness has been run at least once
- Operators have completed ≥3 real Tier 1 cycles under v1.6.0

---

## 9. Honest disclaimers

### 9.1 Pass A is the only unproven adoption

Five of the six adopted changes (matrix, packet, codebase grep, closure check, patterns pre-pass) are independently motivated:
- Disposition matrix sharpens the existing rebuttal artifact (mechanical improvement)
- Research packet improves spec-phase research discipline (independent of review)
- Codebase grep closes the parasitoid integration-bug class (real-trial evidence)
- Closure check enforces the implementation-vs-findings invariant (existing protocol gap)
- Patterns pre-pass is a low-cost prompt change (no new artifacts)

**Pass A is the only one whose value is hypothesis-until-measured.** The literature direction is favorable; the parasitoid-specific value is unproven. Treat it as the conditionally-shipped piece of v1.6.0. The other five ship regardless of Pass A's eval result.

### 9.2 Citations from the consultant's analysis

The consultant cited specific arXiv papers (2603.18740 security code review confirmation bias, 2406.12708 AgentReview anchoring, Choi et al. Aug 2025 ensembling > debate, NAACL 2025 sparsification). I (the spec author) have a January 2026 knowledge cutoff and cannot independently verify the specific findings paper-by-paper. I CAN verify the directions:
- Anchoring bias in AI peer review is well-documented in the literature I do know.
- Ensembling-over-debate is the consensus 2025 finding direction.
- Confirmation bias in LLM code review is established.
- Sparsification is an active 2025 research thread.

**Verdict:** the specific citations are plausible but unverified by me. The directional claims are consistent with the literature I know. The design decisions in this spec rest on directions, not specific paper claims, so the unverified specific citations don't undermine the spec.

### 9.3 What this spec does NOT solve

- **Cycle volume.** v1.6.0 adds ~+90s per Tier 1 cycle. If your Tier 1 cycle volume grows 10x, the cumulative latency cost will be felt. Sparsification (NAACL 2025 direction) is the answer to that — out of scope for v1.6.0, noted for v1.7+.
- **Codex auth fragility.** Pass A uses gpt-5.5 which needs ChatGPT auth. API-key users still hit the existing fallback to gpt-5.4. The fallback path now applies to Pass A AND Pass B; cost on API-key users degrades gracefully (same as v1.5.x).
- **Operator burden.** The research packet adds 5–10 minutes of writing per Tier 1 plan. Some operators will resist. The packet is required only for Tier 1 cycles (~handful per month per project) — burden is bounded but real.

---

## 10. Sequencing

1. **Day 0:** Write spec (this document). Tag `v1.5.2-stable` on main.
2. **Day 1:** Implement adopted changes in feature/second-opinion-v1.6.0 branch.
3. **Day 2–3:** Smoke tests + eval harness run.
4. **Day 4:** Ship to feature branch with Pass A behind feature flag.
5. **Days 5–18 (two weeks):** Real-cycle trial. Track metrics.
6. **Day 19:** Decision review. Keep/drop Pass A based on data.
7. **Day 20:** Merge to main if eval + trial green.

Total: ~3 weeks from spec to merge. Implementation is ~2 hours; the eval harness and trial period are the bulk.

---

## 11. Future direction (out of scope for v1.6.0)

- **Sparsification (NAACL 2025).** The current architecture is already sparse (one Codex session, two passes max). v1.7+ could explore: omitting Pass A for paths where Codex has high training coverage; agent-pair selection based on cycle type. Note in MAINTAINING.md so future maintainers don't drift toward more agents/rounds.
- **CVE-data integration.** For Tier 1 security paths (auth, crypto, session), pipe `govulncheck` output into Pass A's research packet automatically. Bounded latency, structured output, no hallucination risk. v1.7 candidate.
- **Multi-model ensemble.** Adding a third reviewer (e.g., a different Codex model or Gemini) is the obvious extension if Pass A's eval shows that two-model anchoring-resistance is insufficient. Costly; only consider if eval data motivates it.

---

## 12. References (literature direction, not specific citations)

The design decisions in this spec rest on the following research directions, all consistent with 2025–2026 literature:

- **Anchoring bias in AI peer review:** reviewers exposed to a proposal first weight initial impressions heavily; rebuttals barely move them.
- **Confirmation bias in LLM code review:** adversarial framing succeeds against current code-review LLMs at high rates.
- **Ensembling > debate:** most performance gains in multi-agent debate protocols are attributable to ensembling (independent generation + aggregation), not debate rounds. Debate-round gains are minimal absent explicit corrective interventions.
- **Sparsification:** limiting which agents see which outputs reduces tokens substantially with minimal accuracy loss.

The consultant's specific paper citations (arXiv 2603.18740, 2406.12708, Choi et al. Aug 2025, NAACL 2025) instantiate these directions. The spec's design decisions stand on the directions, not paper-by-paper.
