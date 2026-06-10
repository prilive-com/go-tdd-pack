# Update notes: v2.2.x → v2.3.0

> **Audience.** A developer who already installed the Prilive Go TDD
> Pack at **v2.2.x** (via project-copy or plugin install) and wants
> to move to **v2.3.0**.
>
> First time installing? Read
> [`ADOPTION_GUIDE.md`](ADOPTION_GUIDE.md) instead.
>
> Coming from v2.0.x or v2.1.x? Read
> [`UPDATE_NOTES_v2.0-to-v2.1.md`](UPDATE_NOTES_v2.0-to-v2.1.md) and
> [`UPDATE_NOTES_v2.1-to-v2.2.md`](UPDATE_NOTES_v2.1-to-v2.2.md) FIRST
> to get to v2.2.x, then this guide.

v2.3.0 is **backwards-compatible with v2.2.x** in the happy path. The
headline change — `model = "auto"` cache-driven model selection — is
default-on, but its fallback path resolves to the same `gpt-5.5`
slug v2.1.1 pinned, so adopters on subscription accounts see zero
immediate behavior change. The three other v2.3-track items
(grounding adapter, FDTDD Stage 1 marker, sandbox research) are
**contract spikes** — design documents + fixture sets that gate
future slice 2+ work, with **no runtime behavior change** in v2.3.0.

---

## TL;DR — what changed

- **`model = "auto"` is the new shipped default.** The runner reads
  `~/.codex/models_cache.json` (Codex CLI maintains it
  automatically), filters role-inappropriate slugs (`*-auto-review`,
  `*-spark`, `*-mini`), sorts by priority, returns the winner. Falls
  back to `gpt-5.5` with a stderr warning if the cache is missing or
  corrupt — same slug v2.1.1 hotfix pinned.
- **Adopters keeping their existing `tdd-pack.toml`** (with their own
  `model` value) are unaffected — the resolver respects pinned slugs
  unchanged.
- **One latent bug fixed.** Pre-v2.3, `runner/ops-preflight-review.sh`
  called `codex exec` with **no `-m` flag** — same trap v2.1.1 fixed
  in the main runners but missed for the ops-preflight path. Now
  resolved via the same resolver.
- **FDTDD marker location moved** to `.tdd/findings/active.json`
  (was: `.tdd/active-finding`). Legacy markers remain
  **read-only via fallback** until you next run `finding-start.sh`,
  which writes the v2 schema at the new location.
- **`[review] mode = "soft"` is now explicit** in `tdd-pack.toml`.
  Pre-v2.3 the field was consumed by `inject-findings.sh` but not
  documented in the shipped template — now it is, with the
  four-value enum (`off / soft / governed_tdd / strict_tdd`).
