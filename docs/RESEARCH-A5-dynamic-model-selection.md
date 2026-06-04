# Research — Dynamic model selection (Postmortem A5)

> Status: **research outcome — blocked on upstream**.
> Action item A5 from [`POSTMORTEM-v2.1.0.md`](POSTMORTEM-v2.1.0.md).
> Target: v2.3+ (deferred; see "Recommendation" below).
> Last verified against Codex CLI: **0.129.0** (2026-06-04).

The postmortem's A5 hoped to eliminate the pin-vs-track tradeoff
documented in [`UPSTREAM_DEPENDENCY_POLICY.md`](UPSTREAM_DEPENDENCY_POLICY.md)
by querying the auth backend at session start, discovering which
models the current `codex login` session can actually use, and picking
the best one automatically. This research note records what we found
when we went to design that.

---

## TL;DR

The clean version of A5 needs an upstream API that **does not exist**
in Codex CLI 0.129. No `codex models`, no `codex login status`
extension that lists reachable models, no documented endpoint for
authenticated-model discovery. The model name has to come from
somewhere we control.

There are three available next moves. None of them are great. The
recommendation at the bottom is **lobby upstream first, build a
probe-based fallback only if the lobby fails or the wait gets too
long**.

---

## What we wanted

Replace the v2.1.1 pin:

```toml
# Today (v2.1.1)
model = "gpt-5.5"   # works on both subscription + API-key
```

…with something like:

```toml
# Hypothetical v2.3+
model = "auto"      # runner queries auth backend, picks best supported
```

…where the runner at session start runs something equivalent to:

```bash
codex models --json | jq -r 'best model my account can use for our use case'
```

and caches the result for the session.

This would close the loop on:

- **Bug 2 from v2.1.0** — empty model defaulting to a paid-only model
  would never happen because we would explicitly probe what works.
- **The "verified" date in the per-dependency table** — drift would
  be auto-detected when the auth backend's accessible-model set
  changes.
- **Per-adopter optimization** — a subscription user could end up on
  the best subscription model, an API-key user on the best API
  model, automatically.

---

## What the upstream surface actually offers (Codex CLI 0.129)

Subcommands present:

```
exec, review, login, logout, mcp, plugin, mcp-server, app-server,
completion, update, sandbox, debug, apply, resume, fork, cloud,
exec-server, features, help
```

Subcommands **absent**: `models`, `model`, `list-models`, any variant.

Verified surfaces that touch models:

- `codex exec -m <MODEL>` — pass a model id explicitly.
- `codex login status` — returns auth method (ChatGPT vs API key) but
  not the accessible model set.
- `-c model=<MODEL>` — config override in `~/.codex/config.toml`.
- `codex features list` — feature flags only, not models.

**There is no documented way to ask "what models can THIS login use?"
short of trying one and seeing if it succeeds.**

We could also read `~/.codex/auth.json` directly (Codex CLI persists
auth state there) but that is unstable internal state — Codex CLI
0.130 already changed enough to break the v2.0.1 pack's defaults, and
we should not bet on the auth file format.

---

## Three available next moves

### Move 1 — Lobby upstream for `codex models`

Open an issue (or PR) on https://github.com/openai/codex requesting:

```
codex models                 # interactive: pretty table
codex models --json          # machine: list of {id, capability, available}
codex models --available     # only models the current login can use
```

| | |
|---|---|
| Cost to us | a few hours of issue authoring + light back-and-forth |
| Time to result | weeks to months, depending on upstream priorities |
| Win if accepted | a clean stable API we can build on |
| Risk | upstream may decline; or accept but with a different shape we have to adapt to |

Even if upstream accepts, we will not have it for v2.2 or possibly
v2.3. Lobbying does not solve the problem; it makes the eventual
solution clean instead of hacky.

### Move 2 — Probe-based fallback (build it ourselves now)

Maintain an ordered preference list:

```bash
PREFERRED_MODELS=(
  "gpt-5.5"          # best on both auth modes as of 2026-06-04
  "gpt-5-codex"      # API-key only, but better than 5.0 if available
  "gpt-5.0"          # broadly available baseline
  # ... etc
)
```

At session start (in `hooks/session-start.sh`), iterate the list and
make a tiny "do you accept this model?" probe:

```bash
for m in "${PREFERRED_MODELS[@]}"; do
  if echo '{"prompt":"reply with ok"}' \
       | codex exec -m "$m" --output-schema /tmp/min.schema.json \
                    --max-tokens 5 >/dev/null 2>&1; then
    echo "$m" > .tdd/.session-model
    break
  fi
done
```

| | |
|---|---|
| Cost to us | ~half a day of script + smokes + cache logic |
| Time to result | ships in v2.2 |
| Win | adopters do not have to know about model names |
| Risk — A | the probe itself costs real tokens, on every session start. ChatGPT subscription users have plan caps; API-key users pay per probe. We must keep `PREFERRED_MODELS` short. |
| Risk — B | the preference list is still a pin we maintain. We have moved the maintenance from "one model id" to "ordered list of model ids per release". Net work: more, not less. |
| Risk — C | a transient failure during probe (network glitch) demotes the user to a worse model for the whole session. We need a retry policy. |
| Risk — D | the probe semantic is "this model accepts an `--output-schema` call". It does not test what we actually care about (model quality, reasoning depth, schema-strict-mode correctness on a non-trivial schema). Probe-pass and actual-pack-failure are different things. |

