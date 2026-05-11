# TDD Discipline Rules

## When TDD ceremony applies

The full ceremony (spec → APPROVED SPEC → red → APPROVED GREEN → green →
APPROVED IMPLEMENTATION → commit) is **required** for any path matched by
`tier1_path_regexes` in `.tdd/tdd-config.json`. The `require-tdd-state.sh`
and `require-second-opinion.sh` hooks gate edits; the `gate-tier1-commit.sh`
hook gates the green commit.

For code outside Tier 1, lighter discipline applies:
- Red-before-green for fixes that have a tractable test surface.
- Race-detector green before any commit touching goroutine code.
- Integration tests for cross-module workflows.

## The three gates

The Tier 1 ceremony has **three** operator-approval gates. Each gate has
a distinct command (plain `APPROVED` is also accepted; the model infers
which gate based on which marker is next-pending).

**Gate 1 — Spec.** After the model writes `.tdd/current-plan.md` with the
spec sections filled in. The operator replies:
- `APPROVED SPEC` (or plain `APPROVED`) — model proceeds to red phase.
- `CHANGES <reason>` — model revises the spec.
- `STOP` — model halts the cycle.

**Gate 2 — Red proof and green authorization.** After failing tests are
committed and verbatim output is captured in `.tdd/red-proof.md`. The
operator's reply has TWO meanings: red proof is valid AND green phase is
authorized. This is one operator decision, not two.
- `APPROVED GREEN` (or plain `APPROVED`) — model sets `Green phase
  authorized: yes` and proceeds to write production code.
- `CHANGES <reason>` — model revises the red proof or the spec (see
  "Editing tests in green phase" under Forbidden below).
- `STOP` — model halts.

**Gate 3 — Implementation review.** After the green code is written,
tests pass, `.tdd/green-proof.md` is captured, and `/second-opinion diff`
has produced a fresh adjudication artifact. The operator reads the diff
and the adjudication, then replies:
- `APPROVED IMPLEMENTATION` (or plain `APPROVED`) — model sets
  `Implementation reviewed: yes`, then `git commit` is allowed by the
  commit gate.
- `CHANGES <reason>` — model revises the implementation.
- `STOP` — model halts.

## Plan markers

The hook checks markers in `.tdd/tdd-config.json`. Edit-time hooks
require the first three; the commit-time hook requires all four.

| Marker | Set when |
|---|---|
| `Human approved spec: yes` | After operator says APPROVED at gate 1 |
| `Red phase confirmed: yes` | After `.tdd/red-proof.md` is on disk and tests run RED (model sets this autonomously when the artifact exists) |
| `Green phase authorized: yes` | After operator says APPROVED at gate 2 |
| `Implementation reviewed: yes` | After operator says APPROVED at gate 3 |

Set any marker to `yes` ONLY after the matching operator `APPROVED` reply.
Self-setting a marker without an explicit human reply is forbidden.

**Backwards-compat alias:** the old marker name `Human approved
implementation: yes` is honored as `Green phase authorized: yes` for one
minor version, with a stderr deprecation warning. Run
`scripts/migrate-tdd-markers.sh` on any in-flight plan to update.

## Commit naming

For TDD cycles, commits follow this convention (CI verifies the pairs
exist for Tier 1 paths):

- `red(<id>): <description>` — failing-test commit (exempt from the
  commit gate — it IS the red phase commit)
- `green(<id>): <description>` — implementation commit (gated; requires
  `Implementation reviewed: yes`)
- `refactor(<id>): <description>` — non-behavioral improvement (gated;
  refactors are post-green and need M4)

The `<id>` is a short slug shared across all commits in the cycle
(e.g. `auth-token-rotation`).

## Forbidden

- **Self-approving.** Never set any marker to `yes` without an explicit
  operator `APPROVED` reply at the corresponding gate. Setting markers
  on your own initiative defeats the gate's purpose. The hook's deny
  message tells you which marker is next; ASK the operator, do not
  self-approve.
