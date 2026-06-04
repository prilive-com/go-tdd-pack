# Postmortem — v2.1.0 first-cycle crashes

> Status: resolved in **v2.1.1** (2026-06-04).
> Authors: maintainer + assist.
> Format follows `.claude/skills/postmortem-fix/SKILL.md`.

---

## TL;DR

v2.1.0 shipped with **two compounded crashing bugs** that prevented every
fresh adopter from completing a single review cycle on a ChatGPT
subscription account. Caught by the pre-release dev test before any
non-test adopter ran the release. Hotfix v2.1.1 landed Latest **~1.5
hours** after the dev's report. No data loss, no silent corruption, no
known external impact.

The interesting question is not "what were the bugs" — it is **"what
control was supposed to catch them and didn't"**.

---

## Timeline (UTC)

| When | What |
|---|---|
| 2026-06-03 20:48 | v2.1.0 tagged + GitHub Release published as Latest. |
| 2026-06-04 ~12:00 | Dev test starts the v2.0.x → v2.1.0 upgrade procedure (a real adopter project on a ChatGPT subscription). |
| 2026-06-04 ~18:00 | Dev hits HTTP 400 `invalid_json_schema` on first runner cycle. Identifies missing `raised_by_angle` in `required`. Hot-patches locally. |
| 2026-06-04 ~19:00 | Dev hits HTTP 400 on the post-schema-fix retry. Identifies `gpt-5.3-codex` model not on ChatGPT-subscription auth. Hot-patches `model = "gpt-5.5"`. Live cycle converges round 2. |
| 2026-06-04 ~21:30 | Dev report received with both findings + reproduction artifacts. |
| 2026-06-04 21:35 | Maintainer verifies both bugs against shipped tree. v2.1.0 marked GitHub pre-release with warning banner. |
| 2026-06-04 22:00 | v2.1.1 hotfix branch + PR opened (#36). |
| 2026-06-04 22:25 | PR merged after CI green. |
| 2026-06-04 22:27 | v2.1.1 tagged and published as Latest. v2.1.0 banner updated with active link to v2.1.1. |

**Latest-badge exposure of broken v2.1.0:** ~25.5 hours.
**Known external installs in that window:** zero (no adopters except
the test dev had been told v2.1.0 was published).

---

## Bug 1 — Round-1 schema rejected by OpenAI strict mode

### 1. User-visible failure

Every first runner cycle on v2.1.0 errored:
`codex exec --output-schema` returned HTTP 400 `invalid_json_schema`
before any review work began. The runner exited with a generic
"Codex call failed" message; no findings were produced.

### 2. Root cause

- **Symptom**: HTTP 400 on `codex exec --output-schema` against
  `schemas/findings-round1.schema.json` on the very first runner call.
- **Proximate cause**: In `properties.findings.items`, the field
  `raised_by_angle` was declared under `properties` but omitted from
  `required`, while `additionalProperties: false` was set on the same
  node.
- **Root cause**: OpenAI Structured Outputs strict-mode rule —
  "every property MUST appear in `required` when
  `additionalProperties: false`" — was not enforced anywhere in the
  pack. We knew the rule existed (we use strict mode deliberately for
  reviewer-output safety); we did not have a guard that asserted the
  invariant holds across our schemas.

The drift was introduced in v2.1 PR #27 (perspective-diverse
infrastructure). The PR added `raised_by_angle` as a *transitional*
field — the parallel producer that fills it ships in v2.2; in v2.1 it
is foundation-only and optional. The PR author added it as optional
(not in `required`) on that semantic basis. That is the correct
JSON-Schema-as-spec decision, but **OpenAI strict mode does not allow
optional fields next to `additionalProperties: false`**. The semantic
intent and the strict-mode validator disagree.

The schema parsed as valid JSON. It validated as valid JSON Schema.
The bug only manifested when the OpenAI validator ran it.

### 3. What control failed

Multiple, layered:

- **Missing invariant.** No smoke asserted the OpenAI strict-mode
  rule across our schemas. `smoke-carveout-schema-consistency.sh`
  (added in #30) checks a narrower invariant (engine carve-out ⊆
  schema enum), not this one.
- **Missing live test on the post-merge clean tree.**
  `test/smoke-v2-mvp.sh` and `test/smoke-v2-phase2-live.sh` make a
  real `codex exec --output-schema` call and would have caught this
  on the first attempt. Both have a dirty-tree guard: they refuse to
  run while uncommitted changes exist. Every cleanup PR had pending
  changes during its smoke runs, so the live smokes were never run
  against the post-merge clean v2.1.0 state.
- **Missing CI integration of the live smoke.** The live smokes
  require valid `codex login` auth and incur real API cost, so they
  are not part of the `test` CI job. There is no other gated path
  that runs them.