The Risk-B point is the key one. **Probe-based fallback solves a v2.1.0-style crash but does not eliminate the maintenance** — we still own the preference list. The win is for adopters, not for us.

### Move 3 — Document the gap, do nothing

Acknowledge that A5 needs upstream support that does not exist; pin
verified models per release in `tdd-pack.toml`; rely on A1+A2+A3 to
catch drift. This is the status quo after v2.1.1.

| | |
|---|---|
| Cost to us | zero new code |
| Time to result | already done |
| Win | none — keeps the discipline tax of pin-and-verify |
| Risk | each Codex CLI bump or model deprecation is a release-blocking event for us, the way v2.1.0 was |

---

## Recommendation

**Move 1 + Move 3 today. Move 2 only if Move 1 fails or stalls
beyond two quarters.**

The reasoning:

- **Move 1 is the only path to a clean solution.** Building a
  probe-based fallback today (Move 2) buys ~50% of the win at ~150%
  of the cost; we still maintain a per-version model preference
  list, and we add probe-cost to every session start. That trade is
  bad unless we are confident upstream will never ship the API.
- **Move 3 is sustainable.** v2.1.1 already showed we can ship,
  detect drift, and hotfix in ~1.5 hours when the discipline is
  written down (A1+A2). The pin-and-verify tax is two minutes per
  release, not two hours.
- **Move 2 is the right fallback** if upstream rejects the lobby or
  takes more than two quarters to ship. Half a day of work is fine
  *eventually*; not fine *today* when we have no evidence upstream
  will not move.

### Concrete next actions

| Action | Owner | When |
|---|---|---|
| Open `openai/codex` issue requesting `codex models` subcommand with a `--json` and `--available` flag. Link this research note. | maintainer | within one week of merging this doc |
| Add a row to `UPSTREAM_DEPENDENCY_POLICY.md` "Quarterly review" reminder: "Did upstream ship a model-discovery API yet?" | maintainer | merge with this doc |
| Re-evaluate Move 2 if the upstream issue is rejected, marked won't-do, or sits without progress for two quarters. | maintainer | quarterly review |

### What we will NOT do based on this research

- **Build Move 2 (probe-based fallback) today.** Half a day of code
  for half a solution, plus per-session probe cost, plus an ongoing
  preference-list maintenance burden — without first checking if
  upstream will give us the right surface.
- **Read `~/.codex/auth.json` directly.** Codex CLI changes its own
  internal state across versions (v0.130 was already enough to break
  us once). Reading internal files is a worse contract than the
  empty-string default we just removed.
- **Hard-code a model-by-auth-type lookup.** The same maintenance
  burden as Move 2 without the per-account verification — strictly
  worse.

---

## What this research changes upstream of the recommendation

A few items in adjacent docs change because of this research, even
without implementing A5:

1. [`UPSTREAM_DEPENDENCY_POLICY.md`](UPSTREAM_DEPENDENCY_POLICY.md)
   "OpenAI model" row: add note "no upstream discovery API exists in
   Codex CLI 0.129; pinning is the only stable contract until A5
   ships". Link this doc.
2. [`POSTMORTEM-v2.1.0.md`](POSTMORTEM-v2.1.0.md) Action item A5
   should be updated: status changes from "v2.3+ research" to
   "blocked on upstream, see RESEARCH-A5".
3. **Quarterly upstream-policy review** should now include "check
   `codex --help` for a model-discovery subcommand; if present,
   re-open A5".

---

## Open technical questions if Move 2 ever runs

Park here in case we need them later:

- What is the smallest valid `--output-schema` probe? A no-op schema
  that accepts any string? Or do we need a real schema to verify
  strict-mode correctness too?
- How do we distinguish "model rejected" (HTTP 400 from auth) from
  "transient API error" (HTTP 500, retry)?
- What is the right cache lifetime? Per-session is the safe default,
  but adopters who keep Claude Code sessions open for days might
  miss a model upgrade. Daily refresh?
- Does an account's accessible-model set actually change often enough
  to make probing worthwhile, vs setting a pin every release?
- Does the choice of model affect strict-mode validation semantics?
  (We learned in v2.1.0 that schema strict mode is real; do all
  models enforce it equally?)

---

## Related

- [`POSTMORTEM-v2.1.0.md`](POSTMORTEM-v2.1.0.md) — A5 was filed here
  as a v2.3+ research item.
- [`UPSTREAM_DEPENDENCY_POLICY.md`](UPSTREAM_DEPENDENCY_POLICY.md) —
  pin-vs-track policy A5 aims to obviate.
- [`PROPOSAL-release-gate-coupling.md`](PROPOSAL-release-gate-coupling.md)
  — A4; same "defer until evidence justifies the cost" pattern.
- `tdd-pack.toml` `[codex]` `model` — the value A5 would replace.
- `test/smoke-config-default-consistency.sh` — the smoke that
  currently enforces the v2.1.1 pin.
