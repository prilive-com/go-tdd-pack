# FDTDD active-finding marker — filesystem contract

> Scope: closes BLOCKER 3 (Codex addendum 2026-06-08) —
> the v1 proposal alternated between treating
> `.tdd/active-finding` as a JSON file vs a directory, AND
> suggested moving to `.tdd/findings/active.json`. This document
> locks the contract before any code in slice 2+ ships against it.

## Canonical paths (v2)

```
.tdd/findings/
├── active.json                  # the current active marker (JSON file)
├── pending-reason.txt           # §9 fallback (ask/deny reason mirror)
└── closed/
    └── <finding_id>.json        # rotated marker after finding-finish
```

| Path | Lifetime | Writer | Reader | Schema |
|---|---|---|---|---|
| `.tdd/findings/active.json` | finding-start → finding-finish | runner, slash-command helpers (`scripts/tdd/finding-*.sh`) only | hooks, runner, all `finding-*.sh` helpers | `schemas/active-finding.schema.json` (v2) |
| `.tdd/findings/pending-reason.txt` | ask/deny output mirror | gates only | the operator (read in their terminal) | freeform text (~1KB cap) |
| `.tdd/findings/closed/<id>.json` | after finding-finish, indefinitely | finding-finish.sh only | audit, future analytics | same v2 schema (with `phase = "closed"`) |

## Legacy v1 path (back-compat)

```
.tdd/active-finding              # v2.1 PR #26 marker (JSON file)
```

Slice 1 helpers READ this path as a fallback but never WRITE to
it. Migration happens silently on the next `finding-start.sh`
invocation:

1. If `.tdd/findings/active.json` exists → use it (v2 path).
2. Else if `.tdd/active-finding` exists → read it as v1, then:
   - If finding-start.sh was called: refuse with
     "active finding already exists at legacy path; run
     `finding-finish.sh` first to close it cleanly."
   - If a hook called for read-only access: return the v1
     fields with v2 defaults applied:
     - `schema_version: 2`
     - `phase: "red"`
     - `red_proof_accepted: false`
     - `red_proof_record: null`
     - `test_files: []`
     - `prod_files: []`
     - `red_accepted_at: null`
     - `green_started_at: null`
     - `closed_at: null`
     - `amendments: []`
3. Else → no active finding (back-compat treated identically to
   v2: `active_finding_present` returns 1, etc.).

**Why no auto-migration on hook reads:** preserving the legacy
file as long as it exists keeps the v2.1 finish path
(`rm .tdd/active-finding`) working for any operator who
downgrades or who has an external script. After
`finding-finish.sh` runs on a legacy marker, the legacy file is
deleted.

**Why refuse vs migrate on finding-start:** ambiguity. If the
operator runs `finding-start` while a v1 marker exists, it could
mean (a) "I forgot to finish the last one — same finding
continued" or (b) "I started a new task and the old marker is
stale." The pack refuses to guess; the operator runs
`finding-finish` (legacy-aware) and then re-runs `finding-start`
with a fresh ID. Slice 1's `finding-finish.sh` accepts the
legacy path so this is always one command away.

## Schema versioning

- **v1 (schema_version: 1)** — v2.1 PR #26. Fields: `schema_version`,
  `finding_id`, `mode`, `started_at`, `red_proof`, `red_proof_hash`.
  Read-only support remains for one major (through v2.x). Removed
  in v3.0.
- **v2 (schema_version: 2)** — FDTDD Stage 1 slice 1. Adds `tier`,
  `phase`, `red_proof_accepted`, `red_proof_record`, `test_files`,
  `prod_files`, `red_accepted_at`, `green_started_at`, `closed_at`,
  `amendments`. The `mode` field from v1 is dropped (its semantic
  role moves to `phase` + `red_proof_accepted` + `test_files`).
  See `schemas/active-finding.schema.json`.

The v1 `mode` field deserves a callout: in v1 it carried a single
value `"green_fix"` set by `finding-start.sh`. v2 supersedes it
with the richer `phase` axis (`red` / `green` / `refactor` /
`closed`). Backward-compat reads default v1 markers to
`phase: "red"` — INTENTIONAL: a v2.1-era marker did NOT carry
mechanical Red proof (BLOCKER 2 wasn't fixed yet), so treating it
as "Red proof not yet accepted" is the correct conservative
default. Operators upgrading mid-finding will see Gate 1 deny
their next Tier-1 prod edit until they `finding-accept-red.sh`
the test file — which is the intended Stage 1 behavior, not a
regression.

## §9 file-fallback shape

```
.tdd/findings/pending-reason.txt    (overwritten per gate fire; not appended)
```

Mirrors the v2.2 ops-triage pattern at
`.tdd/ops-triage/pending-reason.txt`. Slice 6 of Stage 1 wires
gates to write to this file alongside emitting
`permissionDecisionReason` (defense against Claude Code issue
#55889).

Slice 1 ships the contract; slice 6 ships the implementation.

## Hook protection

All paths under `.tdd/findings/` are protected against direct
Claude edits by `hooks/protect-tdd-artifacts.sh:123`
(PROTECTED_PREFIXES). The v2.2 slice 5 PR added this; slice 1
verifies it (see `docs/FDTDD-SLICE1-PRECHECKLIST.md` Claim 2)
and ships no further hook changes for protection.

Read access for hooks is unmediated — they source
`runner/lib/active-finding.sh` and use its accessors.

## Atomicity

`finding-start.sh` and `finding-finish.sh` write via
`mktemp` + `mv` (POSIX atomic rename within the same filesystem)
to ensure no hook ever observes a half-written marker. The
legacy v1 path used the same pattern; v2 retains it.

The `closed/` rotation is `mv` from `active.json` to
`closed/<id>.json`. If `closed/` doesn't exist, `finding-finish.sh`
creates it first; the rotation is then atomic.

## Validation

Every write of `active.json` is validated against
`schemas/active-finding.schema.json` before the temp file is
renamed into place. Helpers refuse to write an invalid marker.

`test/smoke-fdtdd-marker-schema.sh` covers:

- Valid v2 marker passes.
- Marker missing a required field fails.
- Marker with an unknown extra field fails (strict-mode).
- A v1 marker (no v2 fields) passes BACKWARD-COMPAT READ but
  fails STRICT v2 SCHEMA — the contract for v1 markers is that
  they are read-only; helpers never write a v1 marker.

`test/smoke-fdtdd-backward-compat.sh` covers:

- A pre-existing legacy `.tdd/active-finding` is readable via
  `active_finding_*` accessors.
- `finding-finish.sh` removes the legacy file cleanly.
- `finding-start.sh` after a clean state writes only to
  `.tdd/findings/active.json` (never to the legacy path).

## Forward compatibility (Stage 2+)

The v2 schema is forward-compatible. Stage 2 Gates (e.g. Gate 2
= at least one assertion before Green) can extend it by adding
NEW required fields and bumping `schema_version` to 3. Slice 1
helpers will refuse to read a v3 marker until a future helper
upgrade — explicit, not silent, schema mismatch.
