# Proposal — FDTDD Stage 1 rails (Gate 1 + Gate 3)

> Status: **proposal — implementation-ready slice plan, with one
> marker-schema decision to lock before slice 2**.
> Author: maintainer (2026-06-08).
> Closes pending task #133.
> Slogan: **soft guidance for everyday work; hard rails for Tier-1.**

---

## 0. Origin and where FDTDD sits today

Finding-Driven TDD (FDTDD) is the maintainer's chosen pattern for
high-stakes code paths: every change to a Tier-1 path must be driven
by a written finding, captured as a failing test (Red), then made to
pass (Green), then optionally refactored. The pack shipped the
**foundation** for FDTDD in v2.1 PR #26 + the v2.1 cleanup (#30):

- `.tdd/active-finding` marker file — tracks the current FDTDD cycle.
- `scripts/tdd/finding-start.sh` and `finding-finish.sh` — helpers
  for operators to start/end a cycle.
- Gate 4 protects the marker from direct Claude edits.
- Injected guidance in `hooks/inject-findings.sh` is mode-aware:
  `review.mode = strict_tdd` or `governed_tdd` tells Claude to write
  a failing test first.

But it's all "**soft**" — the guidance is text, Claude reads it,
follows it most of the time, but nothing prevents bypass. For
low-stakes work, soft is fine; for Tier-1 code (auth, billing,
session, capital, anything where a bug ships pain), soft is not
enough. **This proposal adds the hard rails.**

Same architectural pattern as v2.2's ops-triage rail applied to code
instead of commands: **harness controls the trigger; model owns the
decision space within.**

---

## 1. The problem

A Tier-1 path (defined by `runner/lib/tier1.sh`, configured via
`.tdd/tiers.toml`) carries multiples-of-hours recovery cost when
broken. The current soft-guidance path looks like:

```
operator: "fix the auth race condition"
claude:   reads injected guidance suggesting FDTDD,
          but proceeds to edit auth.go directly,
          adds a test afterward that exercises the
          new code path (Goodhart's Law: test is now
          shaped to the implementation, not the bug)
```

Two specific anti-patterns the soft rails do not prevent:

1. **Edit prod code first** — Claude opens `auth.go`, writes the
   fix, then writes a test. The test characterizes what Claude
   wrote, not the bug Claude was supposed to find. Test reviewers
   see "test added; code change looks plausible" and approve.
2. **Edit the test until it passes** — Claude writes a failing test,
   sees it fails, then tweaks the test assertions until they match
   the (buggy) code's actual behavior. The cycle exits "green"
   without ever fixing the underlying bug.

Stage 1 rails close both:

- **Gate 1** blocks Edit/Write/MultiEdit on Tier-1 prod code unless
  an active finding exists with a Red proof.
- **Gate 3** blocks Edit/Write/MultiEdit on the active finding's
  test files during the Green phase.

These are PreToolUse hooks — same shape as v2.2 ops-risk-triage and
existing protect-tdd-artifacts.

---

## 2. Goals + non-goals

**Goals.**

- Tier-1 prod code changes are mechanically gated on Red proof.
- The active finding's test files are locked during Green.
- Adopters in `strict_tdd` mode get hard-deny; in `governed_tdd`
  mode get `ask` (operator can approve with eyes open); in soft
  modes (default) get only the existing inject-findings guidance.
- Marker schema extensions are forward-compatible (future Stage 2
  rails can add fields without migration tax).
- Helper-script ergonomics are good enough that operators actually
  use the helpers instead of bypassing.

**Non-goals.**

- Don't apply Gate 1/3 to non-Tier-1 code. The premise is "high
  stakes deserves high friction"; applying everywhere is the
  approval-fatigue failure mode v2.2 ops-triage taught us to
  avoid.
- Don't define Stage 2 (Gates 2/4/5+) in this proposal. The
  marker-schema extensions are forward-compatible so Stage 2
  doesn't need migration, but the design is out of scope here.
- Don't change the `runner/lib/tier1.sh` Tier-1 detection logic.
  v2.1 PR #9 shipped that; we just consume it.

---

## 3. Marker schema extensions

`.tdd/active-finding` is a JSON file today. The v2.1 PR #26 shape is
minimal:

```json
{
  "finding_id": "F-2026-06-08-001",
  "description": "auth: race in token refresh under concurrent requests",
  "started_at": "2026-06-08T10:00:00Z",
  "tier": "tier1"
}
```

