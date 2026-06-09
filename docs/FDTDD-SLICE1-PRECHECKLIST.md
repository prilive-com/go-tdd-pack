# FDTDD Stage 1 slice 1 — pre-checklist results

> Scope: closes MAJOR M5 (Codex addendum 2026-06-08) — every
> load-bearing claim from `PROPOSAL-fdtdd-stage1-rails.md` must
> be empirically verified before slice 1 ships, with exact file /
> command references for each.

Survey performed against `main` at commit `e3a65af` (post #107
slice 1 merge), 2026-06-09.

## Claim 1 — "`review.mode` already accepts `governed_tdd` / `strict_tdd`"

Source: proposal §5 line 223–224, plus M5 ("load-bearing claims
unverified").

**Verdict: PARTIALLY VERIFIED — consumers exist, but the
`tdd-pack.toml` template did not document the field.**

Where it is consumed:

- `hooks/inject-findings.sh:143` reads `review.mode` via
  `cfg_get` with default `"governed_tdd"`.
- `hooks/inject-findings.sh:278` branches on
  `REVIEW_MODE == "strict_tdd" || == "governed_tdd"` to inject
  mode-aware guidance.
- `docs/UPDATE_NOTES_v2.0-to-v2.1.md:174` documents `[review] mode`
  as a v2.1 addition with `"governed_tdd"` implicit default.
- `CHANGELOG.md:317` documents the `strict_tdd`/`governed_tdd` rail.

Where it is missing:

- `tdd-pack.toml` does NOT declare `[review] mode` explicitly.
  The only `mode = ...` line in the shipped template is at
  `tdd-pack.toml:186` under `[ops_triage]`, with values
  `off | observe | ask | governed` — a DIFFERENT rail with
  different values.

**Resolution in this slice:** add an explicit `mode` line to
`[review]` in `tdd-pack.toml` with the 4-value enum + default
`"soft"`. This closes the doc gap before slice 2 ships Gate 1,
so adopters see the field documented before any hook starts
gating on it.

Why default `"soft"` and not `"governed_tdd"`: per addendum M5's
revised slice plan (slice 2 = "Gate 1 ready-but-not-active in
soft mode"), the gate ships in soft first and ratchets to
governed/strict in slice 3. The default value reflects what slice
2 ships, not what the rail aspires to.

## Claim 2 — "Gate 4 protects the marker"

Source: proposal §11 line 372 (the marker location decision) +
M5 load-bearing claim.

**Verdict: VERIFIED — already protected by an earlier v2.2 slice.**

`hooks/protect-tdd-artifacts.sh:123-129` PROTECTED_PREFIXES array:

```bash
PROTECTED_PREFIXES=(
  ".tdd/findings/"
  ".tdd/queue/"
  ".tdd/ops-triage/"
  ".tdd/ops-preflight/"
  ".tdd/ops-debt/"
)
```

The v2.2 slice 5 added `.tdd/findings/` as part of the ops-triage
artifact protection. Any direct Claude edit to a path under
`.tdd/findings/` (which is exactly where the v2 marker lives —
`.tdd/findings/active.json`) is denied with the message:

> Engine path: use the runner or a slash command (e.g.
> /accept-claude, /accept-codex, /abandon-review, /ops-preflight).

**Implication for slice 1:** no edit to `protect-tdd-artifacts.sh`
is needed. The BLOCKER 3 filesystem-contract decision
(`.tdd/findings/active.json` + sibling `pending-reason.txt`)
aligns the marker with an already-protected prefix.

What is NOT protected: the LEGACY `.tdd/active-finding` path used
by v2.1 PR #26. Slice 1's migration shim moves any pre-existing
v1 marker into `.tdd/findings/` on the first invocation of
`finding-start.sh`. After migration, the legacy path is empty
and protection becomes moot.

Covered by smoke: `test/smoke-protect-tdd-artifacts.sh` already
asserts denial on `.tdd/findings/*`. Counterfactually verified
during the v2.2 slice 5 PR.

## Claim 3 — "`permissionDecisionReason` may not render"

Source: proposal §8 line 285–289 (rationale for the §9 file
fallback pattern shared with v2.2 ops-triage).

**Verdict: VERIFIED — known upstream issue, mitigation already
shipped on the parallel rail.**

- Upstream: Claude Code issue #55889 (closed not-planned on
  2026-06-01). Reason: `permissionDecisionReason` from a
  PreToolUse hook is not always surfaced into the operator UI,
  particularly when the hook denies via JSON output rather than
  exit code.
- v2.2 mitigation: ops-triage rail writes ask/deny reasons to
  `.tdd/ops-triage/pending-reason.txt` as a sibling file
  alongside `permissionDecisionReason`. Slice 6 wires the FDTDD
  Stage 1 equivalent at `.tdd/findings/pending-reason.txt`.

**Implication for slice 1:** the contract document
(`FDTDD-MARKER-CONTRACT.md`) locks the §9 fallback path so slice
6's wiring has no ambiguity. No hook code lands in slice 1 —
this is doc-only resolution.

## Claim 4 — `MultiEdit` semantics (M2 empirical task)

Source: addendum MAJOR M2 — "MultiEdit semantics likely wrong.
Claude Code's MultiEdit typically targets ONE `file_path` with
multiple edits, not multiple files."

**Verdict: VERIFIED via Claude Code official docs +
constructed-payload fixture.**

The official Claude Code tool reference confirms `MultiEdit`
takes a SINGLE `file_path` plus an `edits` array (each entry
being `{old_string, new_string, replace_all?}`), not multiple
file paths. PreToolUse hooks see one tool invocation per
`MultiEdit` call, with `tool_input.file_path` (single string) and
`tool_input.edits[].new_string` for content scanning.

Slice 1 ships documented payload fixtures at
`test/fixtures/pretooluse-payloads/`:

- `edit.json` — Edit tool (single-file, single replacement)
- `write.json` — Write tool (single-file, full content)
- `multi-edit.json` — MultiEdit tool (single-file, multi-edit)

Each fixture is annotated with the source of the schema (Claude
Code tool reference docs at `code.claude.com/docs/en/tools`).
Slice 2 will refine these to literal-captured payloads from a
live capture hook — the slice 2 PR description must call out any
divergence from the slice 1 spec fixtures.

**Implication for slice 1:** the gate parser spec in §3 of
`FDTDD-MARKER-CONTRACT.md` treats `MultiEdit` as single-file.
Gate 1 / Gate 3 read `tool_input.file_path` directly; no
multi-file fan-out. The v1 proposal's "check ALL of them and
deny if ANY would be denied" requirement is **dropped**.

## Out of scope (already true, no action)

- Marker JSON format (`{...}` not `{...}` plus dir) — locked to
  JSON file by `FDTDD-MARKER-CONTRACT.md`.
- Tier-1 detection — depends on `runner/lib/tier1.sh`, untouched
  in slice 1.
- One-active-finding assumption — preserved in slice 1 per
  proposal §11 line 373–375. Parallel findings = v2.4+ question.

## Slice 1 ships

Based on the above:

1. `schemas/active-finding.schema.json` — JSON Schema for the
   v2 marker. Strict-mode compliant. Auto-picked-up by
   `test/smoke-schema-strict-mode.sh`.
2. `docs/FDTDD-MARKER-CONTRACT.md` — filesystem contract +
   backward-compat read rules + migration shim spec.
3. `docs/FDTDD-SLICE1-PRECHECKLIST.md` — this file.
4. `tdd-pack.toml` — add `[review] mode = "soft"` (closes Claim 1
   doc gap).
5. `runner/lib/active-finding.sh` — v2 accessors with v1
   fallback reads.
6. `scripts/tdd/finding-start.sh` — write v2 schema; silent
   migration from `.tdd/active-finding` to
   `.tdd/findings/active.json`.
7. `scripts/tdd/finding-finish.sh` — close v2 marker; rotate
   to `.tdd/findings/closed/<id>.json`; remove legacy path.
8. `test/smoke-fdtdd-marker-schema.sh` — counterfactual schema
   smoke (valid, invalid extra field, invalid missing required,
   v1 backward-compat read).
9. `test/smoke-fdtdd-backward-compat.sh` — v1 marker at legacy
   path migrates to v2 path on first finding-start.
10. `test/fixtures/pretooluse-payloads/` — documented Edit /
    Write / MultiEdit payloads with capture procedure for slice
    2 refinement.

What slice 1 does **NOT** ship (per the addendum revised slice
plan, lines 502–510):

- Gate 1 (`hooks/gate-fdtdd-red-required.sh`) — slice 2.
- Gate 3 (`hooks/gate-fdtdd-test-lock.sh`) — slice 4.
- `finding-accept-red.sh` — slice 2 (with M2 mechanical test
  run + BLOCKER 1 required prod_files).
- `finding-restart-red.sh` / `finding-amend-red.sh` — slice 4.
- §9 file-fallback wiring — slice 6.
- Adopter upgrade notes — slice 7.