- **Editing tests in green phase.** If tests need changes, the spec was
  incomplete. STOP, return to red phase. The model can return to red
  by asking the operator to set `Red phase confirmed: no` and approve
  a revised spec; it cannot edit `_test.go` files after `Red phase
  confirmed: yes` is set (the test-file policy in the config blocks
  that path by default).
- **Paraphrasing red proof.** The verbatim test output is the artifact
  that proves the test ran and failed.
- **False reds.** The `red-proof.md` must include the
  "Why this is not a false red" section — explaining why the failure is
  genuine, not a test setup error, missing dependency, typo, or unrelated
  broken code.
- **Skipping `/second-opinion diff` for Tier 1 green commits.** The
  commit gate requires a fresh adjudication artifact (mtime <60min). If
  you skip the diff review, the commit hook denies and tells you to
  re-run.

- **Modifying hook scripts mid-cycle to unblock yourself.** If a gate
  creates a logical deadlock you cannot resolve through the documented
  flows (return-to-red, killswitch env vars, config flag overrides),
  STOP and surface it to the operator. Do NOT patch
  `.claude/hooks/*.sh` to make a deny go away. Hook scripts are
  governance infrastructure; patching them mid-cycle is unauthorized
  modification of the project's safety controls.

  The escape hatch is operator authorization, not Claude's edit. The
  operator can:
  - flip a config flag in `.tdd/tdd-config.json` (e.g.,
    `test_file_policy.allow_after_red_confirmed: true` for return-to-
    red emergencies) with the reason in the commit message,
  - set a killswitch env var (`SECOND_OPINION_DISABLE=1`,
    `TDD_COMMIT_GATE_DISABLE=1`, `SECOND_OPINION_PASS_A_DISABLE=1`)
    for a one-off,
  - or update the gate design upstream when the deadlock is real and
    repeatable.

  If you see a deny that you believe represents a true deadlock (no
  documented path forward), report it. The hook's design is wrong, not
  your workflow.

## What APPROVED means at each gate

Operators may use either the explicit gate-specific command or plain
`APPROVED` at any gate. The model infers which gate from the next-pending
marker. Use the explicit form for audit clarity in security-sensitive
cycles.

| Operator says | At which gate | Model does |
|---|---|---|
| `APPROVED SPEC` or plain `APPROVED` | Gate 1 (spec drafted) | Set M1 = yes; proceed to red phase |
| `APPROVED GREEN` or plain `APPROVED` | Gate 2 (red proof captured) | Set M3 = yes; proceed to green phase |
| `APPROVED IMPLEMENTATION` or plain `APPROVED` | Gate 3 (green proof + adjudication ready) | Set M4 = yes; allow commit |

## v1.6.0 — anchoring-resistant review (Tier 1, opt-in)

v1.6.0 adds three Tier-1-only artifacts that close the **anchoring**
failure mode in `/second-opinion`. All three default OFF for safe
rollout; flip the corresponding flag in `.tdd/tdd-config.json` after
your eval-harness shows value for your codebase.

### Artifacts

- **`.tdd/research-packet.md`** (Tier 1 plans only — flag
  `second_opinion.require_research_packet_tier1`).
  Required ≥3 authoritative sources. Anchors Codex's review against the
  same evidence the implementer consulted. Template at
  `.tdd/templates/research-packet-template.md`.

- **`.tdd/codex/independent-design.md`** (Tier 1 only — flag
  `second_opinion.require_pass_a_tier1`).
  Codex's OWN design generated BEFORE seeing Claude's plan ("Pass A").
  Anchors Codex's later review on its own thinking, not on Claude's
  framing. The skill writes this automatically when Pass A runs;
  killswitch via `SECOND_OPINION_PASS_A_DISABLE=1`.

- **`.tdd/codex/disposition-matrix.md`** (Tier 1 only — flag
  `second_opinion.require_disposition_matrix_tier1`).
  Per-finding disposition table. Replaces the v1.5.x free-form
  rebuttal area. Mandatory disposition for EVERY Codex finding;
  hook validates row count == finding count. Template at
  `.tdd/templates/disposition-matrix-template.md`.

