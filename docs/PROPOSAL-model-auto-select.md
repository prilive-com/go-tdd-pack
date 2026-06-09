# Proposal — `model = "auto"` runner-side resolution from Codex CLI cache

> Status: **draft for proposal-review** per
> `docs/RELEASE_GUIDE.md` § Pre-implementation discipline.
> Run `scripts/review/proposal-review.sh
> docs/PROPOSAL-model-auto-select.md` before slicing.

## 0. Origin

v2.1.0 shipped `model = ""` so adopters got "whatever Codex CLI
defaults to" — the assumption was that Codex CLI's default would
always be a reasonable, account-accessible model.

v2.1.1 was the hotfix: Codex CLI 0.130 silently changed its
default to `gpt-5.3-codex` (paid-only). Every fresh ChatGPT
subscription adopter hit HTTP 400 on their first cycle. We pinned
`model = "gpt-5.5"` to insulate adopters from upstream default
changes.

The pin is **stable but stale-by-design**: as new frontier models
ship, the pinned slug ages. A maintainer has to bump it across
the starter pack + every adopter project, and there's no
automatic signal when a better model becomes available.

This proposal lets the runner resolve the slug at session start
from data Codex CLI already maintains, giving adopters
"latest-available frontier model" semantics without trusting the
upstream `--model` default.

## 1. The problem

The matrix of failure modes:

| Adopter `tdd-pack.toml` `[codex] model` | Outcome when Codex CLI default shifts | Outcome when better model ships |
|---|---|---|
| `""` (defer to CLI default) | **BROKEN** — v2.1.1 incident: HTTP 400 on first cycle when default ≠ accessible. | "Free" — adopter gets new model on next Codex CLI upgrade. |
| `"gpt-5.5"` (pin specific) — current | Stable. | **STALE** — adopter keeps using yesterday's model until the pack ships a new pin and they re-adopt. |
| `"auto"` (proposed) | Stable — runner reads what's actually reachable. | **AUTOMATIC** — next session picks the new top model. |

Two underlying problems both are symptoms of:

1. **The pack does not know what models the adopter's account can
   reach.** That information lives in the adopter's account
   (subscription tier, API-key entitlements). Hard-coding any
   specific slug assumes account capabilities that may not hold.
2. **Codex CLI exposes no `models list` subcommand.** Task #134
   was filed to request one upstream (overdue 2026-06-11). If
   shipped, it would solve (1) — but the timeline is upstream's,
   not ours.

This proposal solves (1) without waiting on (2) by reading data
Codex CLI already maintains locally.

## 2. Goals + non-goals

**Goals:**

- Adopters who set `model = "auto"` get the
  highest-priority model their account can reach, without
  per-adopter maintenance.
- Selection is **deterministic** per session — same cache, same
  result. No probe-by-trying.
- Selection is **observable** — runner logs which slug was
  resolved + when the cache was last refreshed, so adopters
  can debug "why did we run with X?"
- Selection is **fail-safe** — cache missing, stale, malformed,
  or empty falls back to the current pinned slug with a clear
  warning. No silent failure modes.
- Selection is **zero-token-cost** — local cache only, no probe
  calls.

**Non-goals:**

- Replacing pinned-slug behavior entirely. `model = "gpt-5.5"`
  remains valid and unchanged for adopters who want
  reproducibility.
- Caching across sessions. Codex CLI already does this; we just
  read it.
- Refreshing the cache. Codex CLI refreshes on its own schedule
  during normal use; if it's stale, we surface that fact but do
  NOT trigger a refresh (would require an extra Codex call).
- Cross-CLI portability. This relies on a Codex-CLI-specific file
  format. If an adopter swaps Codex CLI for an alternative
  binary, `auto` is undefined.

## 3. Design

### 3.1 The cache

Codex CLI maintains `${CODEX_HOME:-~/.codex}/models_cache.json`,
refreshed when the CLI sees new model lists from the OpenAI API
during normal use.

**Verified shape** (Codex CLI 0.129.0, captured 2026-06-08):

