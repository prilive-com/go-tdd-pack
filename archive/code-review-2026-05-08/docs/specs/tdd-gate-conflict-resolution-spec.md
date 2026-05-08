# TDD Gate Conflict Resolution — Implementation Spec

**Status:** Approved (synthesized from developer report + 2 consultant reviews + my own analysis)
**Date:** 2026-05-05
**Trigger:** Real-trial deadlock on `pre-oauth-hardening-04052026` cycle in a downstream project consuming `go-claude-starter` v1.3.1 + `feature/second-opinion`
**Scope:** Full 4-marker redesign with backwards-compat alias period. One PR. No layered shipment.

---

## 1. Decision

**Adopt 4-marker design (Interpretation B from the developer's memo)** with disciplined migration:

| # | Marker | Meaning | Set when |
|---|---|---|---|
| 1 | `Human approved spec: yes` | Operator reviewed and approved the written plan | After operator says `APPROVED SPEC` (or `APPROVED` at gate 1) |
| 2 | `Red phase confirmed: yes` | Failing tests exist + verbatim red proof captured | After `.tdd/red-proof.md` is on disk and tests run RED |
| 3 | `Green phase authorized: yes` | Operator authorized writing the implementation | After operator says `APPROVED GREEN` (or `APPROVED` at gate 2) |
| 4 | `Implementation reviewed: yes` (NEW) | Operator reviewed the green diff + tests + adjudication | After operator says `APPROVED IMPLEMENTATION` (or `APPROVED` at gate 3) |

**Two enforcement points:**

| Hook (matcher) | Requires | Why |
|---|---|---|
| `require-tdd-state.sh` (Edit/Write/MultiEdit on Tier 1 production) + `require-second-opinion.sh` Tier 1 leg | M1 + M2 + M3 | "May I write production code?" |
| `gate-tier1-commit.sh` (Bash matching `git commit`/`git tag`/`git push`) | M1 + M2 + M3 + M4 + fresh second-opinion adjudication | "May I close the cycle?" |

**Phase-aware test-file policy:** test files are NOT always exempt. They are allowed before red is confirmed, denied after. Aligns with the documented "don't edit tests in green phase" rule.

**Distinct operator commands:** `APPROVED SPEC` / `APPROVED GREEN` / `APPROVED IMPLEMENTATION`. Plain `APPROVED` is still accepted with context inference (the model picks based on which marker is the next pending one), so existing operator habit doesn't break.

**Backwards compatibility:** the old marker name `Human approved implementation: yes` is treated as an alias for `Green phase authorized: yes` for one minor version, with a stderr deprecation warning when the old name is seen. Drop the alias in the next major.

---

## 2. Why this design — synthesis of three reviews

### 2.1 Where Consultant A (4-marker) is right
- **Audit-semantic precision matters.** Setting `Human approved implementation: yes` BEFORE the implementation exists is a misleading audit claim. For governance-heavy code (the cycle that triggered this involves OAuth, RBAC, audit chain-of-custody), the distinction between "authorized to write" and "reviewed after writing" is genuinely load-bearing.
- **Test-file policy is too broad.** `allow_test_file_edits_without_gate: true` directly contradicts the documented "don't edit tests in green phase" rule. The hook is structurally unable to enforce its own discipline. Phase-aware policy fixes this.
- **Distinct operator commands** remove the same ambiguity that produced this deadlock at the operator-language layer.
- **Commit-time gate** gives `git commit` mechanical enforcement of M4 review. Without this, "operator reads the diff before push" is politeness, not contract.

### 2.2 Where Consultant A is wrong (rejected from this spec)
- **Pre-green/post-green second-opinion split is over-engineering.** Two artifacts means two staleness windows and two ways to drift. The current single-artifact, freshness-bounded model works. Don't split.
- **Full state-machine reframe is too big** for this fix. Markers stay; phase-aware checking is the right middle ground.

### 2.3 Where Consultant B (minimal Interpretation A) is right
- **Migration cleanliness:** alias period, sed migration one-liner, smoke test that catches half-migrated plans.
- **"What APPROVED means at each gate"** doc structure is cleaner than scattered prose.
- **Honest framing:** the docs were behind the hook. The hook's contract is the enforced contract; documentation must describe what's enforced.
- **Single second-opinion artifact** stays.

### 2.4 Where Consultant B is wrong (rejected from this spec)
- **Claiming `/second-opinion diff` + operator-reads-the-diff is "at least as protective" as a third operator approval.** A second AI catches code-shape errors the human eyeball misses, but a human gate-3 catches scope creep, team-style mismatches, and "is this the right thing to ship?" judgment calls. They are complementary, not equivalent. Removing the post-impl gate is a real protection downgrade dressed as equivalence.
- **"RED APPROVED" escape hatch** is solving a smaller problem than the same problem solved by distinct APPROVED commands. Adopt the latter.
- **Optimizing for one-cycle volume** is the wrong default for a starter. The starter ships to many projects; some are audit-sensitive. Adding M4 is cheap once.

### 2.5 Where my earlier 3-layer spec was wrong (corrected here)
- **Phased rollout (A → B → C across three PRs) is fake-cautious.** Three PRs of churn, three sets of smoke tests, three doc passes for what should be one coherent change. Ship the full fix once.

### 2.6 What's adopted from each source

| Component | From | Rationale |
|---|---|---|
| 4-marker design (M1–M4) | Consultant A | Honest audit semantics |
| `gate-tier1-commit.sh` | Consultant A | Mechanical enforcement of M4 |
| Phase-aware test-file policy | Consultant A | Lets the hook enforce its documented rule |
| Distinct `APPROVED SPEC` / `GREEN` / `IMPLEMENTATION` | Consultant A | Operator-layer disambiguation |
| Plain `APPROVED` accepted with context inference | My synthesis | Backwards compat for existing operator habit |
| Backwards-compat alias on old M3 name + deprecation | Consultant B | Existing in-flight plans don't break |
| Single second-opinion artifact (NOT pre/post-green split) | Consultant B | Current freshness check is sufficient |
| Sed migration one-liner + dedicated migration script | Consultant B | Clean migration path for downstream consumers |
| One PR for full fix (NOT 3 layered PRs) | My correction | Fewer churn cycles, one coherent change |

---

## 3. The new state machine

```
S0 idle
  ↓
S1 spec_drafted          (.tdd/current-plan.md exists, M1=no)
  ↓ Operator: APPROVED SPEC (or APPROVED at gate 1)
  ↓ Model sets: M1=yes
S2 spec_approved         (M1=yes, M2=no)
  ↓ Model writes failing tests + .tdd/red-proof.md
  ↓ Model sets: M2=yes
S3 red_proof_recorded    (M1=yes, M2=yes, M3=no)
  ↓ Operator: APPROVED GREEN (or APPROVED at gate 2)
  ↓ Model sets: M3=yes
S4 green_authorized      (M1=yes, M2=yes, M3=yes, M4=no)
  ↓ Model writes production code; tests go green
  ↓ Model captures .tdd/green-proof.md
  ↓ Model runs /second-opinion diff (mandatory for Tier 1)
S5 green_implemented     (M1..M3 yes, M4=no, green-proof + adjudication on disk)
  ↓ Operator: APPROVED IMPLEMENTATION (or APPROVED at gate 3)
  ↓ Model sets: M4=yes
S6 implementation_reviewed (all four markers yes)
  ↓ git commit / git push allowed
S7 closed
```

**Two boundaries the hooks enforce:**
- **Edit-time boundary (S3 → S4):** `require-tdd-state.sh` and `require-second-opinion.sh` Tier 1 leg deny production edits unless M1+M2+M3 are all yes. This is what the deadlock hit; the marker rename makes the operator's authorization explicit rather than implicit.
- **Commit-time boundary (S5 → S6):** `gate-tier1-commit.sh` denies `git commit`/`tag`/`push` of Tier 1 changes unless M4 is yes AND `.tdd/green-proof.md` exists AND `.tdd/second-opinion-completed.md` is fresh.

**Forbidden states are unrepresentable through the hook contract:**
- M3 cannot be set before M2 (model self-discipline + smoke test).
- M4 cannot be set before green code is committed locally (requires green-proof.md to exist; documented).
- A Tier 1 commit without M4 → blocked at the commit hook.

---

## 4. Files changed

| File | Action |
|---|---|
| `.tdd/tdd-config.json` | required_markers → 4 entries; replace `allow_test_file_edits_without_gate` with `test_file_policy` object |
| `.tdd/templates/feature-plan.md` | 4-marker block (rename M3, add M4) |
| `.tdd/templates/bugfix-plan.md` | 4-marker block (rename M3, add M4) |
| `scripts/migrate-tdd-markers.sh` (NEW) | one-shot migration: rename old M3 in any in-flight plan, add M4 line as `no` |
| `.claude/hooks/require-tdd-state.sh` | check 4 markers (with M3 alias), phase-aware test-file policy |
| `.claude/hooks/require-second-opinion.sh` | Tier 1 leg checks M1+M2+M3 (with alias), not M4 |
| `.claude/hooks/gate-tier1-commit.sh` (NEW) | Bash matcher; require M4 + green-proof + fresh adjudication for Tier 1 commits |
| `.claude/settings.json` | Register new hook on PreToolUse Bash matcher |
| `.claude/rules/go-tdd.md` | Three-gate model, distinct APPROVED commands, marker contract, "what APPROVED means" section |
| `docs/process/tdd_workflow.md` | Align with go-tdd.md; update cycle steps to include gate 3 |
| `.claude/skills/go-tdd-feature/SKILL.md` | Operational steps include gate 3 |
| `.claude/skills/go-tdd-bugfix/SKILL.md` | Operational steps include gate 3 |
| `scripts/tdd-test-hooks.sh` | ~15 new tests for the full design |

---

## 5. Backwards compatibility

### 5.1 In-flight plans
Plans created before this change have `Human approved implementation: yes`. The hooks treat this as an alias for `Green phase authorized: yes` and emit a stderr deprecation warning. Plans without M4 (`Implementation reviewed: yes`) get past the edit-time hooks but fail at commit-time hooks until M4 is added.

Migration script: `scripts/migrate-tdd-markers.sh` renames the old marker and adds an M4 line set to `no`. Operators run it once per in-flight plan, then continue the cycle.

### 5.2 Operator approval verbiage
Plain `APPROVED` is still accepted. The model reads which marker is next-pending and applies the approval to that gate. Distinct commands (`APPROVED SPEC` / `APPROVED GREEN` / `APPROVED IMPLEMENTATION`) are recommended for clarity in audit-sensitive cycles.

### 5.3 Alias removal
The M3 alias is removed in the next major version. CHANGELOG carries a deprecation notice.

---

## 6. Resolution for the in-flight cycle

The developer's `pre-oauth-hardening-04052026` cycle has:
- M1 = yes, M2 = yes
- Old marker name `Human approved implementation: no`
- Red proof on disk, fresh second-opinion adjudication, ready for green

Steps to unblock after this PR merges:

1. Run `scripts/migrate-tdd-markers.sh` against `.tdd/current-plan.md`. The script:
   - Renames `Human approved implementation: no` → `Green phase authorized: no`
   - Appends `Implementation reviewed: no`
2. Operator says `APPROVED GREEN for pre-oauth-hardening-04052026`. (Plain `APPROVED` also works.)
3. Model sets M3 = yes.
4. Model applies Fix 1 (D-6-07 recordMutation migration) and Fix 3 (TrimSpace empty-id reject).
5. Tests go green; race detector green; `.tdd/green-proof.md` written.
6. Model runs `/second-opinion diff` on the staged Tier 1 diff.
7. Operator reads the diff + adjudication. Says `APPROVED IMPLEMENTATION`. Model sets M4 = yes.
8. `git commit` allowed by `gate-tier1-commit.sh`.

Total operator interactions: 3 (gate 1 already done; gates 2 and 3 to come). No bypass. No self-approval. Audit trail is honest.

---

## 7. Acceptance criteria

### 7.1 Marker rename + M4
- [ ] `.tdd/tdd-config.json` carries `Green phase authorized: yes` and `Implementation reviewed: yes` in `required_markers`
- [ ] Plan templates carry the 4-marker block
- [ ] `require-tdd-state.sh` accepts both old and new M3 name; emits stderr deprecation when old is used
- [ ] `require-second-opinion.sh` Tier 1 leg checks the 3 edit-time markers (NOT M4)

### 7.2 New commit gate
- [ ] `gate-tier1-commit.sh` denies `git commit` / `git tag` / `git push` on Tier 1 cycle without M4
- [ ] Allows non-Tier-1 commits regardless of markers
- [ ] Allows `red(<id>)` and `refactor(<id>)` style commits per their phases (red doesn't need M4; refactor does)
- [ ] Requires `.tdd/green-proof.md` + fresh `.tdd/second-opinion-completed.md` (mtime <60min) before allowing the green commit
- [ ] False-positive guard: command containing literal text "git commit" in a comment passes

### 7.3 Phase-aware test policy
- [ ] `_test.go` edit before any plan exists → allow
- [ ] `_test.go` edit after M1 yes, M2 no → allow
- [ ] `_test.go` edit after M2 yes (red confirmed) → deny with "test edits forbidden after red phase"
- [ ] Config knob `test_file_policy.allow_after_red_confirmed: true` overrides for emergencies (off by default)

### 7.4 Operator commands
- [ ] Documentation explains distinct commands
- [ ] Plain `APPROVED` still works with context inference
- [ ] Skills updated to use distinct commands in their templates

### 7.5 Migration
- [ ] `scripts/migrate-tdd-markers.sh` exists, executable, idempotent
- [ ] Smoke test verifies migration script on a synthetic old-format plan
- [ ] Smoke test verifies that an unmigrated plan with old marker gets the deprecation warning but is allowed

### 7.6 Smoke tests
- [ ] All existing tests pass
- [ ] ~15 new tests for the full design pass
- [ ] Total ~58 passing

---

## 8. Future direction (out of scope)

A v2 redesign could replace markers with a phase state machine + append-only audit log:

```yaml
cycle_id: pre-oauth-hardening-04052026
tier: 1
phase: green_authorized
phase_log:
  - phase: spec_drafted
    entered_at: 2026-05-04T10:00:00Z
    exited_at: 2026-05-04T11:30:00Z
    operator_decision: APPROVED SPEC
  - ...
```

Benefits: forbidden states unrepresentable by construction; audit trail in the file; simpler hook code. Costs: major version bump, full migration. Adopt if marker-based design shows additional drift in practice.
