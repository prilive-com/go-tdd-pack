# Upstream Dependency Policy

> Status: living document.
> Owner: pack maintainer.
> Audience: pack maintainers + reviewers of PRs that touch external
> tool versions, models, or CLI invocations.

This is the policy for how the pack handles its external dependencies
— Codex CLI, OpenAI models, Go linters. Reading this should take
under five minutes.

---

## Why this exists

v2.1.0 shipped `model = ""` in `tdd-pack.toml`. The intent was "track
Codex CLI's default — we get newer models automatically as upstream
ships them". The contract held at v2.1.0 ship time. Codex CLI 0.130
then changed its default to `gpt-5.3-codex`, a paid-only model that
crashes every ChatGPT-subscription adopter's first review cycle.

The decision "track upstream default" was not wrong on the day it was
made. It was wrong as an unaudited contract with no drift detection
and no recovery plan. See
[`POSTMORTEM-v2.1.0.md`](POSTMORTEM-v2.1.0.md) Bug 2.

This policy makes the pin-vs-track decision explicit for every
external dependency the pack relies on, and writes down how to detect
drift before adopters do.

---

## The two stances

| Stance | What we do | What we own |
|---|---|---|
| **Pin** | Set a concrete value (`gpt-5.5`, `staticcheck@v0.5.0`). Adopter must opt out to track upstream. | Periodic re-verification + re-pin. |
| **Track** | Leave the value implicit or floating (no `--model` flag, `staticcheck` from PATH). Adopter inherits upstream's current behaviour. | Continuous drift surveillance + a recovery plan when drift breaks us. |

Neither is universally correct. The cost is paid in different places.

---

## Decision rubric

For each dependency, lean **pin** if more "yes" answers; **track** if
more "no" answers.

| Question | Lean PIN if yes | Lean TRACK if yes |
|---|---|---|
| Does upstream sometimes ship a default that crashes our use case? | yes | no |
| Is the failure mode "0 results / different results" rather than "system error"? | no | yes |
| Do adopters need byte-reproducible runs (releases, CI)? | yes | no |
| Does upstream version-bump break protocols / flags / wire formats? | yes | no |
| Is the value something an adopter can override in their own config? | yes | no |
| Is the value something we can re-verify in under 5 minutes? | yes | no |
| Does the dependency's value matter for security-of-the-day (vuln DBs)? | no | yes |

A "lean" is a starting point, not a rule. Record the actual decision
in this doc with the reasoning.

---

## How to record a pin-or-track decision

Two places, both required.

### 1. Inline comment at the value

The file that holds the pinned/tracked value gets a comment block
above it covering:

- What is pinned/tracked.
- Why (one sentence).
- The failure mode if upstream changes.
- How to opt out (for adopters).

Template:

```toml
# <field>: pinned to "<value>" / tracking upstream default.
#
# Why: <one sentence reason>.
# Failure mode if upstream changes: <what breaks>.
# Adopter opt-out: set <field> = "<other-value>" in your own copy.
# Re-verify: <command to confirm the pin is still good>.
```

Real example, from `tdd-pack.toml` after v2.1.1:

```toml
# Model selection.
#
# DEFAULT: model = "gpt-5.5" — verified working on both ChatGPT
# subscription auth (Plus/Pro/Team) and API-key auth. ...
```

### 2. Entry in the per-dependency table below

Update the table in this file. The table is the source of truth for
"what stance are we on, today, for each dependency".

---

## Drift detection

Pin and track each need a way to learn that upstream moved before
adopters report a crash. Three mechanisms; use the one matched to
the dependency.