- **Three contract-spike docs** for upcoming slice-2 work:
  - `docs/GROUNDING_ADAPTER_INTERFACE.md` (task #107)
  - `docs/FDTDD-MARKER-CONTRACT.md` + `docs/FDTDD-SLICE1-PRECHECKLIST.md` (task #133)
  - `docs/RESEARCH-codex-sandbox-features.md` (task #105)

  These are read-only artifacts in v2.3.0; their runtime
  implementations will land in future minors.

- **No breaking changes.** No code-review behavior, no
  Ops Risk Triage rail behavior, no Gate 4 behavior changed.

---

## TL;DR — happy path

```bash
# 1. Pull the v2.3.0 pack source.
git clone --depth 1 --branch v2.3.0 \
  git@github.com:prilive-com/go-tdd-pack.git /tmp/go-tdd-pack-v2.3

# 2. From your project root, refresh pack-owned trees (overwrites
#    pack files only; your CLAUDE.md / AGENTS.md / tdd-pack.toml /
#    .claude/settings.json are NOT touched here).
cd ~/your-go-project
PACK=/tmp/go-tdd-pack-v2.3

cp -R "$PACK/hooks/."    hooks/
cp -R "$PACK/runner/."   runner/
cp -R "$PACK/prompts/."  prompts/
cp -R "$PACK/schemas/."  schemas/
cp -R "$PACK/test/."     test/

# v2.3 NEW: cache-fixture corpus for the model resolver smoke.
mkdir -p test/fixtures/codex-models-cache
cp "$PACK/test/fixtures/codex-models-cache/"*.json \
   "$PACK/test/fixtures/codex-models-cache/README.md" \
   "$PACK/test/fixtures/codex-models-cache/not-json.txt" \
   test/fixtures/codex-models-cache/

# v2.3 NEW: grounding-parity fixture (slice 2 of #107 will use it).
mkdir -p test/fixtures/grounding-parity
cp -R "$PACK/test/fixtures/grounding-parity/." \
       test/fixtures/grounding-parity/

# v2.3 NEW: PreToolUse payload fixtures (slice 2 of #133 will use them).
mkdir -p test/fixtures/pretooluse-payloads
cp "$PACK/test/fixtures/pretooluse-payloads/"* \
   test/fixtures/pretooluse-payloads/

# v2.3 NEW: research probe script.
mkdir -p scripts/research docs/research
cp "$PACK/scripts/research/probe-codex-sandbox.sh" scripts/research/
cp "$PACK/docs/research/codex-sandbox-features.example.json" docs/research/

chmod +x hooks/*.sh runner/*.sh runner/lib/*.sh \
         scripts/tdd/*.sh test/smoke-*.sh \
         scripts/research/*.sh

# 3. Reconcile your `tdd-pack.toml` — see "Config merge" below.

# 4. Verify (no Codex calls, no API tokens spent).
bash test/smoke-v2-phase2.sh
bash test/smoke-tool-grounding.sh
bash test/smoke-config-default-consistency.sh
bash test/smoke-schema-strict-mode.sh
bash test/smoke-resolve-model.sh
bash test/smoke-active-finding.sh
bash test/smoke-fdtdd-backward-compat.sh
bash test/smoke-fdtdd-marker-schema.sh
bash test/smoke-protect-tdd-artifacts.sh
bash test/smoke-protect-tdd-artifacts-traversal.sh
bash test/smoke-prompt-content.sh
bash test/smoke-plugin-manifest-v21.sh
# If you're using the v2.2 Ops Risk Triage rail (opt-in):
bash test/smoke-ops-triage-slice1.sh
bash test/smoke-ops-triage-slice2.sh
bash test/smoke-ops-triage-slice3.sh
bash test/smoke-ops-preflight-review.sh
bash test/smoke-ops-triage-slice5.sh
```

---

## Config merge

`tdd-pack.toml` is user-owned. The v2.3 changes are minimal — most
adopters can leave it alone.

### Decision: what value for `[codex] model`?

The shipped default flipped from `model = "gpt-5.5"` to
`model = "auto"`. You have three reasonable choices:

| Your `tdd-pack.toml` | Behavior |
|---|---|
| `model = "auto"` **(recommended)** | Runner reads `~/.codex/models_cache.json` at session start, picks the highest-priority "list"-visible slug, falls back to `gpt-5.5` if cache missing/corrupt. **Self-upgrades when new frontier models ship.** |
| `model = "<slug>"` (e.g. `"gpt-5.5"`) | Pin a specific slug. Use for **reproducibility** or when validating a specific model. Skips the cache. |
| `model = ""` | Defer to Codex CLI's `--model` default. **Documented unsafe** (v2.1.1 incident); kept only for adopters who explicitly depend on it. |

If you keep your existing value (whatever it is), nothing breaks.

#### Adopter recommendation: keep your current value for one
maintenance cycle, then flip to `"auto"`

If you've been running `model = "gpt-5.5"` since v2.1.1, that's
still working today. The pack maintainer is dogfooding `"auto"`
since v2.3.0; once a week or two of field signal accumulates, the
risk of `"auto"` resolving to something unreachable on your account
is well-understood. Until then, `model = "gpt-5.5"` is no worse
than what you had.

#### Fallback override

If you flip to `"auto"` but want a different safety-net slug, set:

```bash
export PRILIVE_MODEL_FALLBACK=gpt-5.5-codex
```

(or whatever your account reaches). The resolver uses this value
on the fallback path. Default fallback is `gpt-5.5`.

### Optional: add explicit `[review] mode` to `tdd-pack.toml`

The field has been consumed by `hooks/inject-findings.sh` since
v2.2 but was not documented in the shipped template. v2.3.0
documents it:

```toml
[review]
# ... existing keys ...

# FDTDD mode hierarchy. Drives the (slice-2+) Gate 1 + Gate 3 rails.
#   off          — both gates disabled, inject-findings rail off
#   soft         — both gates allow; inject-findings emits soft
#                  guidance only. SHIPPED DEFAULT.
#   governed_tdd — gates emit ask prompts
#   strict_tdd   — gates emit hard denies
mode = "soft"
```

If your existing `tdd-pack.toml` lacks `[review] mode`, your
inject-findings hook is already using the implicit default
(`"governed_tdd"`). v2.3.0 ships the explicit value `"soft"` as
the new template default. **Recommendation:** add the explicit
line; pick the value that matches your current expectations.

### Nothing else in `tdd-pack.toml` changes.

The v2.2 `[ops_triage]` block is unchanged. The v2.1 `[severity]`,
`[gate]`, `[audit]`, `[disable]`, `[pre_review]` blocks are
unchanged.

---

## FDTDD marker migration (only if you've used `finding-start.sh`)

v2.3 (task #133 slice 1) moves the active-finding marker:

| Path | Status |
|---|---|
| `.tdd/active-finding` | **Legacy.** Read-only via fallback in `runner/lib/active-finding.sh`. Helpers refuse to write here. |
| `.tdd/findings/active.json` | **New canonical path.** First call to `finding-start.sh` after upgrade writes here. |
| `.tdd/findings/closed/<finding_id>.json` | New: rotated markers from `finding-finish.sh`. |
| `.tdd/findings/pending-reason.txt` | New: §9 file-fallback (slice 6 will wire it). |

### If you have an active legacy marker

`scripts/tdd/finding-start.sh` will refuse to overwrite it. You
have one clear choice:

```bash
# Close it cleanly (handles both v1 and v2 markers):
bash scripts/tdd/finding-finish.sh --reason "v2.3 upgrade"

# Then start fresh; the new marker lands at the v2 path:
bash scripts/tdd/finding-start.sh R<n>-F<n> .tdd/findings/R<n>-F<n>/red-proof.md
```

### If you have no active legacy marker

You don't need to do anything. Future `finding-start.sh` calls
land at the new path automatically.

### Backward compatibility for read paths

`runner/lib/active-finding.sh` (extended in v2.3) reads
whichever path exists; existing hooks that depend on the marker
continue to work transparently. v2.1-era markers (missing
v2-only fields like `phase` and `red_proof_accepted`) are
read with the conservative defaults `phase: "red"`,
`red_proof_accepted: false`.

---

## What about the three contract-spike docs?

v2.3.0 ships these as **read-only documentation + fixture sets**.
There is no runtime behavior change from them in this release.

If you're curious or planning to evaluate slice-2 work as it
lands:

- **Grounding adapter (#107)** —
  `docs/GROUNDING_ADAPTER_INTERFACE.md` defines how sibling-pack
  per-language tool grounding will work (Go is built-in; Python /
  TypeScript / etc. would be sibling packs). Slice 2 will refactor
  `runner/tool-grounding.sh` to read this contract.
- **FDTDD Stage 1 (#133)** —
  `docs/FDTDD-MARKER-CONTRACT.md` +
  `docs/FDTDD-SLICE1-PRECHECKLIST.md` document the v2 marker
  schema. Slice 2 will ship Gate 1 (pre-Tier-1-prod-edit) and
  `finding-accept-red.sh`.
- **Codex sandbox (#105)** —
  `docs/RESEARCH-codex-sandbox-features.md` reports the empirical
  research that gates slice 2 (switch the runner from
  `--dangerously-bypass-approvals-and-sandbox` to
  `--sandbox workspace-write --add-dir`).

None of these affect v2.3.0 runtime.

---

## Rollback

Per-feature rollback (each is independent):

- **Roll back the model resolver default** — set
  `[codex] model = "gpt-5.5"` (or your prior literal pin) in
  `tdd-pack.toml`. The resolver respects the pin; no other change
  needed.
- **Roll back the FDTDD marker move** — set the v2 marker aside
  manually and let your hooks read the legacy path. Or just keep
  using v2.2 → there's no Stage 1 enforcement in v2.3.0 that
  depends on the new path.
- **Roll back the ops-preflight bug fix** — drop `-m "${MODEL}"`
  from the `codex exec` call in `runner/ops-preflight-review.sh`.
  (Not recommended — this re-introduces the v2.1.1 trap.)
- **Roll back the explicit `[review] mode = "soft"`** — delete
  the line; the implicit default takes over.

Full rollback to v2.2.x:

```bash
# From your project root:
cd ~/your-go-project
git clone --depth 1 --branch v2.2.0 \
  git@github.com:prilive-com/go-tdd-pack.git /tmp/go-tdd-pack-v2.2
PACK=/tmp/go-tdd-pack-v2.2
cp -R "$PACK/hooks/."   hooks/
cp -R "$PACK/runner/."  runner/
cp -R "$PACK/prompts/." prompts/
cp -R "$PACK/schemas/." schemas/
cp -R "$PACK/test/."    test/
# Manually drop the new v2.3-only files (or just leave them — they
# are unreferenced by v2.2 hooks/runners):
rm -rf test/fixtures/codex-models-cache \
       test/fixtures/grounding-parity \
       test/fixtures/pretooluse-payloads \
       scripts/research \
       docs/research \
       docs/PROPOSAL-model-auto-select.md \
       docs/PROPOSAL-grounding-adapter-interface.md \
       docs/PROPOSAL-fdtdd-stage1-rails.md \
       docs/PROPOSAL-safer-execution-mode.md \
       docs/GROUNDING_ADAPTER_INTERFACE.md \
       docs/FDTDD-MARKER-CONTRACT.md \
       docs/FDTDD-SLICE1-PRECHECKLIST.md \
       docs/RESEARCH-codex-sandbox-features.md \
       schemas/codex-models-cache.schema.json \
       schemas/active-finding.schema.json \
       runner/lib/resolve-model.sh
```

`tdd-pack.toml`, `CLAUDE.md`, `.claude/settings.json`, and any
adopter-owned files are not touched by either upgrade or rollback.

---

## Compatibility floors (unchanged from v2.2)

- **Claude Code ≥ 2.1.89.** Earlier versions treat hook
  `permissionDecision: "defer"` as `allow` in non-interactive
  mode.
- **Codex CLI ≥ 0.122** for `--ignore-user-config`. v2.3 verified
  against 0.129.0.
- **Go ≥ 1.26.2** for the `go fix` modernize path.
- **Tooling:** `bash`, `jq`, `git`, `gofmt`. Strongly recommended:
  `gitleaks`, `goimports`, `golangci-lint`, `govulncheck`.

---

## References

- [`CHANGELOG.md`](../CHANGELOG.md) — full v2.3.0 entry with PR
  numbers + technical detail.
- [`README.md`](../README.md) — current product line + project
  status.
- [`ADOPTION_GUIDE.md`](ADOPTION_GUIDE.md) — fresh-install path.
- v2.3 contract spikes (read-only in v2.3.0; slice 2+ will land
  the implementations):
  - [`PROPOSAL-model-auto-select.md`](PROPOSAL-model-auto-select.md)
    + addendum (the design + Codex review of the resolver shipped
    in v2.3.0)
  - [`PROPOSAL-grounding-adapter-interface.md`](PROPOSAL-grounding-adapter-interface.md)
    + addendum
  - [`PROPOSAL-fdtdd-stage1-rails.md`](PROPOSAL-fdtdd-stage1-rails.md)
    + addendum
  - [`PROPOSAL-safer-execution-mode.md`](PROPOSAL-safer-execution-mode.md)
    + addendum