```json
{
  "client_version": "0.129.0",
  "etag": "W/\"5d91fb8b0c2e79510ef87f292f5b8de8\"",
  "fetched_at": "2026-06-08T20:28:06.323968946Z",
  "models": [
    {
      "slug": "gpt-5.5",
      "display_name": "GPT-5.5",
      "description": "Frontier model for ...",
      "default_reasoning_level": "medium",
      "priority": 9,
      "visibility": "list",
      "supported_in_api": true,
      ...
    },
    ...
  ]
}
```

Fields the resolver consumes:

| Field | Use |
|---|---|
| `models[].slug` | The value passed to `codex exec -m <slug>`. |
| `models[].priority` | **Lower = better rank.** This is the dominant sort key. |
| `models[].visibility` | `"list"` = appears in selection menus. `"hide"` = internal-use, excluded. |
| `models[].supported_in_api` | Required when adopter uses API-key auth; ignored under subscription auth. |
| `fetched_at` | Used to warn on stale cache. |
| `client_version` | Used to warn on version skew (cache format may shift). |

### 3.2 The runner-side resolver

New helper: `runner/lib/resolve-model.sh` (sourced by
`runner/codex-round1.sh`, `codex-round-n.sh`, and any future
runner that calls `codex exec`).

API:

```bash
# Resolve <toml_model_value> [<auth_mode>] → echoes slug to stdout.
# Exit code: 0 = resolved, 1 = no candidates AND no fallback, 2 = invalid input.
# stderr carries diagnostic notes (cache age, fallback reasons).
resolve_codex_model() {
  local toml_value="$1"
  local auth_mode="${2:-subscription}"   # subscription | api_key
  local fallback_slug="${PRILIVE_MODEL_FALLBACK:-gpt-5.5}"
  # ... see slice 1 for the implementation ...
}
```

Resolution rules:

1. If `toml_value` is **non-empty and != "auto"** → echo it
   verbatim. (Pin-respecting passthrough.)
