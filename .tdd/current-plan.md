# Bugfix Plan: v1.6.2-marker-drift-and-pass-a-docs — reduce per-cycle review friction

Status: active
Cycle ID: v1.6.2-marker-drift-and-pass-a-docs
Change type: bugfix (operator-friction reduction; no new gates, no
                    semver-breaking schema changes)
Tier: 1 (touches `.claude/skills/second-opinion/SKILL.md`)

<!-- TDD ceremony markers. Set each ONLY after the matching operator APPROVED reply. -->
Bug reproduced: yes
Human approved spec: yes
Red phase confirmed: yes
Green phase authorized: yes
Implementation reviewed: yes
Fix applied: yes
Regression tests added: yes
Bug-elsewhere check complete: yes

## Problem statement

The `parasitoid` developer's 10-cycle trial of v1.6.0 (memo dated
2026-05-09) reported two operator-friction issues unrelated to the
v1.6.1 governance bypasses already shipped:

1. **Marker-name drift between Codex's training data and the v1.6.0
   schema.** Codex's pre-v1.6.0 prior holds `Human approved
   implementation: yes` as the canonical M3 marker; the schema
   renamed it to `Green phase authorized: yes` and exposed the old
   name as a `marker_aliases` entry. Codex returns P1 findings of
   the form "marker name doesn't match required gate vocabulary" in
   3/5 plan-review Pass B runs. Each finding is incorrect on the
   facts but requires the operator to write a substantive PUSHBACK
   adjudication (~3-5 minutes of artifact-rewriting +
   ~10 lines of audit-trail noise per cycle). Over 10 cycles,
   ~30-50 minutes of friction on a non-issue.

2. **Pass A's value framing is undersold.** The v1.6.0 SKILL.md
   describes Pass A as an independent design generator. The trial
   showed Pass A's value pattern (3/10 converged with Claude, 4/10
   stylistic divergence, 3/10 substantive priming of Pass B) is
   real but the structural property — Pass A is the noise-floor /
   independence measurement for Pass B's anchoring — is not
   documented. Operators perceive Pass A's latency cost as
   unjustified when Pass B fails (network/API issue), even though
   Pass A's standalone design doc remains a valid peer-review
   artifact.

Neither is a gate bug. Both are friction the pack can mechanically
reduce.

## Reproduction

### Item 1 — marker drift (PR3, PR6, PR7 trial cycles)

```text
Pass B JSON output (verbatim):
{
  "id": "F1",
  "severity": "P1",
  "title": "Tier 1 implementation approval marker doesn't match required gate vocabulary",
  "evidence": "Repo instructions require the Tier 1 marker `Human approved implementation: yes`. The plan instead declares `Green phase authorized: no`."
}
```

Local config check:
```bash
$ jq '.required_markers_commit_time' .tdd/tdd-config.json
[
  "Human approved spec: yes",
  "Red phase confirmed: yes",
  "Green phase authorized: yes",
  "Implementation reviewed: yes"
]
$ jq '.marker_aliases' .tdd/tdd-config.json
{
  "Green phase authorized: yes": "Human approved implementation: yes",
  "Implementation reviewed: yes":  "Human approved implementation: yes"
}
```

The local config is canonical (post-v1.6.0); Codex's prior is
stale. PUSHBACK is the correct adjudication, but it's costly
per cycle.

### Item 2 — Pass A perception

Trial frequency from the developer's memo:

| Pattern | Cycles |
|---|---|
| Pass A converged with Claude's design, zero unique catches | 3/10 |
| Pass A had stylistic divergence Claude overrode | 4/10 |
| Pass A surfaced substantive concern Pass B then sharpened | 3/10 |

Reproduction: read SKILL.md Step 4 description; note that "Pass A
generates an independent design" is sold as direct-find-bugs value.
The trial data shows Pass A's value is mostly indirect (priming Pass
B). Operators reading the doc expect Pass A to find unique bugs;
when it doesn't (3/10 converged cases), they question its ROI.

## Expected behavior

### Item 1

When Codex's Pass B output contains a known marker-drift finding
(matches a documented pattern such as
`Human approved implementation: yes` referenced as required), the
hook preprocessor flags the finding with
`auto_pushback_eligible: true` and a canonical short-form citation
("v1.6.0 renamed this marker; see .tdd/tdd-config.json
marker_aliases"). The agent's PUSHBACK rationale can be short-form
(one line + cite local evidence) instead of full essay.

The /second-opinion skill's prompt template includes a
schema-context block generated from `.tdd/tdd-config.json` so
Codex sees the canonical markers + deprecated aliases + reviewer
instruction "prefer local config to model prior" before producing
findings. This SHOULD reduce drift findings at the source, not
just make them cheaper to handle.

### Item 2

SKILL.md (Pass A description section) reframes Pass A as:
- Noise-floor measurement for Pass B's anchoring (structural property)
- Standalone peer-review artifact (independent value when Pass B fails)

`docs/specs/second-opinion-v1.6.0-spec.md` documents the trial's
Pass A frequency data so operators know what to expect.

## Actual behavior

### Item 1

Codex returns marker-drift P1 findings → agent must read each →
verify against `.tdd/tdd-config.json` → write substantive PUSHBACK
to disposition matrix → carry through to commit message. ~3-5 min
of friction per cycle.

### Item 2

Operators see Pass A's "trade-offs accepted/rejected" section and
expect direct catches; trial data shows ~30% direct convergence
(no unique catches). Cost-benefit feels mispriced. When Pass B
times out, Pass A's design-doc artifact feels like sunk cost.

## Business/domain invariant

The pack's anti-sycophancy discipline (PUSHBACK requires
substantive rationale) is correct. We are NOT changing it. We are
only:
- Giving Codex more local schema context up-front so drift findings
  occur less often (preventive fix)
- Letting agents fast-track PUSHBACK when drift findings DO occur,
  with mandatory citation of local evidence (curative fix)
- Documenting what Pass A actually delivers structurally so
  operators can calibrate expectations correctly

The discipline architecture (PUSHBACK, hash binding, M1-M4) stays
intact. This is friction reduction, not gate weakening.

## Affected code

- `scripts/tdd/build-second-opinion-context.sh` — NEW. Generates
  `.tdd/second-opinion/context/schema-context-for-reviewer.md`
  from `.tdd/tdd-config.json`. ~80 lines bash.
- `.tdd/second-opinion/context/schema-context-for-reviewer.md` —
  NEW (generated; gitignored — operator runs the generator on
  config changes; cycle will regenerate if missing). ~30 lines
  markdown.
- `.claude/skills/second-opinion/SKILL.md` — modified (Tier 1):
  - Step 2 prompt template includes the generated schema-context
    file (after CLAUDE.md context, before TARGET).
  - Step 4 description of Pass A reframed as noise-floor +
    standalone artifact.
  - New Step 4b documents the hook preprocessor for known-drift
    findings (see go-tdd.md rules section).
- `.claude/rules/go-tdd.md` — modified: new "Known reviewer-drift
  findings" section listing the patterns + canonical short-form
  PUSHBACK template. Agent uses this when the preprocessor flags
  `auto_pushback_eligible: true`.
- `docs/specs/second-opinion-v1.6.0-spec.md` — modified: documents
  marker drift as a known limitation; cites the parasitoid trial's
  Pass A frequency data.
- `scripts/tdd-test-hooks.sh` — fixtures: ~12-15 acceptance tests.
- `.gitignore` — add `.tdd/second-opinion/context/` so generator
  output doesn't pollute git history.

The hook preprocessor itself lives INSIDE SKILL.md's Step 5 bash
code (the existing /second-opinion runner). It runs on Codex's
JSON response BEFORE the agent reads findings: scans each finding
for known-drift patterns, adds `auto_pushback_eligible: true` +
`canonical_citation` fields, then prints the modified JSON. Net
addition to SKILL.md: ~25 lines of jq + bash.

## Failing tests that capture the bug

| Test | What it pins |
|---|---|
| v162-c1: build-second-opinion-context.sh exists + executable | tooling exists |
| v162-c1: generator produces context with canonical edit-time markers | preventive fix |
| v162-c1: generator produces context with canonical commit-time markers | preventive fix |
| v162-c1: generator includes deprecated aliases with explicit "DEPRECATED" tag | preventive fix |
| v162-c1: generator includes reviewer instruction "prefer local config" | preventive fix |
| v162-c1: generator handles missing tdd-config.json (warns + emits empty marker section) | error handling |
| v162-c1: SKILL.md Step 2 prompt references the generated context file | integration |
| v162-c1: SKILL.md Step 5 includes hook preprocessor for marker drift | integration |
| v162-c1: preprocessor flags `auto_pushback_eligible:true` on `Human approved implementation` finding | curative fix |
| v162-c1: preprocessor adds canonical citation pointing at marker_aliases | curative fix |
| v162-c1: preprocessor leaves unrelated findings unchanged (regression) | curative fix |
| v162-c1: go-tdd.md includes "Known reviewer-drift findings" section with marker_name_drift_v1.6.0 | docs |
| v162-c2: SKILL.md Step 4 describes Pass A as noise-floor measurement | docs |
| v162-c2: SKILL.md Step 4 documents Pass A standalone-artifact value when Pass B fails | docs |
| v162-c2: docs/specs/second-opinion-v1.6.0-spec.md cites parasitoid trial frequency data | docs |

~15 acceptance tests total. All easy regex/grep style on file contents
plus one fixture-driven test for the preprocessor.

## Root cause analysis

### Item 1

- Mechanism: the `/second-opinion` skill's prompt template (SKILL.md
  Step 2) sends the first 200 lines of `CLAUDE.md` as project
  context. Marker vocabulary lives in `.tdd/tdd-config.json`, not
  CLAUDE.md. Codex falls back to its training-data prior for marker
  names. v1.6.0 renamed M3 in the schema; Codex doesn't know.
- Introduced in: F-cycle (M3 marker rename, ~v1.5.x → v1.6.0 schema
  migration via `scripts/migrate-tdd-markers.sh`).
- Why not caught by existing tests: the existing tests verify the
  PACK's correct behavior (markers, aliases, hooks). They do NOT
  verify Codex's behavior (out of scope; can't be tested in CI).

### Item 2

- Mechanism: documentation gap. Pass A was added in v1.6.0 with
  emphasis on "independent design"; the structural property (noise
  floor for anchoring) wasn't articulated.
- Introduced in: v1.6.0 SKILL.md Step 4 addition.
- Why not caught: not a bug; a documentation/framing issue surfaced
  by trial-feedback only.

## Minimum fix

### Item 1

1. `scripts/tdd/build-second-opinion-context.sh`: reads
   `tdd-config.json`, emits markdown with markers + aliases +
   reviewer instruction. ~80 lines.
2. SKILL.md Step 2 prompt template: source + cat the generated
   context file. ~5 lines.
3. SKILL.md Step 5 bash: pipe Codex's response through a jq filter
   that tags known-drift findings. ~25 lines.
4. `.claude/rules/go-tdd.md`: new section listing
   `marker_name_drift_v1.6.0` pattern + short-form PUSHBACK
   template. ~30 lines markdown.

### Item 2

1. SKILL.md Step 4: rewrite Pass A description block. ~20 lines.
2. `docs/specs/second-opinion-v1.6.0-spec.md`: appended
   "Trial-data evidence" section. ~40 lines.

Total net addition: ~200 lines across 6 files. No deletions; no
schema changes; no hook semantics changes.

## Acceptance criteria

### AC1 — Schema-context generator exists and is correct

1.1 `scripts/tdd/build-second-opinion-context.sh` exists,
    `chmod +x`, parses with `bash -n`.
1.2 Run with project's `.tdd/tdd-config.json` produces a markdown
    file at `.tdd/second-opinion/context/schema-context-for-reviewer.md`.
1.3 Output contains a "Canonical edit-time markers" section listing
    each entry from `required_markers_edit_time`.
1.4 Output contains a "Canonical commit-time markers" section listing
    each entry from `required_markers_commit_time`.
1.5 Output contains a "Deprecated aliases" section listing each
    `marker_aliases` mapping with the form
    `"OLD" → "NEW" (deprecated)`.
1.6 Output ends with the reviewer instruction:
    `If you think a marker is wrong, verify against
    .tdd/tdd-config.json BEFORE producing a finding. Local config
    is canonical and beats your training-data prior.`
1.7 Generator handles missing `tdd-config.json`: emits empty
    marker sections + a clear "config not found" comment + a
    warning to stderr; exits 0 (don't break /second-opinion).
1.8 Generator handles missing `marker_aliases` field: emits the
    "Deprecated aliases" section with "(none)" body. No crash.

### AC2 — SKILL.md prompt template integration

2.1 SKILL.md Step 2 (prompt building) sources/cats the generated
    context file (regenerates if missing or older than
    `tdd-config.json`).
2.2 The schema-context block appears in the prompt AFTER the
    `PROJECT CONTEXT (first 200 lines of CLAUDE.md, redacted):`
    block, BEFORE the `CHANGE SCOPE` line.
2.3 If the generator fails (jq missing, config malformed),
    /second-opinion still runs; the prompt just lacks the schema
    context block. Stderr advisory.

### AC3 — Hook preprocessor for known-drift findings

3.1 SKILL.md Step 5 bash includes a preprocessor that runs on
    Codex's parsed JSON response BEFORE the agent reads findings.
3.2 Preprocessor scans each finding's `evidence` + `title` for
    pattern `Human approved implementation: yes` (case-insensitive)
    AND simultaneously presence of phrases like "marker", "gate
    vocabulary", "approval marker", or "required marker" in same
    finding.
3.3 When matched, adds two fields to that finding:
    - `auto_pushback_eligible: true`
    - `canonical_citation: "v1.6.0 renamed this marker. See
       .tdd/tdd-config.json marker_aliases:
       'Human approved implementation: yes' is the deprecated alias
       for 'Green phase authorized: yes' (gate 2 green-side) AND
       'Implementation reviewed: yes' (gate 3)."`
