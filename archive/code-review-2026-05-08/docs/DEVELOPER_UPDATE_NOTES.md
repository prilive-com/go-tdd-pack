# Developer update notes — go-claude-starter

**Date:** 2026-05-08
**Branch:** `feature/second-opinion`
**Updates from:** main (v1.3.1)
**Safety:** all changes are backwards-compatible. Updating does not break existing cycles. New behaviors are opt-in via config flags or run only when their preconditions are met.

---

## TL;DR

You can update safely today. Defaults preserve the v1.3.1 behavior you already have. New features activate when you flip flags or invoke new artifacts. **No mandatory action.**

Three new things you can use right away:
1. **Mandatory `/second-opinion` enforcement** — automatic; replaces the soft skill auto-invocation that was being bypassed
2. **Integration guards** — opt-in regex patterns that block bad commits at the commit gate
3. **TDD gate redesign** — fixes the documented-vs-actual workflow conflict; old marker name still works via alias

One new thing **you should NOT use yet without testing**:
- **Pass A blind independent design** (v1.6.0) — empirically motivated, mechanism validated on one synthetic scenario, codebase-specific value still unproven for your projects. Keep the flag off until you do your own validation.

---

## What changed

### Group 1 — Safety hardening (already active by default)

These fixes activate automatically when you update. They do not require config changes and they catch real bugs.

| Change | What it does | Why it ships on |
|---|---|---|
| `require-second-opinion.sh` hook | Denies Tier 1 production edits unless a fresh `/second-opinion` adjudication exists | The soft skill was being bypassed in real cycles; mechanical enforcement closes the loop |
| `guard-bash-pipefail.sh` hook | Denies piped Go-tool commands without `set -o pipefail` (e.g., `go build \| head` masking exit code) | Caught a real verification bug in trial use |
| Redact-patterns hardening | Comment lines in `.claude/redact-patterns.txt` no longer crash the redactor; invalid regex is logged + skipped (not silent failure) | Trial showed silent diff-emptying causing `/second-opinion` to bill for empty reviews |
| Pre-Codex packet validation | Skill skips with diagnostic instead of sending empty TARGET to Codex | Same root cause as above; defense in depth |
| PARTIAL discipline check | `/second-opinion` adjudication denies any PARTIAL stance with empty `rejected:` field (anti-patterns: `nothing`/`n/a`/`none`/blank) | Closes the sycophancy-theatre slot where label drift hides |
| YAML CI fix | `.gitlab-ci.yml` agents-md-sync job now parses correctly | Pre-existing bug surfaced by the first MR pipeline run |

**Adoption:** nothing for you to do. These activate on update.

### Group 2 — TDD gate redesign (deals with a real documented conflict)

The earlier "two gates" model in the docs conflicted with what the hook actually enforced. Marker 3 was named "Human approved implementation" but used as "Green phase authorized" — operators hit deadlock at the boundary.

| Change | What it does |
|---|---|
| Marker M3 renamed | `Human approved implementation: yes` → `Green phase authorized: yes` (old name still works via alias for one minor version) |
| New marker M4 | `Implementation reviewed: yes` (gates the green commit) |
| New hook `gate-tier1-commit.sh` | Denies Tier 1 commits without M4 + green-proof + fresh adjudication |
| Phase-aware test policy | `_test.go` edits in a Tier 1 path are now denied AFTER `Red phase confirmed: yes` (the documented "no editing tests in green phase" rule, finally enforced) |
| Distinct operator commands | `APPROVED SPEC` / `APPROVED GREEN` / `APPROVED IMPLEMENTATION` (plain `APPROVED` still works with context inference) |
| Migration script | `scripts/migrate-tdd-markers.sh` renames M3 + adds M4 in any in-flight plan |