Stage 1 rails need these added fields:

```json
{
  "finding_id":          "F-2026-06-08-001",
  "description":         "auth: race in token refresh under concurrent requests",
  "started_at":          "2026-06-08T10:00:00Z",
  "tier":                "tier1",

  "phase":               "red",
  "red_proof_accepted":  false,
  "test_files":          [],
  "prod_files":          [],
  "red_accepted_at":     null,
  "green_started_at":    null,
  "closed_at":           null
}
```

| Field | Purpose | Set by |
|---|---|---|
| `phase` | One of `"red"` / `"green"` / `"refactor"` / `"closed"`. Drives Gate 1 + Gate 3 decisions. | `finding-start.sh` (initial = `"red"`), helpers as cycle progresses |
| `red_proof_accepted` | True after the operator has approved the Red proof (the failing test demonstrates the bug, not just makes any assertion fail). | `finding-accept-red.sh` (new helper) |
| `test_files` | List of test-file paths that demonstrate the bug. Gate 3 locks these during Green. | Operator declares when running `finding-accept-red.sh <path>...` |
| `prod_files` | List of prod-file paths the operator intends to edit. Optional; helps Gate 1 distinguish "expected" edits from "drift". | Operator declares (optional) |
| `red_accepted_at` | Timestamp when Red was accepted; transitions phase to `"green"`. | `finding-accept-red.sh` |
| `green_started_at` | Same as red_accepted_at currently, but separate field so future Stage 2 can decouple. | `finding-accept-red.sh` |
| `closed_at` | Timestamp when `finding-finish.sh` ran. After this, marker becomes "closed" and is rotated to `.tdd/findings/closed/<id>.json`. | `finding-finish.sh` |

**Backward compatibility**: existing markers without these fields are
treated as `phase: "red"`, `red_proof_accepted: false`, empty
`test_files` / `prod_files`. Gate 1 still works (denies prod edits
because Red proof is unaccepted); Gate 3 no-ops (no test files
declared yet).

---

## 4. The two gates

### Gate 1 — Red proof required for Tier-1 prod fix

**Hook**: `hooks/gate-fdtdd-red-required.sh` (PreToolUse, matcher
`Edit|Write|MultiEdit`).

**Logic**:
```
read .tdd/active-finding (if any)
read tdd-pack.toml [review] mode
read tool_input.file_path

if file_path not in a Tier-1 path → exit 0 (allow)
if file_path looks like a test (e.g. ends in _test.go) → exit 0 (allow — Gate 3 handles tests)
if no active finding → behavior depends on mode:
  - soft / off              → exit 0 (allow, soft guidance only)
  - governed_tdd            → emit ask: "Tier-1 prod edit needs an active finding. Run /finding-start <description> first, or approve to bypass."
  - strict_tdd              → emit deny: "Tier-1 prod edit blocked: no active finding. Run /finding-start <description> first."

if active finding exists but red_proof_accepted == false → behavior:
  - soft / off              → exit 0
  - governed_tdd            → emit ask: "Active finding exists but Red proof not yet accepted. Approve to bypass, or write the failing test first and run /finding-accept-red <test>."
  - strict_tdd              → emit deny: "Tier-1 prod edit blocked: Red proof not accepted. Write the failing test first and run /finding-accept-red <test>."

if red_proof_accepted == true → exit 0 (allow)
```

### Gate 3 — Test-lock during Green

**Hook**: `hooks/gate-fdtdd-test-lock.sh` (PreToolUse, matcher
`Edit|Write|MultiEdit`).

**Logic**:
```
read .tdd/active-finding
read tdd-pack.toml [review] mode
read tool_input.file_path

if no active finding → exit 0 (allow)
if phase != "green" → exit 0 (allow)
if file_path not in active_finding.test_files → exit 0 (allow)

# At this point: we're in Green AND editing a locked test file.
- soft / off                → exit 0 (allow, soft guidance only)
- governed_tdd              → emit ask: "Test file is locked during Green to prevent edit-test-until-passes. Approve to bypass, or fix the prod code so the test passes."
- strict_tdd                → emit deny: "Test file locked during Green phase. Modify prod code to make the existing test pass, or run /finding-restart-red to revisit the test."
```