2. If `toml_value` is **"auto"**:
   a. Locate cache: `${CODEX_HOME:-$HOME/.codex}/models_cache.json`.
   b. If missing → emit warning to stderr ("cache absent; using
      fallback ${fallback_slug}"), echo fallback, exit 0.
   c. If unreadable / not JSON → same path: warn + fallback.
   d. Filter `.models` where `visibility == "list"` AND
      (`auth_mode == "subscription"` OR `supported_in_api ==
      true`).
   e. Sort filtered by `priority` ascending.
   f. If list is empty → warn + fallback + exit 0.
   g. Echo the first slug.
   h. If `fetched_at` older than 14 days → emit a non-fatal
      warning ("cache stale; consider `codex models` refresh").
3. If `toml_value` is **`""`** → emit deprecation warning ("empty
   model defers to Codex CLI default; see v2.1.1 incident; using
   fallback ${fallback_slug}"), echo fallback, exit 0.
4. If `toml_value` contains an obviously invalid character set
   (whitespace, control chars) → exit 2 with error.

### 3.3 Auth-mode detection

The filter in 2d depends on whether the adopter is using
subscription auth or API-key auth. Detect via:

- `CODEX_API_KEY` env var set OR
- `OPENAI_API_KEY` env var set
  → `auth_mode = "api_key"`.

- Else → `auth_mode = "subscription"`.

Subscription accounts can see models with
`supported_in_api == false` (e.g. Codex-Spark models that are
TUI-only); excluding them only when API-key auth is detected
preserves access for subscription adopters.

### 3.4 `tdd-pack.toml` change

```toml
[codex]
# Model selection.
#
# Three valid forms:
#
#   model = "auto"
#     Runner reads ~/.codex/models_cache.json at session start
#     and picks the highest-priority "list"-visible model the
#     account can reach. Fallback to <pinned default> if the
#     cache is absent / stale / unreadable.
#
#   model = "<slug>"
#     Pin a specific model (e.g. "gpt-5.5", "gpt-5.6-codex").
#     Use when you need reproducibility across sessions or want
#     to validate a specific model.
#
#   model = ""
#     DEPRECATED. Defers to Codex CLI's `--model` default, which
#     v2.1.1 documented as unsafe (default shifted from a
#     subscription-safe model to a paid-only one in 0.130 →
#     HTTP 400 on every first cycle). The runner now warns and
#     falls back to <pinned default> when it sees an empty value.
#
# Default: "auto" — adopters get latest-frontier behavior
# without per-pack maintenance.
model = "auto"
```

### 3.5 What changes in the runner

`runner/codex-round1.sh` (and `codex-round-n.sh`, etc.) today
have a line like:

```bash
MODEL=$(cfg_get "${PROJECT_DIR}/tdd-pack.toml" "codex.model" "gpt-5.5")
```

After slice 2:

```bash
MODEL_RAW=$(cfg_get "${PROJECT_DIR}/tdd-pack.toml" "codex.model" "auto")
MODEL=$(resolve_codex_model "${MODEL_RAW}")    # the resolver call
log "model resolved: ${MODEL} (toml said: ${MODEL_RAW})"
```

The `log` line is the observability requirement from §2.

### 3.6 Cache freshness signaling

The resolver emits a stderr line when cache is stale (>14 days
fetched). The runner SHOULD relay this to the operator as a
non-blocking note: "Codex CLI cache is N days old; consider
running `codex` once to refresh the model list." (Slice 3
detail; can land in a follow-up.)

## 4. Build slices

Three slices.

| Slice | Scope |
|---|---|
| **1** | Lock the resolver contract: write the spec, JSON Schema for the cache file (defensive — Codex CLI may shift format), and the fixture set. Counterfactual smoke covers each fallback branch (cache missing / unreadable / empty list / valid). No runner-side changes. |
| **2** | Implement `runner/lib/resolve-model.sh`. Wire `runner/codex-round1.sh` + `codex-round-n.sh` + ops-triage runners to call it. Default `tdd-pack.toml` `model` value flips from `"gpt-5.5"` to `"auto"`. Smoke + counterfactual added to `smoke-config-default-consistency.sh`. |
| **3** | (Optional) Stale-cache warning is surfaced through the runner so adopters see it. Adopter docs in `UPDATE_NOTES_v2.2-to-v2.3.md`. |

Slices 1+2 are the MVP. Slice 3 is polish.

## 5. Smoke tests

Per the counterfactual discipline:

- **`smoke-resolve-model.sh` (slice 1)** — directly tests the
  resolver function with fixture caches:
  - Valid cache → highest-priority list-visible slug.
  - Cache with `visibility: "hide"` on the highest-priority
    model → skips it.
  - Cache empty `models: []` → falls back to pinned default with
    warning.
  - Cache file missing → falls back, warning.
  - Cache file present but invalid JSON → falls back, warning.
  - `toml_value = "gpt-5.5"` (pinned) → echoes verbatim, no
    cache read.
  - `toml_value = ""` → falls back with deprecation warning.
  - API-key auth + `supported_in_api: false` on top model → skips it.
  - Counterfactual: subscription auth + `supported_in_api: false`
    on top model → returns it (does NOT skip).
- **`smoke-config-default-consistency.sh` (extended in slice
  2)** — asserts the shipped `tdd-pack.toml` has
  `model = "auto"` (the new default).
- **Worktree counterfactual (slice 2)** — runner cycle through a
  test sandbox: with `model = "auto"` + planted cache → runs
  against the planted slug. Counterfactual: with `model =
  "gpt-5.5"` pinned + planted cache → runs against `gpt-5.5`
  (cache ignored).

## 6. Honest limits

- **The cache trusts the operator's Codex CLI installation.** If
  the cache is tampered with (e.g. an attacker planted a fake
  high-priority model that does not exist), the runner will try
  to run against it and get an API error. Defense: the runner
  ALREADY validates Codex CLI's response; a fake slug would
  surface as a clear HTTP error, not silent wrong behavior.
- **The cache can lag behind reality.** Codex CLI refreshes on
  its own schedule. An adopter who hasn't run Codex CLI in
  weeks might miss a new frontier model. The 14-day stale-cache
  warning makes this observable; no automatic fix.
- **Cache format is undocumented upstream.** Codex CLI 0.129.0
  emits the structure described in §3.1. A future release may
  change it. The resolver's JSON-schema validation + tolerant
  fallback catch this; adopters get the safety net, maintainers
  get an empirical signal that the cache schema needs updating.
- **No multi-cache support.** If an adopter has separate
  `CODEX_HOME` paths for different projects, the resolver reads
  the env-resolved one. Edge case; document but do not handle.
- **`auto` is opaque about reasoning effort.** The `[codex]
  reasoning_effort` knob stays adopter-controlled. Resolver
  picks the slug; the existing knob picks the effort. Two
  axes, independent.

## 7. Open questions for slice 1

1. **Cache schema validation strictness.** Should an unknown
   field in the cache (Codex CLI added something we don't know)
   cause fallback? Recommend: no. Tolerate unknown fields; only
   fall back when the fields we DEPEND on are missing or
   malformed. Forward-compatible by default.
2. **Stale threshold.** 14 days is arbitrary. Should it be a
   `tdd-pack.toml` knob? Recommend: no for slice 1 (one-week vs
   two-week vs month is bikeshedding); revisit if adopters
   report friction.
3. **API-key vs subscription detection.** The `CODEX_API_KEY` /
   `OPENAI_API_KEY` env-var heuristic catches the common case
   but misses operators who use `codex login` for API-key auth
   (login flow stores auth in `~/.codex/auth.json`). Slice 1
   should sniff `auth.json` for `"api_key"` token type as a
   secondary signal. Document the precedence.
4. **Excluded slugs.** Some models (e.g. `codex-auto-review`,
   `*-spark`) might be inappropriate for the review-round role
   even when high-priority. Recommend: don't blocklist by name
   in slice 1; trust `visibility == "list"`. Revisit if real
   reviews come back with poor outputs from a niche model.
5. **What if `models_cache.json` doesn't exist on first ever
   install?** Codex CLI populates it on first successful auth +
   run. Recommend: the resolver's "cache missing → fallback"
   branch covers this; adopters get the pinned default until
   they make their first Codex call, then `auto` takes over.

## 8. Recommendation

**Approve and start slice 1 (resolver contract + fixtures).**
The mechanism is small, the cache structure is verified, and
the fallback path is the same path v2.1.1 already trusts. Total
across slices 1+2 is probably ~1 day of work; slice 3 is half a
day.

Once slice 2 lands, devopspoint's PR-A (the v2.0 → v2.1.1
catch-up) can adopt `model = "auto"` directly without needing
to track each future model bump.

Slice 1 must Codex-review the resolver design before slice 2
implements it — same proposal-review discipline as #105 / #107
/ #133.

## 9. Interaction with task #134

Task #134 (file `codex models` subcommand upstream) was the v1
plan for solving this. That ask is **still useful** — an
official subcommand would be a forward-compatible alternative
to reading the cache directly, and could carry signaling
(deprecations, account-tier hints) the cache doesn't. But
shipping `auto` removes the urgency: we don't need the upstream
subcommand to give adopters latest-model behavior today.

Recommend: still file #134 for visibility, but downgrade its
priority. Note in the issue that the local cache solves the
near-term need and an upstream subcommand would be a quality
upgrade.

## 10. Related

- v2.1.1 hotfix — pinned `model = "gpt-5.5"` after the empty-
  default incident. This proposal builds on that safety net.
- Task #134 — upstream `codex models` subcommand request. See §9.
- `~/.codex/models_cache.json` — the cache this proposal reads.
  Verified shape in v0.129.0; the resolver tolerates schema
  drift via §3.2 fallbacks.
- `docs/RELEASE_GUIDE.md` § Pre-implementation discipline —
  governs how this proposal gets adversarially reviewed before
  implementation lands.

---

## 11. Addendum — Codex review findings (2026-06-09)

A second-model adversarial review by Codex (gpt-5.5, high
reasoning) was sharp on this proposal — **2 BLOCKER + 5 MAJOR +
3 MINOR**. The most important finding is that I treated the
local cache as proof of entitlement when it is only a UI signal
— the same class of failure as the v2.1.1 incident I was trying
to prevent. v2 of this proposal narrows the safety claim and
makes `auto` opt-in until field evidence proves the cache means
what I assumed.

### BLOCKER findings (2) — both accepted

1. **Cache does not prove entitlement.** v1 assumed
   `visibility == "list"` AND `supported_in_api == true` was
   sufficient to guarantee the model is runnable. The cache is
   a UI/menu list; it does NOT encode quota state, org/project
   scoping, or paid entitlement. If a high-priority listed
   model is unreachable for the operator's actual auth context,
   the runner fails on the first cycle — the exact failure mode
   v2.1.1 was the hotfix for.
   - **Change**: rename the contract from "best model the
     account can reach" to **"best cached listed model"**. Do
     NOT claim entitlement guarantees. The fallback path stays
     as the safety net, BUT (per BLOCKER 2) `auto` must not
     become the shipped default until field evidence shows
     entitlement and listing actually agree for the target
     adopter mix.

2. **Default flip to `model = "auto"` is not fail-safe.** The
   resolver's fallback handles only missing/malformed/empty
   cache. The most likely failure (valid cache → resolver picks
   a slug the account cannot actually run → HTTP 400 first
   cycle) is NOT in the fallback set. Shipping `auto` as the
   default would put fresh adopters through the same first-
   cycle-crash funnel as v2.1.1.
   - **Change**: slice 2 ships the resolver but **keeps the
     shipped default at `model = "gpt-5.5"`**. `model = "auto"`
     is fully implemented and documented as an opt-in for
     adopters who want to try it. Default flip is gated on a
     new slice 4 (was slice 3): field evidence from at least
     two adopters running `auto` for 14+ days with zero first-
     cycle resolver-attributed failures.

### MAJOR findings (5) — all accepted

| # | Finding | Change |
|---|---|---|
| M1 | "Highest priority" is generic-UI signal; the runner does code review, which has role-specific suitability. Trusting `visibility == "list"` lets a niche/auto-review/-spark model win on priority alone. | v2 §3.2 adds a **role-suitability filter** that runs BEFORE the priority sort: drop slugs whose name matches `*-auto-review`, `*-spark`, `*-mini` (configurable allowlist in a future slice). Slice 1 fixture set MUST include a cache where a high-priority `codex-auto-review` model exists; the smoke asserts it is filtered out. The filter is conservative: explicit names, easily auditable, easily revised. |
| M2 | Shell+JSON+TOML parsing is brittle. The v1 design relies on `jq` without declaring it a hard dependency; missing/null/string-typed `priority` fields would silently break. | v2 §3.2 **declares `jq` a hard dependency** for the resolver (already the case for the rest of the pack — `make doctor` checks it). Slice 1 fixtures cover: missing `priority`, string `priority`, duplicate priorities, `null` fields, absent `models`, absent `visibility`. Each maps to fallback with a specific stderr note (no silent skipping). |
| M3 | `model = ""` semantics change from "defer to CLI default" to "warn + fallback" without a migration path. Some adopters may rely on `""` for local experimentation. | v2 §3.2 **preserves `""` semantics literally** — the resolver passes empty through to Codex CLI unchanged (current v2.1.x behavior). A new explicit value `model = "cli-default"` is added for adopters who WANT to opt into the deferred-default behavior with a clear name. Deprecation warning moves from `""` to `"cli-default"` — at least it tells the truth about what it does. |
| M4 | Empirical claims rest on one CLI version. Cache shape, refresh timing, meaning of `priority` / `visibility` / `supported_in_api` are asserted from 0.129.0 only. | v2 slice 1 ships a **verification matrix**: probe results across at least 0.128.x and 0.129.x (older releases by version range — bound by what's reachable via `npm i -D` snapshots), subscription AND API-key auth, plus ONE real `codex exec -m <slug>` per selected class to confirm reachability. The probe runs against fixtures, not live tokens for the matrix; one live spot-check at the end. |
| M5 | Slice plan is not independently shippable. v1 slice 1 "tests the resolver" before slice 2 "implements it"; v1 slice 3 makes observability optional even though §2 lists it as a goal. | v2 slice plan recut to vertical-shippable: slice 1 = contract + JSON Schema + fixtures + a STUB resolver returning fallback (counterfactual smoke validates fallback paths); slice 2 = real resolver implementation + runner wiring + observable logging (NOT optional); slice 3 = stale-cache warning surfacing; slice 4 = (gated on field evidence) flip default to `auto`. |

### MINOR findings (3) — all accepted

- **Auth-mode detection underdesigned.** v2 §3.3 changes: prefer
  Codex CLI's actual active auth (parse `~/.codex/auth.json` for
  the `OPENAIAuth` token type) as PRIMARY signal; env var
  heuristic as SECONDARY signal only when `auth.json` is absent.
  Every `auto` resolution logs the detected mode AND why
  (which signal was used).
- **Stale-cache contradiction.** v1 §3.2 said "stale → fallback",
  §3.6 said "stale → warn", `tdd-pack.toml` comment said
  "fallback if absent/stale/unreadable." v2 reconciles: **stale
  warns but does NOT fall back**. The resolver still uses the
  cache; only the operator sees a "consider running `codex` to
  refresh" note. All three text locations updated to match.
- **Date carelessness.** v1 §9 said task #134 was "overdue
  2026-06-11" but today is 2026-06-09. v2 says "due
  2026-06-11" with the correct sense.

### Revised slice plan

| Slice | v1 scope | v2 scope (post-addendum) |
|---|---|---|
| 1 | Lock resolver contract + fixtures (no runner changes) | **Lock contract + JSON Schema for the cache + role-suitability filter spec + verification matrix + STUB resolver returning fallback so slice 1 ships independently with a working counterfactual smoke** (BLOCKER 1, MAJOR M1/M2/M4/M5 closures). |
| 2 | Implement resolver + flip default | **Implement real resolver + wire `codex-round1.sh` / `codex-round-n.sh` / ops-triage runners + ship operator-visible logging in the MVP** (NOT optional per MAJOR M5). Default stays `gpt-5.5` (BLOCKER 2). `model = "auto"` opt-in, `model = ""` preserves v2.1.x semantics, new `model = "cli-default"` carries the deprecation warning (MAJOR M3). |
| 3 | (Optional) stale-cache warning | **Stale-cache warning surfaced through runner output** (no longer optional). MINOR contradiction fixes. |
| 4 | (was 3) UPDATE_NOTES | **Flip default `model` from `"gpt-5.5"` to `"auto"`** — gated on ≥2 adopters reporting 14+ days zero first-cycle resolver-attributed failures (BLOCKER 2). Plus adopter doc update. |

### What stays solid in v1

- The cache shape captured in §3.1 (verified against 0.129.0) is
  still the right input. v2 just narrows what we claim about its
  meaning.
- The resolver API in §3.2 (`resolve_codex_model`) is the right
  shape; only the filter step changes.
- The §6 honest-limits section was already calling out the
  cache-tampering and cache-lag failure modes. Keep as-is.
- `jq` as a dependency is already in `make doctor`; M2's
  "declare it" change is a doc fix more than an architectural
  one.

---

## 12. Recommendation (post-addendum)

**Approve and start slice 1** under the v2 scope. Slice 1 is
self-contained: contract, schema, fixtures, role-filter,
stub-resolver-with-fallback-smoke. No live Codex calls. ~2-3
hours.

Slice 2 (real resolver + runner wiring + logging) follows once
slice 1's fixtures lock the contract.

Slices 3 and 4 are conditional on the prior slice landing
cleanly + (for slice 4) field evidence from adopters.

---