**Adoption:**
- Run `bash scripts/migrate-tdd-markers.sh` once per project to update any in-flight plan files.
- New cycles use the renamed markers automatically (templates updated).
- Old marker name still satisfies the gate for one minor version (you'll see a stderr deprecation warning).

### Group 3 — Integration guards (opt-in)

After parasitoid trial caught 3 P0/P1 cross-module integration bugs that plan-review missed (camelCase vs snake_case key mismatch, helper-only-called-on-one-path, direct API call bypassing new wrapper), we added a regex-based check at commit time.

| Change | What it does |
|---|---|
| `integration_guards` array in `.tdd/tdd-config.json` | Per-project list of "no API X outside file Y" invariants |
| `gate-tier1-commit.sh` extended | Greps repo against guards on Tier 1 commits; denies on violation outside `allowed_globs` |
| `.claude/rules/go-integration-guards.md` | Decision tree: write integration tests first, type safety second, guard third (guards are FALLBACK) |

**Adoption:**
- Default array is empty (no guards). Update is safe.
- Add guards as you find bugs that grep could have caught. Each guard should link to the bug it would have caught.
- See `.claude/rules/go-integration-guards.md` for the schema and when to use what.

### Group 4 — /second-opinion v1.6.0 (anchoring-resistant review, opt-in)

The single biggest change. The mechanism resists confirmation bias by making Codex generate its OWN design BEFORE seeing Claude's plan, then comparing. Three new artifacts; three opt-in flags.

| Change | What it does |
|---|---|
| Pass A blind independent design | For Tier 1 plans, Codex generates its own design before reviewing Claude's. Anchor for the comparison review. |
| Concern Disposition Matrix | Replaces v1.5.x free-form rebuttal text. Every Codex finding gets a row with mandatory Disposition column. |
| Research packet | Required for Tier 1 plans (when flag on). ≥3 authoritative sources. Anchors Codex's review on the same evidence Claude consulted. |
| Codebase grep invitation | Codex prompt now explicitly invites read-only grep of the rest of the codebase (closes the parasitoid integration-bug class) |
| Closure check | `/second-opinion diff` prompt now includes the prior plan-review matrix; verifies each ACCEPTED finding was actually implemented |
| Patterns pre-pass | Adjudication template gains a "cross-cutting observations" section before per-finding decisions |
| Most-powerful Codex by default | Both tiers default to `gpt-5.5`. Per-project config in `.tdd/tdd-config.json` `second_opinion.model_default`. Env vars override. |

**Adoption:** see "Recommended adoption sequence" below.

### Group 5 — Trial-feedback fixes from earlier rounds

These are smaller but worth knowing about:

- `/second-opinion` skill broadened from Tier-1-only to all non-trivial changes (fast model for non-Tier-1, deep model for Tier 1)
- `Redact-patterns.txt.example` template clarifies the comment syntax
- Anti-deference rules expanded with the sycophancy-theatre + deference-theatre vocabulary
- `MAINTAINING.md` documents the trial-feedback loop and design choices

---

## How to update

```bash
cd your-project
git fetch <starter-remote> feature/second-opinion
git merge --no-ff <starter-remote>/feature/second-opinion
# Or, if you copied the pack: cp -r ../starter-pack/.claude .claude && cp -r ../starter-pack/.tdd .tdd && cp -r ../starter-pack/scripts scripts && cp -r ../starter-pack/docs docs
```

Then, one-time per project:

```bash
# 1. Migrate any in-flight TDD plans (renames M3, adds M4).
bash scripts/migrate-tdd-markers.sh

# 2. (Optional) Migrate any in-flight v1.5.x adjudications to the matrix format.
bash scripts/migrate-rebuttal-to-matrix.sh

# 3. Verify hooks pass.
bash scripts/tdd-test-hooks.sh
# Expect: Results: 81 passed, 0 failed
```

Nothing else is required. Existing cycles continue working.

---

## Recommended adoption sequence

The matrix and packet flags can be flipped immediately. Pass A flag should wait until you have your own validation.

### Week 1 — flip the matrix flag

```json
"second_opinion": {
  "require_disposition_matrix_tier1": true
}
```

**Why first:** mechanical improvement (structured matrix > free-form text). Known mechanism. No LLM behavior change. Catches REJECTs that hide without explicit reason. Zero risk.

**Operator burden:** Claude writes a row per Codex finding instead of a paragraph. Slightly more structure; same total work.

### Week 2 — flip the research packet flag

```json
"second_opinion": {
  "require_research_packet_tier1": true
}
```

**Why second:** spec-phase discipline. No LLM behavior change. Forces operators to commit to ≥3 sources before writing the plan.

**Operator burden:** ~5–10 minutes per Tier 1 plan to write the packet. You'll feel this; it is the point.

**If your team resists:** the burden is real. Trade-off is whether the discipline is worth it for your codebase. Optional in our defaults; opinion-strong if you have audit-sensitive code (auth, payments, migrations).

### Later — flip the Pass A flag (after your own validation)

```json
"second_opinion": {
  "require_pass_a_tier1": true
}
```

**Why last:** Pass A's value is the only one that's empirically motivated but unproven for YOUR codebase. The literature direction is favorable; we validated the mechanism on one synthetic scenario; we have no data yet on whether Pass A catches more real defects than v1.5.2 already did on your specific cycles.

**Validation options:**

- **Quick (recommended first step):** flip the flag on your next Tier 1 cycle. See if Pass A's independent design catches anything you missed. If yes, flip it permanently. If no, keep flag off and revisit later.
- **Rigorous:** build the eval harness (~1 day) — run Pass A against historical cycles where you know what defects shipped. Measure catch rate vs v1.5.2 baseline.

**If you don't want Pass A at all:**

```bash
export SECOND_OPINION_PASS_A_DISABLE=1
```

Killswitch is per-shell. Add to your shell rc to disable globally.

---

## How `/second-opinion` works after the update

For non-Tier-1 cycles: same as v1.5.x. Single Codex pass, JSON findings, Claude adjudicates per-finding.

For Tier 1 cycles (when v1.6.0 flags are flipped on):

```
1. Operator writes spec → .tdd/current-plan.md
2. Operator writes research packet → .tdd/research-packet.md (≥3 sources)
3. Claude invokes /second-opinion plan
4. Skill runs Codex Pass A (blind, no Claude plan in context)
   → produces .tdd/codex/independent-design.md
5. Skill runs Codex Pass B (sees Pass A's design + Claude's plan)
   → produces JSON findings
6. Claude writes:
   .tdd/second-opinion-completed.md (operator-readable adjudication)
   .tdd/codex/disposition-matrix.md (one row per Codex finding)
7. Operator says APPROVED SPEC. Red phase begins.
8. ... red phase ...
9. Operator says APPROVED GREEN. Green phase begins.
10. Claude implements; tests go green; .tdd/green-proof.md captured
11. Claude invokes /second-opinion diff (closure check on prior matrix)
12. Operator says APPROVED IMPLEMENTATION. M4 marker set.
13. git commit allowed by gate-tier1-commit.sh (validates M4 + green-proof
    + fresh adjudication + integration guards)
```

This is the full Tier 1 ceremony. For lower-tier work, most of these steps are skipped automatically.

---

## Honest disclaimers

### What's proven and what isn't

| Improvement | Status |
|---|---|
| Mandatory `/second-opinion` enforcement | Caught real bypass attempts in trial. Proven. |
| Pipefail guard | Caught real `go build \| head` masking. Proven. |
| Redact-patterns hardening | Fixed actual silent-failure bug in trial. Proven. |
| PARTIAL discipline check | Catches real label drift. Mechanism proven; operator burden small. |
| TDD gate redesign | Resolved real deadlock. Proven on the deadlock case. |
| Integration guards | Mechanism proven; project-specific guard quality is your responsibility. |
| Disposition matrix | Mechanical improvement; no LLM behavior change. Safe. |
| Research packet | Spec-phase discipline; no LLM behavior change. Safe. |
| Codebase grep invitation | Closes parasitoid bug class; effectiveness depends on Codex's grep willingness in your repo. |
| Closure check | Mechanical; verifies findings → implementation. Safe. |
| **Pass A blind independent design** | **Mechanism validated on one synthetic scenario. Codebase-specific value unproven. Use the killswitch or the flag default until you've tested.** |

### Citations

The Pass A design rests on the 2025–2026 literature on multi-agent review (anchoring bias, ensembling > debate, confirmation bias in LLM code review). Specific paper citations were provided by external consultants. The directional claims are consistent with what we know; specific paper-by-paper citations are plausible but not all independently verified. The design rests on directions, not paper-by-paper.

### What we did NOT add

- No round-3 / counter-review (literature is unambiguous on the convergence/sycophancy risk of additional rounds)
- No multi-agent role-theater (separate "primary-architect" / "reconciler" / "final-spec-author" agents — same model with different prompts adds no independent signal)
- No general internet research integrated into reviews (latency + hallucination > value for code review specifically)
- No comprehensive separate "implementation spec" generated by Claude (the plan IS the spec; generating another doc creates drift)

---

## If you hit problems

### Update breaks an in-flight cycle

Run the migration scripts:
```bash
bash scripts/migrate-tdd-markers.sh
bash scripts/migrate-rebuttal-to-matrix.sh
```

If a hook denies an action and the deny message doesn't help, the hook's stderr output explains what's missing. The most common causes:
- Marker name old vs new (run migrate-tdd-markers.sh)
- Missing M4 (operator hasn't said APPROVED IMPLEMENTATION yet)
- Stale adjudication (>60min mtime — re-run `/second-opinion`)
- Missing green-proof.md (capture verbatim test output before committing green)

### Pass A is slow / produces bad output for your scenario

Three options:
1. Per-shell disable: `export SECOND_OPINION_PASS_A_DISABLE=1`
2. Per-project disable: keep `require_pass_a_tier1: false` in tdd-config.json (the default)
3. Tell us: open an issue with the symptom. Pass A is the conditionally-shipped piece; we'd rather drop it than have it produce noise.

### gpt-5.5 not available (API-key auth)

The skill auto-falls-back to `gpt-5.4` (the most powerful model API-key auth supports). Doctor.sh warns when it detects the mismatch. To pin a specific model permanently:

```json
"second_opinion": {
  "model_tier1": "gpt-5.4",
  "model_default": "gpt-5.4"
}
```

### CI / pipeline failures

If the GitLab pipeline fails on `agents-md-sync`, you have an old version of `.gitlab-ci.yml`. The fix is in commit `cc425d3`. Pull it in.

---

## Where to find more detail

| Topic | Document |
|---|---|
| TDD ceremony rules | `.claude/rules/go-tdd.md` |
| TDD gate redesign rationale | `docs/specs/tdd-gate-conflict-resolution-spec.md` |
| /second-opinion v1.6.0 design | `docs/specs/second-opinion-v1.6.0-spec.md` |
| Integration guards | `.claude/rules/go-integration-guards.md` |
| TDD workflow | `docs/process/tdd_workflow.md` |
| Hook smoke tests | `scripts/tdd-test-hooks.sh` (81 tests, run with `bash scripts/tdd-test-hooks.sh`) |
| Pack maintenance + design choices | `MAINTAINING.md` |

---

## Summary in one paragraph

Update is safe — defaults preserve v1.3.1 behavior. Run the two migration scripts once. Flip the disposition-matrix flag this week (low risk, immediate gain). Flip the research-packet flag next week if your team is willing to write packets. Keep the Pass A flag OFF until you've validated it on at least one of your own Tier 1 cycles (or until we build the eval harness — open an issue if you want it sooner). Pipefail / redact-patterns / PARTIAL discipline / mandatory-second-opinion / TDD gate redesign all activate automatically and have caught real bugs in trial use. If anything denies unexpectedly, read the stderr message — every deny includes the specific fix.