- **Missing PR-review checklist item.** PR #27 added a new schema
  field. The PR review confirmed the *semantic* correctness ("yes,
  this is foundation-only for v2.1") but did not separately verify
  the *strict-mode* correctness.

### 4. Prevention patch (multi-layer)

| Layer | Patch | Status |
|---|---|---|
| Code fix | Add `raised_by_angle` to `required` in `schemas/findings-round1.schema.json`. | Shipped in v2.1.1. |
| Test | New `test/smoke-schema-strict-mode.sh` walks every file in `schemas/` and asserts the OpenAI strict-mode invariant (`properties ⊆ required` when `additionalProperties: false`) on every object node, including nested ones. Counterfactual-verified: reverting the v2.1.1 fix causes the smoke to fail with the exact missing-field name and JSON path. | Shipped in v2.1.1. |
| Invariant | The new smoke encodes the OpenAI rule directly. It will catch the same class of bug for every future schema and every nested object in existing schemas. | Shipped in v2.1.1. |
| Process | Run the live smokes (`smoke-v2-mvp.sh` + `smoke-v2-phase2-live.sh`) against a clean post-merge tree before tagging any release. Document the SHA of the commit they ran against. **Open action (A1, A2 below).** | Pending. |

### 5. Prevention summary

The failure was a schema strict-mode violation that ships valid as
JSON but rejects when run through OpenAI's Structured Outputs
validator. The control gap was a missing invariant smoke. v2.1.1 ships
that smoke; it walks every schema, on every object node, and asserts
the rule. The same class of bug cannot ship again without the smoke
catching it. To know the prevention worked: watch that
`smoke-schema-strict-mode.sh` runs in CI on every PR that touches
`schemas/`.

---

## Bug 2 — Codex CLI default model crashed ChatGPT-subscription auth

### 1. User-visible failure

After fixing Bug 1 (or in fresh installs that somehow avoided it), the
runner failed with HTTP 400 from Codex: the model `gpt-5.3-codex`
returned "model not available on this auth method" against ChatGPT
subscription accounts (Plus, Pro, Team).

### 2. Root cause

- **Symptom**: HTTP 400 from Codex on every first runner cycle for
  ChatGPT subscription adopters.
- **Proximate cause**: `tdd-pack.toml` shipped `model = ""`. The
  runner interprets `""` as "do not pass `--model`", so Codex CLI
  picks its own default. Codex CLI **0.130** changed that default to
  `gpt-5.3-codex`, which is paid-only on the API and rejects
  ChatGPT-subscription auth.
- **Root cause**: We pinned a *behavior* (`""` = "track upstream
  default") instead of a *value*. That contract was an implicit
  promise from upstream — and upstream broke it. We had no smoke and
  no contract check that the resolved model is reachable on the
  target auth mode.

This is NOT a regression in our code. The contract was valid at v2.1.0
ship time (Codex CLI 0.129's default *was* subscription-supported).
The contract was an upstream promise that broke between releases. We
chose a fragile contract.

### 3. What control failed

- **Missing invariant.** No smoke asserted the shipped `model` value
  is a concrete, verified model id (vs an empty string deferring to
  upstream).
- **Missing upstream-version pin.** CI did not pin a Codex CLI
  version, so testers may have run against different CLI defaults at
  different times. The same `model = ""` would have worked on Codex
  CLI 0.129 and crashed on 0.130. We had no way to detect the drift.
- **Missing policy.** The pack had no written stance on whether to
  pin model versions or track upstream. Both have costs; we chose
  "track" by default without recording the failure mode.

### 4. Prevention patch (multi-layer)

| Layer | Patch | Status |
|---|---|---|
| Code fix | Pin `model = "gpt-5.5"` in `tdd-pack.toml` (verified on ChatGPT subscription + API-key auth). | Shipped in v2.1.1. |
| Test | Expand `test/smoke-config-default-consistency.sh` with check #3 — assert shipped `model` is non-empty. Adopters who want "track CLI default" can set `""` themselves; the shipped default must always be a concrete verified model. | Shipped in v2.1.1. |
| Invariant | The check #3 above encodes the "never ship empty model" rule directly. | Shipped in v2.1.1. |
| Documentation | The new `tdd-pack.toml` comment block explains the v2.1.0 failure mode and documents how to opt back into "track upstream default" if you have verified your auth mode supports whatever Codex ships. | Shipped in v2.1.1. |
| Policy | Document the upstream-dependency stance: pin verified versions by default, opt-in to "track default" with a written acceptance of the failure mode. **Open action (A3 below).** | Pending. |

### 5. Prevention summary

The failure was a broken upstream contract: Codex CLI 0.130 changed
its default to a model our auth mode rejects. The control gap was a
missing invariant that the shipped `model` must be a concrete value.
v2.1.1 ships that invariant; the smoke now blocks any release that
tries to revert to `model = ""`. To know the prevention worked: the
smoke fires green on every PR that touches `tdd-pack.toml`.

---

## What worked

These behaviours are why this stayed a near-miss instead of an outage:

- **The pre-release dev test was real.** We treated v2.1.0 as
  pre-release until a developer ran the upgrade procedure on a real
  adopter project. The test was not a CI artifact — it was a person
  doing the actual install, on the actual auth mode an adopter would
  use. That test caught what every layer of automated checks missed.
- **The dev hot-patched and kept going.** Instead of stopping at Bug
  1, the dev fixed it locally, hit Bug 2, fixed that too, and
  reported both compounded with reproduction. Two bugs in one round-
  trip, not two round-trips.
- **Hotfix turnaround was tight (~1.5 hours, report → Latest).**
  Verifying the bugs against the shipped tree, marking pre-release,
  branch, fixes, counterfactual-verified smokes, CHANGELOG, PR, CI,
  merge, tag, release — done in one session. The bottleneck was
  reviewer + CI time, not our work.
- **Tag-protection ruleset forced the right move.** We could not
  delete v2.1.0 even if we had wanted to (we did not). The forcing
  function — "v2.1.0 stays tagged forever; you can only mark it
  pre-release and ship v2.1.1" — produced the correct adopter
  experience without any judgment call.
- **Counterfactual verification of the new smoke.** Before the smoke
  was committed, we re-introduced the exact v2.1.0 bug in a
  temporary tree and confirmed the smoke fails with the right
  message. The smoke is not just "tests pass on the fixed code" — it
  is "tests fail on the buggy code, with a useful failure message".

---

## What didn't work

- **Live smokes never ran against post-merge clean state.** The
  dirty-tree guard on `smoke-v2-mvp.sh` and `smoke-v2-phase2-live.sh`
  is correct (it stops the smoke from reviewing your in-progress
  changes by accident), but it has a side effect: during a sequence
  of cleanup PRs, the smokes are never in a runnable state. After
  the last PR merged and `main` was clean, we did not re-run the
  live smokes against the new `main` before tagging. Bug 1 would
  have been caught at that point.
- **Schema validity was checked, but only as JSON Schema, not as
  OpenAI strict mode.** The pack ships under OpenAI strict-mode
  contract; nothing enforces that contract.
- **Model contract was opaque.** `model = ""` looks fine in review
  — a reviewer would assume "the runner has a sensible default".
  There was no place where someone could see "the shipped default
  resolves to `<concrete model id>`". Drift was therefore invisible.
- **Latest-badge window.** v2.1.0 sat as Latest for ~25.5 hours
  before getting demoted. Pure luck that no external adopter
  installed in that window. We need a tighter pattern for "publish
  release → public marketplace bump" so the window is structurally
  short or guarded.

---

## Action items (carried forward)

Status: **A1** and **A2** are the highest-leverage. **A3** is process
hygiene. **A4** is medium-term. **A5** is a v2.3+ research item.

| ID | Action | Owner | Done? |
|---|---|---|---|
| A1 | Run `bash test/smoke-v2-mvp.sh && bash test/smoke-v2-phase2-live.sh` against `main` immediately after the release-cut PR merges and BEFORE tagging. Block the tag if either fails. | maintainer | pending |
| A2 | Add a `docs/RELEASE_CHECKLIST.md` (or extend the existing release-flow doc) that lists A1 explicitly. Mention this postmortem as the rationale. | maintainer | pending |
| A3 | Write a one-pager `docs/UPSTREAM_DEPENDENCY_POLICY.md` covering: when we pin upstream version vs track default, how to record the trade-off, and how to detect drift. Cover Codex CLI, OpenAI models, golangci-lint, staticcheck. | maintainer | pending |
| A4 | Consider gating the GitHub Release publish on a `LIVE_SMOKE_PASSED` workflow artifact stamped against the same SHA as the tag. Forces structural coupling between live smoke + release. | maintainer | pending |
| A5 | Research dynamic model selection: query the auth backend's accessible models at session start, pick the highest-capability supported model automatically. Removes the pin/track tradeoff entirely. Probably needs a `codex models` call we cache per session. | maintainer | v2.3+ |

---

## Prevention summary (one paragraph for the whole incident)

v2.1.0 shipped with a schema that violated OpenAI strict mode and a
config default that depended on an upstream contract we couldn't
enforce. Two control gaps allowed both: (a) we had no invariant smoke
encoding the strict-mode rule, and (b) we had no invariant smoke
enforcing that the shipped `model` value is concrete. v2.1.1 ships
both invariants as smokes, both counterfactual-verified to catch the
exact original bugs. The remaining open work is process — running the
live Codex smokes against a clean post-merge tree before every tag
(A1, A2), and writing down an upstream-dependency policy (A3) so the
next "let upstream pick" decision is made with eyes open. To know the
prevention worked: every v2.x.y release from v2.1.1 onward should
have its `smoke-schema-strict-mode.sh` green in CI and its live
smokes timestamped against the post-merge SHA.