3.4 Preprocessor never DELETES findings, only annotates. Operator
    still sees the finding and must adjudicate.
3.5 Findings without the drift pattern pass through unchanged
    (regression).
3.6 If Codex's response is not valid JSON (timeout, network error),
    preprocessor is skipped silently.

### AC4 — go-tdd.md rules update

4.1 New section "Known reviewer-drift findings" added to
    `.claude/rules/go-tdd.md`.
4.2 Section includes the pattern key `marker_name_drift_v1.6.0`
    with description.
4.3 Section provides a short-form PUSHBACK template that includes
    BOTH the canonical citation AND a local-evidence requirement
    ("cite the field name + line number from
    `.tdd/tdd-config.json`").
4.4 Section explicitly states: agent uses short-form ONLY when
    preprocessor flagged `auto_pushback_eligible:true`. Otherwise
    full PUSHBACK essay is required.

### AC5 — SKILL.md Pass A docs reframe

5.1 SKILL.md Step 4 (Pass A description) reframes Pass A as:
    > Pass A is the noise-floor / independence measurement for
    > Pass B's anchoring. When Pass A and Pass B converge on a
    > finding, you have evidence that two inferential paths reached
    > the same conclusion → high confidence. When they diverge,
    > you've learned that Claude's framing was load-bearing for
    > Pass B's analysis → important brittleness signal.
5.2 SKILL.md Step 4 also notes: Pass A's design doc has standalone
    peer-review value if Pass B times out / errors / returns
    nothing. Not "wasted" if Pass B fails.
5.3 Pass A's "trade-offs accepted/rejected" structure is preserved
    (operator workflow unchanged); only the explanatory framing
    around it is updated.

### AC6 — second-opinion-v1.6.0-spec.md known-limitation note

6.1 New section "Trial-data evidence" appended to
    `docs/specs/second-opinion-v1.6.0-spec.md`.
6.2 Section includes the parasitoid trial's Pass A frequency table
    (3/10 converged, 4/10 stylistic, 3/10 substantive priming).
6.3 Section documents marker drift as a "known reviewer-drift
    pattern" and points operators at the schema-context generator
    + go-tdd.md rules section as the mitigation path.
6.4 Section is honest: Pass A's value is real but mostly indirect
    (priming Pass B); not a single-handed bug-finder.

## Test plan

| Test name | AC# |
|---|---|
| v162_c1_generator_exists_executable | 1.1 |
| v162_c1_generator_emits_edit_time_markers | 1.2, 1.3 |
| v162_c1_generator_emits_commit_time_markers | 1.4 |
| v162_c1_generator_emits_deprecated_aliases | 1.5 |
| v162_c1_generator_emits_reviewer_instruction | 1.6 |
| v162_c1_generator_handles_missing_config | 1.7 |
| v162_c1_generator_handles_missing_aliases | 1.8 |
| v162_c1_skill_md_step2_includes_schema_context | 2.1, 2.2 |
| v162_c1_skill_md_preprocessor_present | 3.1 |
| v162_c1_preprocessor_flags_known_drift_finding | 3.2, 3.3 |
| v162_c1_preprocessor_passes_unrelated_findings_unchanged | 3.5 |
| v162_c1_go_tdd_md_drift_section_present | 4.1, 4.2, 4.3, 4.4 |
| v162_c2_skill_md_step4_pass_a_noise_floor_framing | 5.1 |
| v162_c2_skill_md_step4_pass_a_standalone_value | 5.2 |
| v162_c2_v160_spec_trial_data_section_present | 6.1, 6.2, 6.3, 6.4 |

15 acceptance tests. All run as part of the existing
`scripts/tdd-test-hooks.sh` suite (no new test runner).

## Implementation order (dependency-driven)

1. **AC1 first** (build-second-opinion-context.sh + tests).
   Standalone tool; no other file dependencies.
2. **AC2** (SKILL.md Step 2 prompt integration). Depends on AC1.
   Tier 1 file edit — adjudication required for the edit.
3. **AC3** (SKILL.md Step 5 preprocessor). Depends on SKILL.md
   already being editable (same Tier 1 cycle).
4. **AC4** (go-tdd.md rules update). Independent of SKILL.md;
   not Tier 1.
5. **AC5** (SKILL.md Step 4 Pass A reframe). Same Tier 1 file as
   AC2/AC3; batch into the same edit pass.
6. **AC6** (v1.6.0 spec doc note). Independent; not Tier 1.

Sequence: AC4 → AC1 → AC6 → AC2/AC3/AC5 (one SKILL.md edit pass).
This minimises Tier 1 edit ceremony to a single round.

## Non-goals (this cycle)

- Typed test-edit exceptions (Item 1 from the parasitoid memo) —
  deferred to v1.7.0. That's a 16-22h cycle with new schema, new
  hook, new library; doesn't fit a v1.6.x patch.
- AST-level assertion detection — deferred to v1.8.0.
- Removing `allow_after_red_confirmed` boolean — deferred to v2.0.0.
- Codex's training data update — out of scope (we don't control
  OpenAI's release schedule).

## Risk register

| Risk | Mitigation |
|---|---|
| Schema-context generator drift if `tdd-config.json` changes after generation | Generator runs on every /second-opinion invocation if context file is older than config file (mtime check). Cheap; cures staleness without operator action. |
| Preprocessor's regex matches false positives (legitimate findings about marker names get incorrectly flagged) | AC3.4 says preprocessor never DELETES findings, only annotates. Operator still sees + adjudicates. False positive cost: agent gets fast-track option they didn't need; agent still must cite local evidence. |
| Schema-context block leaks redacted patterns to Codex | The context block is markdown built FROM tdd-config.json — already on disk; not a new disclosure. The markers themselves are not secrets. |
| Codex's training data updates and stops emitting drift findings | Best case: preprocessor never fires; the schema-context block becomes harmless overhead. No regression. |
| Pass A reframing accidentally suggests Pass A is now optional | AC5.3 explicitly preserves the operator workflow. The reframe is explanatory, not behavioural. |
| The hook preprocessor lives inside SKILL.md (Tier 1 file) — every change to it requires Tier 1 ceremony | Accepted cost. Alternatives (separate script sourced by SKILL.md) add file-resolution complexity without major benefit for a 25-line snippet. v1.7.0+ may extract if it grows. |

## Smoke test growth target

365 baseline (post v1.6.1) + 15 new = **~380 passing, 0 failing**.

## Effort estimate (honest)

| Phase | Time |
|---|---|
| Cycle plan (this draft) | ~30 min (done) |
| Red phase: write 15 RED tests | 1.5h |
| Green phase: implement AC1-AC6 | 3h |
| /second-opinion review (4-6 rounds expected) | 4-6h |
| Adjudication artifacts | 1h |
| Total elapsed | **~10-11h** |

Realistic; matches the v1.6.2 budget agreed in the prior turn.