### Why three flags, not one

Each artifact is independently motivated:
- The research packet improves spec-phase research discipline (no
  Codex required).
- Pass A is the only one whose value is hypothesis-until-measured (the
  literature direction is favorable; codebase-specific value is
  unproven). Treat as the conditionally-shipped piece.
- The matrix sharpens the existing rebuttal artifact (mechanical
  improvement, no LLM behaviour change).

Flip them in any order based on what your trial cycles show. Most
projects will flip the matrix flag first (lowest cost, immediate
discipline gain), then the packet (one-time spec-phase habit), then
Pass A last (highest-value if the eval shows it works).

### Full design rationale

See [`docs/specs/second-opinion-v1.6.0-spec.md`](../../docs/specs/second-opinion-v1.6.0-spec.md).

## Known reviewer-drift findings

Codex's training data lags the pack's schema. Pre-v1.6.0 plans used
the marker name `Human approved implementation: yes` for the M3 gate.
v1.6.0 renamed it to `Green phase authorized: yes` (the operator's
APPROVED GREEN reply) and added `Implementation reviewed: yes` (the
operator's APPROVED IMPLEMENTATION reply). Both old-name uses are
recorded in `.tdd/tdd-config.json` `marker_aliases` for backwards
compatibility. Codex doesn't know about the rename and routinely
returns P1 findings of the form "the plan declares the wrong marker
vocabulary" when reviewing v1.6.0+ plans.

This section catalogs known drift patterns that the
`/second-opinion` skill's preprocessor flags with
`auto_pushback_eligible: true` + a `canonical_citation`. The agent
may use the short-form PUSHBACK template below for these specific
cases ONLY; full PUSHBACK essay is required for any finding the
preprocessor did not flag.

### Pattern: `marker_name_drift_v1.6.0`

Codex returns a finding asserting the plan's M3 marker should be
`Human approved implementation: yes` (or any phrasing that treats
the v1.5.x marker name as authoritative). The schema-context block
in the prompt template (generated from
`.tdd/tdd-config.json` by `scripts/tdd/build-second-opinion-context.sh`)
should reduce these findings at the source; when one slips through,
this short-form PUSHBACK is sufficient.

### Short-form PUSHBACK template

When the preprocessor flagged `auto_pushback_eligible: true` AND the
finding matches `marker_name_drift_v1.6.0`, the disposition matrix
"Reason" column may be:

```
PUSHBACK on training-data drift. v1.6.0 renamed this marker.
See .tdd/tdd-config.json field <field-name> at line <N>:
"Green phase authorized: yes" is the canonical M3 marker.
"Human approved implementation: yes" is recorded in marker_aliases
as the deprecated alias only. The plan is correct as written.
```

The agent MUST cite local evidence: the field name AND the line
number from `.tdd/tdd-config.json`. The auto-flag is permission to
SKIP the multi-paragraph essay justifying the PUSHBACK; it is NOT
permission to skip evidence. Adjudication discipline (PUSHBACK
requires substantive rationale) is preserved by the
local-evidence requirement.

### Hook-file verification (when the finding cites a path)

The matcher cannot reliably distinguish a real reviewer-drift
finding ("Repo instructions require Human approved implementation:
yes") from a real hook implementation defect ("Repo instructions
require Human approved implementation: yes in
scripts/git-hooks/pre-commit"). Both phrasings match the same
auto-flag pattern. When the finding's `evidence` or `location`
field cites ANY hook/script/file path (regex: matches a
`scripts/`, `.claude/hooks/`, `internal/`, or `cmd/` path), the
agent MUST inspect the cited path before using short-form PUSHBACK:

```
agent verification (mandatory when finding cites a path):
  1. Read the cited file at the cited line range.
  2. Confirm the file does NOT actually require the deprecated
     marker (i.e., the finding's claim about the file is wrong).
  3. ONLY THEN use short-form PUSHBACK with the citation pointing
     at .tdd/tdd-config.json AND noting the cited file was checked.
```

If step 2 fails (the file DOES require the deprecated marker —
real governance defect), the agent must NOT use short-form
PUSHBACK. The finding is real; write a full ACCEPT or full
PUSHBACK essay as appropriate. The auto-flag was a false positive.

### When the preprocessor does NOT fire

Findings about marker names that don't match the documented drift
patterns require full PUSHBACK essay as before. Examples:
- "M2 marker is missing" — could be a real issue, full essay required.
- "Plan markers are not in the order specified" — Codex sees an
  ordering bug, not a vocabulary drift; full essay required.

The preprocessor is conservative by design: better to write a
slightly longer PUSHBACK on a marker-related finding the
preprocessor didn't recognise than to silently fast-track a real
finding.

### Narrow-matching philosophy (operator awareness)

The preprocessor is intentionally narrow. The implementation
matches a much smaller set of phrasings than the documented trigger
("old marker + marker vocabulary") would suggest. This is a
deliberate design choice surfaced across 14 rounds of /second-opinion
review on v1.6.2 itself — each round Codex found a slightly
different drift-adjacent finding the preprocessor was wrongly
fast-tracking. The accumulated exclusions narrow the matcher until
ONLY the canonical "gate-as-subject demands old marker, new marker
not present in the demand context, no compatibility/deprecation/
plan-as-subject vocabulary" pattern matches.

Practical consequence: **many real drift findings will still
require full PUSHBACK essay.** The agent should not expect every
finding mentioning `Human approved implementation` to receive
`auto_pushback_eligible: true`. Examples that the preprocessor
DOES NOT fast-track (intentionally — false negatives are acceptable;
false positives that suppress real signal are NOT):

- "Wrong marker: Green phase authorized should be Human approved
  implementation" — uses `should be` which is too generic.
- "the plan uses Green phase authorized; required marker is Human
  approved implementation" — new-before-old phrasing.
- "Hook scripts/git-hooks/pre-commit requires Human approved
  implementation: yes" — could be a real hook implementation defect.
- "Stale doc reference to Human approved implementation in
  README" — could be real documentation drift.

For these, the agent writes a full PUSHBACK essay (or ACCEPT, if
on inspection the finding is actually correct). The
short-form template is permission to skip the multi-paragraph
rationale ONLY when the preprocessor's narrow matcher fired.

## Typed test-edit exceptions (v1.7.0)

The legacy `test_file_policy.allow_after_red_confirmed` boolean is
DEPRECATED in v1.7.x and will be removed in v2.0.0. The replacement
is the `post_red_mechanical_update` typed-exception system: typed,
operator-authorized, mechanically-validated, auditable per-cycle
exceptions for post-red test-edit work (e.g., signature widening
that breaks 12 pre-existing test call sites).

### When to use a typed exception

- A production-signature change (function widened from `error` to
  `(Result, error)`, struct field added that's accessed in
  `signal.Metadata["X"]`) breaks pre-existing test call sites
  mechanically. The change to test files is structural co-evolution,
  NOT semantic weakening.

- The cycle is in green phase (`Red phase confirmed: yes`), so the
  legacy block kicks in and forbids test edits.

- The operator approves the typed exception with an explicit
  `APPROVED EXCEPTION E-NNN` reply (or batch `APPROVED EXCEPTIONS
  E-001, E-002` / `APPROVED EXCEPTIONS E-001 through E-003`).

### Four accepted exception types (v1.8.0)

- `mechanical_signature_propagation` — function/method signature
  widening; co-evolution of test call sites.
- `compile_fix_only` — type-rename ripple, import path change,
  struct field rename — purely mechanical.
- `import_only` — adding/removing imports without changing test
  semantics.
- `schema_predicate_correction` — pure rename of a struct field
  or symbol everywhere it appears in test predicates (e.g.
  `want.OldField` → `want.NewField`). Requires `--old-name` and
  `--new-name` flags on the grant helper. AST-validated for
  rename-only diffs; any other identifier change rejects.

### Workflow

1. Agent identifies the need for a typed exception.
2. Agent invokes `scripts/tdd/grant-test-edit-exception.sh
   --type ... --paths ... --symbol ... --operations ... --reason ...`
   to write a `pending` entry to
   `.tdd/exceptions/post-red-test-edits.json`.
3. Agent surfaces the entry to the operator and asks
   `APPROVED EXCEPTION E-NNN?`.
4. Operator reviews the entry's scope + reason; replies
   `APPROVED EXCEPTION E-NNN` (or batch syntax).
5. Agent runs `scripts/tdd/grant-test-edit-exception.sh --approve E-NNN`
   to bump status to `approved` and compute binding hashes.
6. The PreToolUse hook (`require-tdd-state.sh`) sees the approved
   exception, routes test-file edits through the validator
   (`scripts/tdd/_lib_test_edit_exception.sh`), allows on validator
   pass, denies on validator fail.
7. Auto-expiry on green-proof.md write (next-green commit).

### Killswitches (v1.8.0)

| Env var | Effect | When to use |
|---|---|---|
| `TEST_EDIT_EXCEPTION_DISABLE=1` | Bypass the entire typed-exception system; hook falls through to legacy boolean. | Emergency-only; document reason in next commit message. |
| `TDD_AST_VALIDATOR_DISABLE=1` | Skip the AST helper checks; validator runs regex-only with stderr warning. | When `go run` is too slow OR the AST helper has a known false-positive on a legitimate edit. Document in commit. |

If `go` is not installed at all, the validator falls back to
regex-only with the same stderr warning — no opt-in needed.
Install Go ≥1.26.2 for stricter governance.

### Per-cycle exception cap (v1.8.0)

`tdd-config.json` `test_file_policy.post_red_mechanical_update.max_per_cycle`
caps the number of approved exceptions per cycle (default `5`;
`0` = no cap). Exceeding the cap disables typed exceptions for
the cycle until either:
- Cycle is reverted to red phase (gate 2) and re-spec'd, OR
- `max_per_cycle` is raised in the same commit with documented
  reason.

### Audit-log integrity (v1.8.0)

Every audit-log line in `.tdd/audit/<cycle-id>.jsonl` carries a
`prev_sha` field (sha256 of the prior line). The hook calls
`scripts/tdd/verify-audit-chain.sh <cycle-id>` at typed-exception
dispatch; chain mismatch fails closed for typed exceptions.

If you need to verify an audit log standalone:
```bash
bash scripts/tdd/verify-audit-chain.sh <cycle-id>
echo $?  # 0 = intact; 1 = tampered; 2 = hard error
```

### Validator limits (v1.8.0)

The validator now AND-gates regex (v1.7.0) with AST (v1.8.0).
AST checks are stricter (catches more); regex checks remain as
defense-in-depth and as the no-Go fallback. Remaining limits:

- AST helper cold-start ~300ms per `go run` invocation. If your
  workflow is sensitive, `go build scripts/tdd/ast/validator.go`
  and the hook will pick up the binary in v1.9.
- `schema_predicate_correction` is line-by-line; multi-line
  refactors must be split.
- Sha-chain detects unsophisticated tampering, not a compromised
  host.

### Migration from the legacy boolean

Each consultation of `allow_after_red_confirmed` emits a stderr
deprecation warning (rate-limited per hook invocation). Operators
should migrate to typed exceptions before v2.0.0 ships.

## Bypass procedure

For an emergency hotfix where the operator vouches for the change:

1. Edit `.tdd/current-plan.md` to set the four required markers to `yes`.
2. Document the bypass reason in the commit message.
3. Open a follow-up issue to add the missing test.
4. The CI `tdd-ceremony-check` job will flag the missing red commit; the
   bypass reason should be in the PR/MR description.

The bypass is for **genuine emergencies only**. Routine cycles should go
through the three gates. Routinizing the bypass weakens the gate's
signal value.