| Mechanism | Best for | Cost |
|---|---|---|
| **Smoke that asserts the contract** | Pinned values that must remain non-empty / non-default / on a specific shape (e.g. `smoke-config-default-consistency.sh` check #3). | Free per run. Best signal. |
| **Live smoke at release time** | Anything that hits an external API (Codex CLI + OpenAI models). `scripts/release/pre-tag-smoke.sh` (postmortem A1) is this layer. | One real API call per release. |
| **Periodic manual re-verification** | Tools where behavior change = noise (golangci-lint, staticcheck). Catalogue in the table; check once a quarter or whenever a tool's major version ships. | 10-15 minutes per dependency per check. |

All three are necessary. No single mechanism covers every dependency.

---

## Per-dependency current stance

The current stance and verification policy for every upstream the pack
calls. Last reviewed: **2026-06-04** (alongside the v2.1.1 hotfix).

| Dependency | Stance | Value | Where | Drift detection | Last verified |
|---|---|---|---|---|---|
| **Codex CLI binary** | floor in adopter requires; the live-smoke environment SHOULD pin | `>= 0.125.0` in `plugin.json` `requires.codex-cli` | adopters install per `ADOPTION_GUIDE.md` | live smoke (A1) catches CLI-version-induced default changes | 2026-06-04 (0.130 on adopter; pack OK) |
| **OpenAI model (round-1 + round-N)** | **pin** | `model = "gpt-5.5"` in `tdd-pack.toml` | `tdd-pack.toml` `[codex]` | `smoke-config-default-consistency.sh` check #3 asserts non-empty | 2026-06-04 (post-v2.1.0 incident) |
| **OpenAI reasoning effort** | pin | `reasoning_effort = "xhigh"` in `tdd-pack.toml` | `tdd-pack.toml` `[codex]` | none — value is owned by us, not upstream | n/a |
| **OpenAI web search** | pin | `web_search = "live"` in `tdd-pack.toml` | `tdd-pack.toml` `[codex]` | none — `live` vs `disabled` is owned by us | n/a |
| **`gofmt`** | track | from Go toolchain | `runner/tool-grounding.sh` | tracked with Go version floor (`>= 1.22.0` in `plugin.json` requires) | 2026-06-04 |
| **`go vet`** | track | from Go toolchain | `runner/tool-grounding.sh` | tracked with Go version floor | 2026-06-04 |
| **`staticcheck`** | track + opt-in | `staticcheck -checks=all` from PATH | `runner/tool-grounding.sh` | manual re-verification once per quarter; new SA checks expected to surface new findings, which is by design | 2026-06-04 |
| **`golangci-lint`** | track + opt-in | `golangci-lint run --enable-all` from PATH | `runner/tool-grounding.sh` | manual re-verification once per quarter; `--enable-all` is intentionally tracking upstream's full linter set | 2026-06-04 |
| **`gosec`** | track | `gosec -no-fail -quiet ./...` from PATH | `runner/tool-grounding.sh` | manual; security findings are by design | 2026-06-04 |
| **`govulncheck`** | track | from PATH | `runner/tool-grounding.sh` | tracked by design — vulnerability DB updates daily; we want the freshest signal | continuous |
| **`jq`** | track + floor | `>= 1.6` in `plugin.json` | runner / hooks / smokes | parses break would be caught by every smoke | 2026-06-04 |
| **`git`** | track + floor | `>= 2.25.0` in `plugin.json` | runner / hooks | hook invocations would fail loudly | n/a |
| **`bash`** | track + floor | `>= 4.0` in `plugin.json` | every shell script | catastrophic; the parse smoke catches associative-array regressions | n/a |
| **`codex login` auth backend** | n/a (per-adopter) | ChatGPT subscription OR API key | adopter env | live smoke (A1) catches "configured model not reachable on this auth" | 2026-06-04 |

> **Quarterly review.** Once per calendar quarter, scan this table. For
> every `last verified` field older than 90 days, run that
> dependency's drift-detection mechanism (smoke or manual check) and
> bump the date.

---

## Changing a dependency's stance

If you flip a dependency from track to pin (or vice versa), do all of:

1. Update the value at the source (file referenced in the table's
   "Where" column).
2. Update the inline comment at the value (template above).
3. Update the table row in this doc — stance, value, drift detection,
   last verified.
4. Add a CHANGELOG entry under `### Changed` covering the rationale
   (cite the failing case if there is one).
5. If the change is in response to an incident, link the postmortem.
6. If the change introduces a new smoke or invariant, add it to the
   table's "Drift detection" cell so future maintainers know which
   smoke guards the new stance.

---

## What this policy does NOT do

- It does not freeze our dependencies. We still encourage upstream
  updates; we just want them to be intentional, not silent.
- It does not require every value to be pinned. Track is a valid
  stance when the failure mode is "new findings" rather than "system
  error".
- It does not commit us to running drift-detection automatically for
  every dependency. Some (linters) are explicitly manual-review at
  quarterly cadence. The point is to record the cadence, not to
  automate everything.

---

## Related

- [`POSTMORTEM-v2.1.0.md`](POSTMORTEM-v2.1.0.md) — the incident that
  motivated this policy. Bug 2 is the canonical example of an
  untracked upstream contract failing.
- [`RELEASE_GUIDE.md`](RELEASE_GUIDE.md) Phase 3a — the live-smoke gate
  that catches several drift-detection failures at release time.
- `scripts/release/pre-tag-smoke.sh` — the script behind Phase 3a.
- `test/smoke-config-default-consistency.sh` — the smoke that enforces
  the OpenAI-model pin from v2.1.1 onward.