**Why two gates, not one combined?** Same isolation pattern as
v2.2 ops-triage: each gate has a focused responsibility, easier to
reason about + smoke separately. They cooperate via the shared
marker but neither needs to know the other exists.

---

## 5. Mode hierarchy

Existing `review.mode` field gets explicit meanings for Stage 1:

| Mode | Gate 1 | Gate 3 | Existing soft guidance |
|---|---|---|---|
| `off` | allow | allow | none (rail disabled) |
| `soft` (= old default) | allow | allow | inject-findings text only (today) |
| `governed_tdd` | **ask** | **ask** | inject-findings + Gate ask prompts |
| `strict_tdd` | **deny** | **deny** | inject-findings + Gate hard denies |

The current `review.mode` field already accepts `governed_tdd` /
`strict_tdd` per the v2.1 cleanup PR (#30, B5 fix). This proposal
adds the Gate 1/3 mechanical enforcement to those modes; `soft` /
`off` modes are unchanged from current behavior.

---

## 6. New helper scripts + slash commands

The existing `finding-start.sh` and `finding-finish.sh` cover the
endpoints. Stage 1 adds the middle:

- `scripts/tdd/finding-accept-red.sh <test-file> [<test-file>...]`
  Operator runs after writing a failing test that demonstrates the
  bug. Records `test_files`, sets `red_proof_accepted = true`,
  `phase = "green"`, `red_accepted_at = now`. Slash command:
  `/finding-accept-red`.
- `scripts/tdd/finding-restart-red.sh`
  Operator runs to drop back from Green to Red (e.g. the test was
  wrong and they want to revisit it). Sets
  `red_proof_accepted = false`, `phase = "red"`, clears
  `red_accepted_at`. Slash command: `/finding-restart-red`.
- `.claude/commands/finding-start.md`,
  `.claude/commands/finding-accept-red.md`,
  `.claude/commands/finding-finish.md`,
  `.claude/commands/finding-restart-red.md` — slash commands that
  load short skills documenting each helper.

The slash commands are critical for ergonomics: without them,
operators have to remember the script names + paths. With them,
Claude can be told (in injected guidance) "run /finding-accept-red"
and the operator types it.

---

## 7. Build slices

Seven slices. Slices 1–4 are the MVP; 5–7 are polish + helpers.

| Slice | Scope |
|---|---|
| **1** | Lock the marker schema extensions (§3) + write a JSON Schema (`schemas/active-finding.schema.json`) for it, strict-mode compliant per v2.1.0 Bug 1 lesson. Update `finding-start.sh` + `finding-finish.sh` to read/write the new fields with backward-compatible defaults. Counterfactual smoke: a v2.1-era marker (without new fields) is treated as `phase: "red"`, `red_proof_accepted: false`. |
| **2** | Implement Gate 1 (`hooks/gate-fdtdd-red-required.sh`). Register on PreToolUse `Edit\|Write\|MultiEdit`. Default `review.mode = soft` so this is no-op for existing adopters until they opt in. Smoke covers all 4 modes × all 3 marker states (no finding / finding-without-red / finding-with-red). |
| **3** | Implement `finding-accept-red.sh` + `/finding-accept-red` slash command + skill. Validates test files exist + parse as Go test files (or other languages — defer the polyglot bit to the v2.4 grounding-adapter cycle if relevant). Counterfactual smoke: invalid test file → fail loud, marker untouched. |
| **4** | Implement Gate 3 (`hooks/gate-fdtdd-test-lock.sh`). Smoke covers locked-during-Green vs unlocked-otherwise + counterfactuals for path-matching edge cases. |
| **5** | Implement `finding-restart-red.sh` + `/finding-restart-red` slash command + skill. Tests Red→Green→Red transition + that Gate 3 unlocks correctly. |
| **6** | Update `hooks/inject-findings.sh` to surface mode-aware guidance about the Gates. In `governed_tdd` / `strict_tdd` modes, when there's an active finding in Green phase, the injected text reminds Claude that test files are locked. Same §9 file fallback as v2.2 ops-triage (`.tdd/active-finding/pending-reason.txt`). |
| **7** | `docs/UPDATE_NOTES_v2.2-to-v2.3.md` adopter guide: how to enable Tier-1 + Stage 1 rails, the 4-mode hierarchy, the helper scripts. Same shape as the v2.0-to-v2.1 and v2.1-to-v2.2 guides. |

Slices 1+2+4 are the core gates. Slices 3+5 are helper ergonomics.
Slices 6+7 are guidance + docs.

---

## 8. Interaction with v2.2 ops-triage rail

Both Stage 1 rails AND ops-triage are PreToolUse hooks. They don't
overlap on tools (ops-triage is Bash, Stage 1 is file edits) so
there's no decision conflict. But two design choices benefit from
being consistent across rails:

- **§9 file fallback pattern.** v2.2 writes ask/deny reasons to
  `.tdd/ops-triage/pending-reason.txt` (defense for #55889 — Bash
  matcher `permissionDecisionReason` may not render in the
  operator UI). Stage 1 should do the same:
  `.tdd/active-finding/pending-reason.txt`. Same file shape, same
  defense. Slice 6 wires this.
- **Mode terminology.** v2.2 uses `off` / `observe` / `ask` /
  `governed`. Stage 1 uses `off` / `soft` / `governed_tdd` /
  `strict_tdd`. Different terms because the rails serve different
  purposes (ops-triage observe-mode collects data; Stage 1 has no
  data-collection phase), but conceptually `governed_tdd` ≈
  `ask` and `strict_tdd` ≈ "ask + hard-deny on the critical
  subset". Document the parallel in the adopter guide.

---

## 9. Smoke tests

Per the v2.1.1 + v2.2 discipline: counterfactual every "match"
assertion.

- **Marker schema smoke**: every required field present, schema
  strict-mode-compliant (caught by existing
  `smoke-schema-strict-mode.sh`). Backward-compat: a v2.1 marker
  loads without errors + treats missing fields as
  `phase: "red"` / `red_proof_accepted: false`.
- **Gate 1 smoke** (slice 2): for each of 4 modes × 3 marker
  states (none / no-red / red-accepted), assert the correct
  decision. Plus counterfactuals: editing a NON-Tier-1 file always
  allows; editing a `*_test.go` file always allows (Gate 3
  handles it).
- **`finding-accept-red.sh` smoke** (slice 3): valid + invalid
  test-file inputs; marker state transitions; counterfactual that
  a non-existent test file fails loud and marker stays in `red`.
- **Gate 3 smoke** (slice 4): editing a locked test file in Green
  → ask/deny; editing the same file outside Green → allow; editing
  an unlisted test file → allow; counterfactual that path-matching
  is exact (a file with a similar name but not in `test_files`
  allows).
- **Red→Green→Red transition smoke** (slice 5): full cycle through
  `finding-start` → `finding-accept-red` → `finding-restart-red` →
  `finding-accept-red` again. Marker state correct at each step.
- **§9 file fallback smoke** (slice 6): ask/deny reasons written
  to `.tdd/active-finding/pending-reason.txt`; overwritten per
  call (not appended), same as v2.2 pattern.
- **Existing Gate 4 protection smoke** updated to confirm the
  expanded marker schema is still protected (no Claude direct
  edits to `.tdd/active-finding/`).

---

## 10. Honest limits

- **Test-file detection.** Slice 4 needs to recognize "what's a
  test file." For Go, `*_test.go` is unambiguous. For polyglot
  repos via the grounding-adapter interface (proposal #107), each
  language has its own convention. v2.3 ships Go-only test
  detection; polyglot support waits on #107's adapter pattern.
- **Tier-1 detection depends on `runner/lib/tier1.sh`.** If an
  adopter hasn't set up `.tdd/tiers.toml`, no path is Tier-1 and
  Gate 1 never fires (allow-all). This is correct behavior — the
  rail is opt-in via tier configuration — but worth documenting.
- **The Goodhart problem isn't fully solved.** Gate 3 prevents
  edit-test-until-it-passes, but a sufficiently determined
  operator can `finding-restart-red`, rewrite the test, and re-
  accept. The rail makes the bypass explicit (it logs each
  transition); it doesn't make it impossible. Same residual
  trust as every other gate in the pack.
- **Helper-script overhead.** Operators must run `finding-start`
  before any Tier-1 edit in `strict_tdd` mode. If forgotten, the
  first edit gets denied with a clear message. Approval-fatigue
  risk is low because the message is actionable, but watch the
  rate in adopter dogfooding.
- **No Stage 2 here.** Future Gates 2/4/5+ may be needed for
  full TDD ceremony (e.g. Gate 2 = at least one assertion before
  Green; Gate 4 = no `if false` / `t.Skip` shortcuts). Out of
  scope; the marker schema is forward-compatible so Stage 2
  doesn't need migration.

---

## 11. Open questions for slice 1

1. **Marker location.** Today: `.tdd/active-finding`. Stage 1
   marker is richer (multi-field JSON); should it move to
   `.tdd/findings/active.json` with closed findings at
   `.tdd/findings/closed/<id>.json`? Recommend: yes, cleaner
   separation. Existing path (`.tdd/active-finding`) becomes
   either a symlink or gets removed in slice 1.
2. **One active finding at a time vs. parallel findings.** Today
   the pack assumes one. Stage 1 keeps that assumption. Parallel
   findings are a v2.4+ design question.
3. **What counts as a "Tier-1 prod file" exactly?**
   `runner/lib/tier1.sh` answers this for paths; but a single PR
   might touch both Tier-1 and non-Tier-1 files. Gate 1 fires
   per-edit; we don't have a "PR-level" concept. Per-edit is the
   right granularity (and matches PreToolUse natively); document
   it.
4. **Slash-command naming.** Current FDTDD slash commands ship as
   `/finding-start`, `/finding-finish`. Stage 1 adds
   `/finding-accept-red`, `/finding-restart-red`. Should we move
   to a hierarchical namespace (`/finding start`, `/finding
   accept-red`, etc.) for the v2.3 generation? Recommend: no,
   slash commands are flat in Claude Code. Just add the new
   commands at the top level.
5. **What happens on a multi-file Edit?** `MultiEdit` can touch
   multiple files in one tool call. Gate 1 / Gate 3 see them as
   one tool invocation. We probably want to check ALL of them and
   deny if ANY would be denied. Slice 2 covers this; spec it
   explicitly to avoid drift.

---

## 12. Recommendation

**Approve and start slice 1 (lock the marker schema).** Slice 1 is
the load-bearing decision: every later slice depends on the schema
fields agreed here. ~2-3 hours including the schema doc + Schema
file + helper-script updates + backward-compat smoke. Then slices
2+4 (the gates) follow naturally over the next week of
implementation.

This is FDTDD's enforcement layer landing — the architecture has
been talked about since v2.1 PR #26; v2.3 makes it real.

---

## 14. Addendum — Codex review findings (2026-06-08)

A second-model adversarial review by Codex (gpt-5.5, high reasoning)
was harsh on this proposal — 3 BLOCKER + 5 MAJOR + 2 MINOR — and
identified a genuinely important framing problem. Codex's closing
verdict deserves a direct quote:

> *"the largest issue is that the rail proves and scopes much less
> than it claims: any accepted finding can unlock unrelated Tier-1
> prod edits, and 'Red proof' is currently just operator metadata
> unless the failing test is mechanically captured."*

That critique is correct. v1 of this proposal sold the rail as
"mechanical FDTDD enforcement" but in practice the two key claims
(scoped unlock + actual Red proof) are operator-attested, not
mechanically enforced. v2 of the proposal fixes both.

### BLOCKER findings (3) — all accepted

1. **Gate 1 is too coarse.** Once ANY active finding has
   `red_proof_accepted = true`, v1's Gate 1 allows edits to ANY
   Tier-1 prod file. An auth finding can unlock billing / session /
   capital edits. `prod_files` is described as optional → not
   enforced. The "Red proof gates the scope of unlock" claim is
   false in v1.
   - **Change**: `prod_files` becomes REQUIRED for strict/governed
     modes. Gate 1's allow-condition extended: `red_proof_accepted
     == true` AND `file_path` in the active finding's `prod_files`
     OR in the same Tier-1 directory tree as a file in
     `prod_files`. Off-scope Tier-1 edits get the same deny as if
     no finding existed. `finding-accept-red.sh` MUST collect both
     test files AND the operator-declared prod-file scope; without
     prod_files, slice 2 refuses to transition to Green.

2. **"Red proof" is not actually proved.** v1's
   `finding-accept-red.sh` only validates that test files exist
   and parse as Go test files. It does NOT prove the test currently
   fails, fails for the intended reason, or demonstrates the
   finding. The "Red proof" guarantee is mostly social.
   - **Change**: `finding-accept-red.sh` v2 MUST run the declared
     test command (e.g. `go test -run <TestName> ./<pkg>`) and
     record the failing exit code + the last ~200 lines of failure
     output into the marker's new `red_proof_record` field. The
     transition to Green is gated on a non-zero test exit. If the
     test passes (i.e. the bug is not reproduced), the operator
     gets a clear "test must fail to be a Red proof" error and the
     marker stays in `red`. Mechanical Red, not social.

3. **Marker layout self-contradicts.** v1 alternates between
   `.tdd/active-finding` as a JSON file AND
   `.tdd/active-finding/pending-reason.txt` as if it were a
   directory, AND suggests moving to `.tdd/findings/active.json`.
   Breaks Gate 4, helpers, smokes, docs.
   - **Change**: Lock the filesystem contract before slice 1 ships.
     v2 contract: `.tdd/findings/active.json` is the canonical
     marker (JSON file); `.tdd/findings/pending-reason.txt` is the
     §9 fallback (separate sibling file in the same directory). The
     legacy `.tdd/active-finding` path (v2.1 PR #26) is read by
     slice 1's helpers for backward-compat but is migrated to
     `.tdd/findings/active.json` on first `finding-start.sh`
     invocation. Gate 4's PROTECTED_PREFIXES gets `.tdd/findings/`
     instead of `.tdd/active-finding`. Smokes updated.

### MAJOR findings (5) — all accepted

| # | Finding | Change |
|---|---|---|
| M1 | Path normalization unspecified. Gate 3 compares `tool_input.file_path` to `test_files` via exact string match, but real inputs vary: absolute / relative / `./` prefix / symlinked / case-different. Either misses locked files or falsely blocks unrelated ones. | v2 §4 adds canonicalization rules: paths are stored repo-root-relative + cleaned (`./x/../y` → `y`); symlinks resolved via `pwd -P` (same pattern as Gate 4 §6 canonicalization); both `test_files` and `tool_input.file_path` canonicalized before comparison. Smokes cover all four input variants. |
| M2 | MultiEdit semantics likely wrong. Claude Code's `MultiEdit` typically targets ONE `file_path` with multiple edits, not multiple files. v1's "check ALL of them" is misleading. | v2 slice 1's pre-checklist adds an empirical task: capture real PreToolUse JSON for Edit, Write, and MultiEdit. Spec the gate parsers against the observed payloads. If MultiEdit is single-file, the "check ALL files" requirement is dropped; if it's multi-file, the requirement holds with explicit per-file evaluation. |
| M3 | Test-lock during Green is too rigid. Real Green work often requires mechanical test maintenance (fix imports, helper placement, table cases, snapshots) after prod changes. Strict-mode deny forces noisy `restart-red` churn. | v2 adds an "amend-red-proof" flow: `scripts/tdd/finding-amend-red.sh <test-file>` lets the operator declare a mechanical test change (imports / helpers / etc.) WITHOUT regressing to Red. The marker records `amendments: [{ts, file, rationale}]`. Gate 3 allows test edits within an active amendment window. Soft modes are unaffected. |
| M4 | No stale-marker recovery. If a marker stays in Green after an interrupted session, Tier-1 edits stay unlocked indefinitely. No policy on staleness. | v2 §11 adds a new helper `scripts/tdd/finding-status.sh` that detects staleness (active marker > 24h old, or with no recent commits / test runs); reports it on `SessionStart` via the existing `session-start.sh` hook. Gate 1 + Gate 3 become CONSERVATIVE when timestamps are inconsistent (e.g. `green_started_at` before `red_accepted_at`): treat as `phase: "red"` for gating until operator resolves. |
| M5 | Slice order strands users. v1 ships Gate 1 (slice 2) before `finding-accept-red.sh` (slice 3); ships Gate 3 (slice 4) before `finding-restart-red.sh` (slice 5). In strict mode, operators would hit deny without the ergonomic escape hatch. | v2 reorders to vertical slices: slice 2 = schema + start/finish + accept-red helper (Gate 1 ready-but-not-active in soft mode); slice 3 = Gate 1 fires in governed/strict; slice 4 = Gate 3 + restart-red + amend-red helpers (Gate 3 ready); slice 5 = Gate 3 fires in governed/strict; slices 6-7 unchanged. Each slice ships a usable unit. |

### MINOR findings (2) — accepted

- **Mode naming divergence** (`off/observe/ask/governed` for v2.2
  ops-triage vs `off/soft/governed_tdd/strict_tdd` for FDTDD)
  creates adopter confusion. v2 includes a compatibility table in
  the adopter docs (slice 7) showing the parallel (governed_tdd ≈
  ask + scope; strict_tdd ≈ ask + scope + deny). Names stay
  different because the rails serve different purposes (ops-triage
  observe is data-collection; FDTDD has no data-collection phase),
  but the parallel is documented.
- **Load-bearing claims unverified**: "review.mode already accepts
  governed_tdd/strict_tdd", "Gate 4 protects the marker",
  "permissionDecisionReason may not render". Slice 1 pre-checklist
  adds explicit verification steps with exact file/test/command
  references for each.

### Revised slice plan (vertical, per M5)

| Slice | v1 scope | v2 scope (post-addendum) |
|---|---|---|
| 1 | Lock marker schema + JSON Schema + backward-compat | Same, plus the BLOCKER 3 filesystem-contract lock (`.tdd/findings/active.json` + sibling `pending-reason.txt`) + Gate 4 PROTECTED_PREFIXES update + M2 empirical PreToolUse JSON capture + M5's pre-checklist verifying load-bearing claims. Migration shim for v2.1 `.tdd/active-finding` markers. |
| 2 | Gate 1 hook + register | **Schema + finding-start/finish + accept-red helper** (with BLOCKER 2's mechanical test-run + BLOCKER 1's required prod_files). Gate 1 implementation lands here too but DEFAULT MODE is soft — it doesn't fire yet. |
| 3 | accept-red helper | **Activate Gate 1 in governed_tdd / strict_tdd modes**. Mode toggle smoke + counterfactual that soft mode still allows. Migration note in adopter docs. |
| 4 | Gate 3 hook | **Gate 3 hook + restart-red + amend-red helpers** (M3's mechanical-test-maintenance flow). Gate 3 ready-but-not-active. |
| 5 | restart-red helper | **Activate Gate 3 in governed_tdd / strict_tdd modes**. Smokes cover lock-during-Green, restart-red, amend-red, all with M1 path canonicalization. |
| 6 | inject-findings guidance + §9 file fallback | Unchanged, with §9 fallback path now `.tdd/findings/pending-reason.txt` per BLOCKER 3 resolution. |
| 7 | UPDATE_NOTES_v2.2-to-v2.3 | Unchanged + add the mode-parallel table from MINOR 1. |

### What stays solid in v1

- The two-rail concept (Gate 1 = "Red required for Tier-1 prod
  fix"; Gate 3 = "test-lock during Green") is the right
  factorization.
- The shared §9 file-fallback pattern with v2.2 ops-triage is the
  right move (Codex did not push back on this).
- Mode hierarchy (`off / soft / governed_tdd / strict_tdd`)
  matches the proven v2.2 ops-triage shape applied to a different
  rail.
- Backward-compat: v2.1-era markers without new fields read as
  `phase: "red"`, `red_proof_accepted: false`. (Codex did not
  challenge this; the backward-compat smoke remains load-bearing.)
- The marker-schema-strict-mode lesson from v2.1.0 applies
  automatically via `smoke-schema-strict-mode.sh` once
  `schemas/active-finding.schema.json` ships.

---

## 13. Related

- v2.1 PR #26 — FDTDD foundation (the marker, the helpers, the
  mode-aware injected guidance).
- v2.1 PR #30 (B5 fix) — reconciled `review.mode` semantics +
  removed "silently" from injected guidance.
- v2.1 PR #9 / `runner/lib/tier1.sh` — Tier-1 path detection that
  Gate 1 consumes.
- [`PROPOSAL-ops-risk-triage.md`](PROPOSAL-ops-risk-triage.md) —
  same "harness controls trigger; model owns decision space within"
  pattern applied to commands instead of code. The §9 file fallback
  is reused here.
- `hooks/protect-tdd-artifacts.sh` (Gate 4) — already protects
  `.tdd/active-finding` from direct Claude edits. Slice 1 extends
  the protection to cover the new `.tdd/findings/` layout if we
  adopt §11.1's recommendation.
- [`UPDATE_NOTES_v2.1-to-v2.2.md`](UPDATE_NOTES_v2.1-to-v2.2.md) —
  the adopter guide pattern that slice 7 follows for v2.2-to-v2.3.
