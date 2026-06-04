# Update notes: v2.0.x → v2.1.0 (and v1.9.x → v2.1.0)

> **Audience.** A developer who already installed the Prilive Go TDD
> Pack at **v2.0.0, v2.0.1, or v1.9.x** via the project-copy path
> (`git clone` + `cp -R`) and wants to move to **v2.1.0**.
>
> - **From v2.0.x:** read the main body of this guide top-to-bottom.
> - **From v1.9.x:** read the main body of this guide AND the
>   ["Coming from v1.x"](#coming-from-v1x) section below it for the
>   extra cleanup work that does not apply to v2.0.x adopters.
>
> First time installing? Read
> [`ADOPTION_GUIDE.md`](ADOPTION_GUIDE.md) instead.
>
> On the plugin install path (`/plugin install`)? This guide does NOT
> cover that path yet — see "Plugin path" at the bottom for a short note.

This guide tests the upgrade path **before** the public v2.1.0 release.
Run through it on a real project. Report any step that does not behave
as written.

---

## TL;DR — happy path

```bash
# 0. In your project, confirm your starting state.
cat .claude-plugin/plugin.json 2>/dev/null | jq -r '.version' || \
  grep -E '^# v[0-9]' hooks/post-edit-review.sh | head -1
# Expect: 2.0.0 or 2.0.1.

git status -sb                     # working tree MUST be clean
git branch -m main pre-v2.1-backup # safety branch on your project
git checkout -b try-v2.1

# 1. Pull the v2.1.0 pack source.
git clone --depth 1 --branch v2.1.0 \
  git@github.com:prilive-com/go-tdd-pack.git /tmp/go-tdd-pack-v2.1

# 2. Refresh pack-owned trees (overwrites pack files only; your
#    CLAUDE.md / AGENTS.md / tdd-pack.toml / .claude/settings.json
#    are NOT touched here).
cd ~/your-go-project
PACK=/tmp/go-tdd-pack-v2.1

cp -R "$PACK/hooks/."    hooks/
cp -R "$PACK/runner/."   runner/
cp -R "$PACK/prompts/."  prompts/
cp -R "$PACK/schemas/."  schemas/
cp -R "$PACK/test/."     test/

# v2.1 NEW: FDTDD helper scripts (Finding-Driven TDD foundation).
mkdir -p scripts/tdd
cp -R "$PACK/scripts/tdd/." scripts/tdd/

# v2.1 NEW: Tier-1 path configuration example (commit it if you want
# perspective-diverse review on protected paths; safe to skip for now).
mkdir -p .tdd
cp "$PACK/.tdd/tiers.toml.example" .tdd/tiers.toml.example

chmod +x hooks/*.sh runner/*.sh runner/lib/*.sh \
         scripts/tdd/*.sh test/smoke-*.sh

# 3. Reconcile your configs (see "Config merge" section below).

# 4. Verify.
bash test/smoke-v2-phase2.sh        # ~1s, 25+ checks, no Codex calls
bash test/smoke-tool-grounding.sh   # ~2s, fixture checks
bash test/smoke-plugin-manifest-v21.sh        # only if you ALSO ship a plugin manifest
bash test/smoke-config-default-consistency.sh
bash test/smoke-carveout-schema-consistency.sh
bash test/smoke-protect-tdd-artifacts-traversal.sh

# 5. End-to-end smoke (one real Codex call, ~30s).
bash test/smoke-v2-mvp.sh
```

If every step prints `PASS`, the upgrade landed. Make a real edit in a
Go file and confirm the Codex review fires (see "Manual end-to-end
check" below).

---

## What changed (5-minute read)

v2.1.0 is a quality release. Twelve PRs (#19–#31). The full list is in
[`CHANGELOG.md`](../CHANGELOG.md); the items below are the ones a v2.0.x
adopter needs to be aware of.

### One user-visible default change

- **`tdd-pack.toml` `[pre_review]` now ships `enabled = false`.**
  v2.0.x docs always said pre-write gating was off by default, but a
  leaked dogfooding flip shipped it as `enabled = true`. v2.1.0 brings
  the literal value into line with the docs. If you want pre-write
  gating, set `enabled = true` yourself.

### New hooks (must be registered)

- `hooks/protect-tdd-artifacts.sh` — PreToolUse Gate 4. Blocks direct
  Claude edits to engine-owned artifacts (`.tdd/findings/**`,
  `.tdd/queue/**`, `.tdd/reviews/state.json`, ledger, debate log, the
  FDTDD active-finding marker). Runner writes are unaffected.
- `hooks/pre-review.sh` — PreToolUse pre-write gate (only fires when
  you turn `[pre_review] enabled = true`; no-ops otherwise).

### New runner code

- `runner/lib/active-finding.sh`, `runner/lib/codex-capabilities.sh`,
  `runner/lib/tier1.sh` — library files the runner sources.
- `runner/pre-review-worker.sh` — runs the pre-write Codex pass.

### New schemas

- `schemas/pre-review-verdict.schema.json` — strict shape for the
  pre-write reviewer's allow/deny/ask decision.
- `schemas/findings-round1.schema.json` — description updated for
  `contradicts_grounding`; enum unchanged.

### New rails (silent behavior; no config required)

- Tool-grounding demotion (Rail A) with semantic carve-out:
  `correctness | design | test_quality | security` are never demoted.
- Confidence floor (Rail B) — `severity.confidence_floor = 4` default
  drops findings below high static evidence.
- `line_scope` routing (Rail C) — `pre_existing_unrelated` findings
  get demoted.
- Perspective-diverse consensus (Rail D) — foundation only in v2.1;
  the parallel producer ships in v2.2.

You should see fewer noise findings surfaced as must-address; demoted
findings are still shown but flagged informational.

### FDTDD foundation

- `.tdd/active-finding` marker file.
- `scripts/tdd/finding-start.sh` and `scripts/tdd/finding-finish.sh`
  for the Red → Green flow.
- Gate 4 protects the marker so only the helpers can change it.

No behavior change unless you use the helpers. Safe to ignore for this
test.

### Removed

- The Bash matcher under PostToolUse / PreToolUse for review hooks is
  gone. Runtime command safety is out of scope for the dev-time
  review pack. If your `.claude/settings.json` still has a Bash
  matcher pointing at `post-edit-review.sh`, remove it (see Config
  merge below).

Full list in [`CHANGELOG.md` § 2.1.0](../CHANGELOG.md).

---

## Config merge

Three files are adopter-customized. v2.1.0 does NOT overwrite them
during the `cp -R` step. You merge the deltas by hand.

### 1. `tdd-pack.toml`

Open both files side by side:

```bash
diff -u tdd-pack.toml "$PACK/tdd-pack.toml" | less
```

Keys you must reconcile:

| Key | v2.0.x | v2.1.0 | Action |
|---|---|---|---|
| `[severity] confidence_floor` | not present | `4` | Add (default; raise to 5 for stricter must-address) |
| `[review] mode` | not present | `"governed_tdd"` (implicit default) | Add explicitly if you want `strict_tdd` or a non-TDD mode |
| `[pre_review] enabled` | `true` (leaked) or absent | `false` | Set `false` unless you actually want pre-write gating |
| `[tiers]` table | not present | example in `.tdd/tiers.toml.example` | Optional; copy if you want Rail D perspective review on Tier-1 paths |

Everything else (`max_rounds`, `model`, `reasoning_effort`,
`web_search`, `min_surface`) is unchanged; keep your local values.

### 2. `.claude/settings.json`

The v2.1.0 `hooks/settings.json` template registers the new hooks.
Open both:

```bash
diff -u .claude/settings.json "$PACK/hooks/settings.json" | less
```

Merge these three deltas into your `.claude/settings.json`:

**A. Add Gate 4 + pre-review to PreToolUse (file matcher only):**

```json
{
  "matcher": "Edit|Write|MultiEdit|NotebookEdit",
  "hooks": [
    {
      "type": "command",
      "command": "${CLAUDE_PROJECT_DIR}/hooks/protect-tdd-artifacts.sh",
      "timeout": 5
    },
    {
      "type": "command",
      "command": "${CLAUDE_PROJECT_DIR}/hooks/pre-review.sh",
      "timeout": 120
    }
  ]
}
```

> **Order matters.** `protect-tdd-artifacts.sh` MUST be registered
> before `pre-review.sh`. Gate 4 is fail-closed for engine artifacts;
> pre-review is opt-in for everything else.

**B. Remove the Bash PostToolUse matcher**, if present. It looks like:

```json
{
  "matcher": "Bash",
  "hooks": [
    {
      "type": "command",
      "command": "$CLAUDE_PROJECT_DIR/hooks/post-edit-review.sh",
      "async": true,
      "timeout": 5
    }
  ]
}
```

Delete the whole block. v2.1.0 reviews file edits only, not Bash
commands.

**C. Confirm the file PostToolUse matcher** still registers
`post-edit-review.sh` AND `inject-findings.sh` under
`Edit|Write|MultiEdit`. No change needed if it already does.

Validate JSON after editing:

```bash
jq empty .claude/settings.json && echo OK
```

### 3. `.claude-plugin/plugin.json` (only if you ship a manifest)

If your project does NOT have `.claude-plugin/plugin.json`, skip this.
It is for the plugin install path; project-copy adopters do not need
one.

If you do have it, the manifest is fully overwritable from
`$PACK/.claude-plugin/plugin.json` — no per-project state in it.

---

## Verify

Run the smokes in this order; stop and report at the first failure:

```bash
bash test/smoke-v2-phase2.sh                       # 25+ unit checks
bash test/smoke-tool-grounding.sh                  # fixture checks
bash test/smoke-config-default-consistency.sh      # B2 guard
bash test/smoke-carveout-schema-consistency.sh     # B4 guard
bash test/smoke-protect-tdd-artifacts.sh           # Gate 4 base
bash test/smoke-protect-tdd-artifacts-traversal.sh # Gate 4 traversal (NEW)
bash test/smoke-active-finding.sh                  # FDTDD marker (NEW)
bash test/smoke-grounding-demotion.sh              # Rail A
bash test/smoke-perspective-ensemble.sh            # Rail D foundation
bash test/smoke-escalate-origin-aware.sh           # origin-aware A/B/V

# Plugin-install adopters ALSO run this; project-copy adopters skip:
# bash test/smoke-plugin-manifest-v21.sh
```

> **`smoke-plugin-manifest-v21.sh` is plugin-install only.** It hard-
> fails with `plugin manifest not found` if `.claude-plugin/plugin.json`
> is absent. Project-copy installs do not ship that file and do not
> need it — hook registrations come from `.claude/settings.json` on
> this path. Skip the smoke; nothing else in v2.1.0 depends on the
> manifest existing.

Expected: each smoke above prints `PASS` with a check count, exit 0.
Total wall time under 5 seconds; no Codex calls.

Live end-to-end (one real Codex call, ~30 s):

```bash
bash test/smoke-v2-mvp.sh
```

This one requires a clean working tree and a valid `codex login`. It
makes a real Codex round-1 call against a fixture and asserts the
verdict shape, the no-project-writes invariant, and the active-finding
marker behavior.

---

## Manual end-to-end check

Pure smoke output is necessary but not sufficient. Confirm the actual
review path fires in a Claude Code session:

1. Open this project in Claude Code.
2. Ask Claude to make a small Go change — for example, "rename
   `helper` to `Helper` in `internal/foo/bar.go`".
3. After the edit, you should see (within ~10 s):
   - A new directory under `.tdd/reviews/cycle-<id>/`.
   - `round-1.json` containing findings.
   - In your next Claude turn, an injected `[Codex review]` block
     with findings classified as `must address` and/or `speculative`.
4. Confirm the demotion semantics:
   - At least one demoted finding should carry a
     `(demoted: contradicts_grounding|low_confidence|...)` reason
     when applicable.
   - No finding labeled `[blocker]` should appear for unchanged
     surrounding code.

If any of the above does NOT happen, see "If something breaks" below.

---

## Rollback (hard)

If the upgrade misbehaves and you need to get back to v2.0.1 fast:

```bash
# 1. Get the v2.0.1 pack source.
git clone --depth 1 --branch v2.0.1 \
  git@github.com:prilive-com/go-tdd-pack.git /tmp/go-tdd-pack-v2.0.1

cd ~/your-go-project
PACK_OLD=/tmp/go-tdd-pack-v2.0.1

# 2. Remove the v2.1-only files.
rm -f  hooks/pre-review.sh
rm -f  hooks/protect-tdd-artifacts.sh
rm -f  runner/pre-review-worker.sh
rm -f  runner/lib/active-finding.sh
rm -f  runner/lib/codex-capabilities.sh
rm -f  runner/lib/tier1.sh
rm -rf scripts/tdd
rm -f  schemas/pre-review-verdict.schema.json
rm -f  test/smoke-active-finding.sh
rm -f  test/smoke-carveout-schema-consistency.sh
rm -f  test/smoke-codex-capabilities.sh
rm -f  test/smoke-config-default-consistency.sh
rm -f  test/smoke-escalate-origin-aware.sh
rm -f  test/smoke-perspective-ensemble.sh
rm -f  test/smoke-plugin-manifest-v21.sh
rm -f  test/smoke-pre-review-protocol.sh
rm -f  test/smoke-pre-review-worker.sh
rm -f  test/smoke-protect-tdd-artifacts.sh
rm -f  test/smoke-protect-tdd-artifacts-traversal.sh
rm -f  prompts/codex-pre-review-file-user.md
rm -f  prompts/codex-pre-review-system.md
rm -f  prompts/codex-system-correctness.md
rm -f  prompts/codex-system-security.md

# 3. Restore v2.0.1 pack files.
cp -R "$PACK_OLD/hooks/."   hooks/
cp -R "$PACK_OLD/runner/."  runner/
cp -R "$PACK_OLD/prompts/." prompts/
cp -R "$PACK_OLD/schemas/." schemas/
cp -R "$PACK_OLD/test/."    test/
chmod +x hooks/*.sh runner/*.sh test/smoke-*.sh

# 4. Revert your settings.json + tdd-pack.toml edits manually:
#    - Remove the Gate 4 + pre-review block from PreToolUse.
#    - Restore the Bash PostToolUse matcher IF you had one before.
#    - Remove `confidence_floor` and `review.mode` from tdd-pack.toml.
#
#    Easiest: `git checkout HEAD -- .claude/settings.json tdd-pack.toml`
#    if your working tree was clean before the upgrade.

# 5. Verify.
bash test/smoke-v2-phase2.sh
```

You are now back on the v2.0.1 pack with your project unchanged.

---

## If something breaks

Order of escalation:

1. **Kill the runner for the session** —
   `export PRILIVE_REVIEW_DISABLE=1` in your shell. The pack
   no-ops; you can keep working.
2. **Read `.tdd/runner.log` and `.tdd/install-error.log`.** Most v2.1
   failures surface here with a one-line cause (expired Codex auth,
   missing tool on PATH, schema parse error).
3. **Re-run a single smoke with `bash -x`** to see the failure point:
   `bash -x test/smoke-grounding-demotion.sh 2>&1 | tail -40`.
4. **Hard rollback** (above) if a smoke fails on a clean v2.1.0 install
   and the cause is not obvious in 5 minutes.

Report any test path that fails on a clean v2.1.0 install with:

- Output of `bash <smoke>.sh 2>&1 | tail -30`.
- `jq -r '.version' .claude-plugin/plugin.json 2>/dev/null` (if you
  have a manifest) or the commit SHA of the pack source you copied
  from.
- The exact step from this guide where the failure started.

File at https://github.com/prilive-com/go-tdd-pack/issues.

---

## Coming from v1.x

This section is the extra work a v1.9.x adopter does on top of the
main body above. Skip if you are already on v2.0.x.

> **v1.x → v2.1.0 is a supported direct path.** There is no incremental
> advantage to going through v2.0 first. v2.0.0 was the architectural
> pivot — it dropped the v1.x ceremony model (Tier 1/2/3, SPEC.md,
> second-opinion skill, blocking PreToolUse ceremony hooks) and
> replaced it with continuous silent peer review. v2.1.0 adds rails,
> Gate 4, and the FDTDD foundation on top. Going through v2.0 first
> would mean doing the same v1.x cleanup twice.

Read both CHANGELOG entries before starting:
[`## [2.0.0]`](../CHANGELOG.md) is the heavy lift (architectural
pivot); [`## [2.1.0]`](../CHANGELOG.md) is the polish on top.

### How this changes the steps above

| Step | v2.0.x adopter | v1.9.x adopter |
|---|---|---|
| Step 0 (starting state check) | Expect v2.0.0 or v2.0.1 in plugin.json | Expect v1.9.x in your hooks/scripts. Do NOT downgrade through v2.0 first. |
| Step 2 (`cp -R` pack-owned trees) | Same | Same. There is no v1.x state worth preserving in `hooks/`, `runner/`, `prompts/`, `schemas/`, `test/`, `scripts/tdd/`. |
| Step 3 (config merge) | Apply the small v2.0→v2.1 deltas | Do the full rewrites in [v1.x config rewrite](#v1x-config-rewrite) below — `tdd-pack.toml`, `.claude/settings.json`, and `CLAUDE.md` are all near-discard cases. |
| Step 4 (verify) | Smokes pass clean | Same. Skip `smoke-plugin-manifest-v21.sh` (project-copy install). |
| Step 5 (live end-to-end) | Same | Same. |

### v1.x config rewrite

#### `tdd-pack.toml` — no conversion script

The v1.x `.tdd/tdd-config.json` and the v2.x `tdd-pack.toml` are
fundamentally different models. There is no port script and most v1.x
fields have no v2.x equivalent.

| v1.x field | v2.x fate |
|---|---|
| Tier-1 path regexes | **Partial mapping** → `.tdd/tiers.toml` (rename `.example` → real file). Different semantics: Tier-1 in v2.x means "Codex runs multi-perspective review on these paths" (Rail D), not "must run SPEC.md ceremony". Copy your regex set, treat the routing as a fresh decision. |
| Marker aliases | **Drop entirely.** All v1.x markers (SPEC.md, `current-plan.md`, `CYCLE_ABANDONED.txt`, Tier 1/2/3 stamps) are gone. The only v2.x marker is `.tdd/active-finding` and you do not alias it. |
| `no_discretion` block | **Drop entirely.** v1.x: "Claude cannot bypass the second-opinion skill on these paths". v2.x: no skill to bypass — Codex reviews every file edit silently. Closest analogue is Tier-1 + `[pre_review] enabled = true`, but the semantics do not translate cleanly. |
| Tier 2/3 path patterns | **Drop entirely.** v2.x doesn't classify paths into tiers for review beyond Tier-1 (for Rail D) vs everything else. |

**What to do:** start from a fresh copy of v2.1.0 `tdd-pack.toml`, port
only the Tier-1 path regexes into `.tdd/tiers.toml`, then delete
`.tdd/tdd-config.json` after the new setup runs clean.

#### `.claude/settings.json` — surgical removal, not wipe-and-restart

Your file probably mixes three categories of hooks:

1. **v1.x TDD ceremony hooks** — `require-second-opinion.sh`,
   `pre-second-opinion.sh`, `post-second-opinion.sh`, any blocking
   PreToolUse for ceremony. **REMOVE.** No v2 equivalent.
2. **v1.x quality hooks** — `gofmt-after-edit.sh`,
   `scan-for-secrets.sh`, `detect-ai-bloat.sh`,
   `guard-protected-files.sh`, `guard-dangerous-bash.sh`,
   `guard-bash-pipefail.sh`. Not part of v2's review pipeline, but
   harmless if kept. **Recommendation: keep for now**, evaluate
   separately later. They are orthogonal to the review path.
3. **Your own project-specific hooks** — **KEEP.**

Do NOT run `git checkout HEAD -- .claude/settings.json` — that mixes
your last-committed v1.x state with your in-progress edits and is hard
to reason about.

```bash
# 1. Back up the current file
cp .claude/settings.json .claude/settings.json.pre-v2.1

# 2. Surgically remove v1.x ceremony hooks. Open the file and delete
#    any hook block whose command path references:
#      require-second-opinion.sh
#      pre-second-opinion.sh
#      post-second-opinion.sh
#      any *spec* or *ceremony* hook from v1.x

# 3. Add the v2.1 PreToolUse block (file-matcher only):
#    See "Config merge → .claude/settings.json" above. Order matters —
#    protect-tdd-artifacts.sh BEFORE pre-review.sh.

# 4. Add v2.1 PostToolUse + UserPromptSubmit + Stop + SessionStart
#    entries from the v2.1 template:
diff -u .claude/settings.json "$PACK/hooks/settings.json" | less

# 5. Validate
jq empty .claude/settings.json && echo OK
```

#### `CLAUDE.md` — delete the stale governance block, replace with v2.1 base, keep project-specific sections

The v1.x patch notes block (`v1.9.4 + v1.9.8` patches, bootstrap
bypasses, etc.) documents ceremony-model quirks that no longer exist.
It is pure stale content on v2.x.

```bash
# 1. Diff your current CLAUDE.md against the v2.1 stock CLAUDE.md
diff -u CLAUDE.md "$PACK/CLAUDE.md" | less

# 2. KEEP from your current CLAUDE.md:
#    - Project-specific sections (your domain conventions, your team's
#      review norms, paths/patterns unique to your codebase)
#    - CODEOWNERS / review-routing decisions
#    - Project-domain rules NOT covered by v2.1 stock content

# 3. DELETE entirely:
#    - The v1.9.4 / v1.9.8 patch notes block (stale)
#    - Bootstrap bypass documentation (no longer a thing in v2)
#    - Any reference to SPEC.md, current-plan.md, second-opinion skill,
#      Tier 1/2/3 ceremony, CYCLE_ABANDONED.txt
#    - Any "require-second-opinion" guidance

# 4. REPLACE with v2.1 stock content:
#    - Continuous-review architecture explanation
#    - Pack version reference
#    - Hook contract
#    - Available slash commands

# Practical approach: take v2.1's CLAUDE.md as the base, layer your
# project-specific sections at the bottom, commit, review, iterate.
```

Same approach for `AGENTS.md` if you have one.

### v1.x cleanup checklist

After the rewrite, delete files that no longer exist in v2.x. These
were the v1.x ceremony state and live in the project tree:

```bash
rm -rf .tdd/current-plan.md
rm -rf .tdd/cycles/
rm -rf .tdd/exceptions/
rm -rf .tdd/tdd-config.json        # after porting Tier-1 regexes
rm -f  .claude/hooks/require-second-opinion.sh
rm -f  SPEC.md                     # if you have a stale one at root
rm -f  CYCLE_ABANDONED.txt         # if you have a stale one at root
```

Keep `.tdd/reviews/` (v2.x cycle artifacts) and `.tdd/findings/` (v2.1
FDTDD artifacts) if they exist — those are the new state.

### Rollback caveat for v1.x adopters

The hard rollback procedure in this guide targets v2.0.1. If you came
from v1.9.x and decide v2.1.0 does not work for you, do NOT try to
"rollback to v1.9.x" with the same procedure — the v1.x ceremony
files were already deleted as part of the upgrade. Either:

1. Stay on v2.1.0 with `PRILIVE_REVIEW_DISABLE=1` until the cause is
   understood.
2. Restore your v1.9.x state from git: `git checkout pre-v2.1-backup`
   (the safety branch you made in Step 0 of the TL;DR).

---

## Plugin path (note)

If you installed via `/plugin install go-tdd-pack@...`, the update
flow is different and not covered here. In short: the plugin manager
re-reads `.claude-plugin/plugin.json` on update, so most changes land
automatically. You still need to:

- Apply the `tdd-pack.toml` and `.claude/settings.json` deltas above
  (these are project-owned, not plugin-owned).
- Run the smoke verify pass.

A dedicated plugin-path update guide will ship before the public v2.1.0
release.
