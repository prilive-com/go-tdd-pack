# Update notes: v1.9.4 → v1.10.3

If your project pulled the starter pack at any version v1.9.4 or
earlier and you want to move to current (v1.10.3, `origin/main` at
`b4ec424`), this is the changelog you need to read in 5 minutes.

## TL;DR — how to update

From your project root (wherever you have the pack files):

```bash
# 1. Pull the latest pack source
cd $YOUR_STARTER_CHECKOUT
git pull origin main
git log --oneline -1
# Expect: b4ec424 (or later)

# 2. In your adopting project, refresh the pack files
cd $YOUR_PROJECT
STARTER=$YOUR_STARTER_CHECKOUT
cp -R "$STARTER/.claude/hooks/"*.sh   .claude/hooks/
cp -R "$STARTER/.claude/skills/"*     .claude/skills/
cp -R "$STARTER/.claude/commands/"*   .claude/commands/  # v1.10.2 added
cp -R "$STARTER/scripts/tdd/"*        scripts/tdd/
cp     "$STARTER/scripts/doctor.sh"   scripts/
cp     "$STARTER/scripts/tdd-test-hooks.sh" scripts/
chmod +x .claude/hooks/*.sh scripts/tdd/*.sh scripts/*.sh

# 3. Refresh the schema (v1.9.2, v1.9.3, v1.9.8 schema fixes)
cp "$STARTER/.tdd/templates/review-completion.schema.json" \
   .tdd/templates/review-completion.schema.json

# 4. Verify smoke
bash scripts/tdd-test-hooks.sh 2>&1 | tail -3
# Expect: Results: 591 passed, 0 failed (or more)

# 5. Add v1.10.2 runtime paths to your .gitignore
echo '.tdd/cycles/' >> .gitignore
echo '.tdd/active'  >> .gitignore
echo '.tdd/abandoned/' >> .gitignore
```

**No config changes required.** All v1.9.x and v1.10.x changes
preserve backward compatibility with existing `.tdd/tdd-config.json`.
Two optional new knobs are documented in the "New config knobs"
section below.

## What you get (by release)

### v1.10.3 — governance file refinements (2026-05-16)

Doc-only release. If you maintain a fork of the starter pack, pull
the new versions of:

- `NOTICE` — stripped of acknowledgments per ASF guidance
- `CHANGELOG.md` — first-public release is now v1.10.2; v1.0–v1.6
  collapsed to a pre-public summary
- `CONTRIBUTING.md` — added change-risk tier table; DCO app updated
  to `cncf/dco2`
- `CODE_OF_CONDUCT.md` — inlined full Contributor Covenant 3.0
- `SECURITY.md` — CVSS v4.0 anchored severity bands; added
  CVE-2026-21852 alongside CVE-2025-59536; disclosure-window levers
- `MAINTAINERS.md` — concrete co-maintainer criteria; succession plan

If you are an adopter (not a fork maintainer), you can ignore this
release.

### v1.10.2 — smooth session-resumption UX (2026-05-16)

**This is the one that matters most for daily flow.** When you
`/exit` mid-cycle and come back later:

- Stop hook writes `.tdd/cycles/<cycle-id>/state.json` capturing
  the cycle's status, next_actor, approved_rounds, and a
  human-readable continuation hint.
- A pointer `.tdd/active` names the most recent cycle.
- On the next `claude`, the SessionStart hook auto-injects the
  state as continuation context. You see something like:
  > Active TDD cycle: my-cycle-id | status=approved | next_actor=claude | approved_rounds=2 | hint: ...
- If SessionStart silently drops the injection
  (anthropics/claude-code#10373 — known bug for brand-new sessions),
  run `/continue` (active cycle) or `/resume <cycle-id>` (specific)
  as explicit fallback. These slash commands are new and live in
  `.claude/commands/continue.md` and `.claude/commands/resume.md`.

Also new: `scripts/tdd/validate-codex-output.sh` — an external
validator for Codex output, defense-in-depth against
`openai/codex#15451` where `--output-schema` is silently ignored
when shell tools are active.

**Action**: copy `.claude/commands/` and `scripts/tdd/validate-codex-output.sh`
from the starter; add `.tdd/cycles/`, `.tdd/active`, `.tdd/abandoned/`
to your `.gitignore`.

### v1.10.1 — production trigger honors `tier1_path_regexes` (2026-05-16)

**This is the second-most-important change.** Pre-v1.10.1, the
production-edit trigger fired on every `.go` file regardless of
your Tier 1 config. Result: low-stakes refactors required full
ceremony + manual cycle abandonment on `/exit`. After v1.10.1:

- Tier 2 edits are **silent** — no obligation, no ceremony.
- Tier 1 edits still get the full ceremony.
- Tier 1 vs Tier 2 is decided by your `.tdd/tdd-config.json`
  `tier1_path_regexes`.

**Action**: nothing required. Your existing `tier1_path_regexes` now
actually governs production-edit ceremony as documented.

**Optional**: if you previously widened `tier1_path_regexes` to
`.+\.go$` hoping v1.9 would gate everything, you can now narrow it
back to security/payment/storage paths. v1.10.1's behavior matches
what your config has been claiming all along.

**Override**: if you actually want "force ceremony on Tier 2 too"
(for a high-risk refactor week, say), set
`second_opinion.no_discretion.production_edits_all_tiers: true`.

### v1.10.0 — Codex runs with full real-environment access (2026-05-16)

**Behavior change.** Pre-v1.10.0, Codex was invoked with
`--sandbox read-only` — which (per OpenAI's docs) blocks BOTH writes
AND spawned shell commands. So Codex could NOT `cat`, `ls`, `grep`,
`go test`, etc. Every supporting file became a context-request round.

After v1.10.0, Codex runs with the SAME environment Claude Code
itself runs in: `--sandbox danger-full-access --ask-for-approval never
--cd $project_root`. Real files, real OS, real network, real commands.
ONE rule, enforced by the prompt + Codex cooperation: do not write
files (`Edit`, `>`, `mv`, `cp`, `git commit`, etc. all forbidden).

**Trust model**: identical to how you trust Claude CLI. The operator
made this choice explicitly after the ~300K-token cycle of context
blindness in v1.9.x.

**Action**: nothing required if you accept this trust model. If you
want stricter sandboxing, revert your local runner script's flags or
fork the starter.

### v1.9.11 — wrong assumption fix (later superseded by v1.10.0)

This release added text to the prompt telling Codex to "use sandbox
tools to cat files" — based on a wrong assumption that read-only
sandbox allows command execution. **v1.10.0 made this moot** by
switching to full-access sandbox. The prompt text is harmless either
way; no action required.

### v1.9.10 — MC pattern detection loosened (2026-05-16)

When Codex emits "missing context" findings, v1.9.9 required both
`id` prefix `MC-` AND `failure_mode` starting with `missing context:`.
Real Codex output kept F1/F2 ids. v1.9.10 dropped the id check;
`failure_mode` prefix alone is now the signal.

**Action**: none.

### v1.9.9 — "missing context" pattern (2026-05-16)

Added: Codex can return findings with `failure_mode: "missing context:
<file>"` when it can't see a supporting file. The runner recognizes
these as context-request rounds (not defect rounds) and surfaces the
requested paths to the operator. These rounds do not count toward
`max_review_rounds_per_cycle`. v1.10.0 mostly obviates this (Codex
can now `cat` files directly), but the MC pattern remains as a
fallback for genuine read failures.

**Action**: none.

### v1.9.8 — two real-Codex-only schema bugs (2026-05-16)

Two one-liners that lurked because the unit smoke never invokes real
Codex:

1. **Schema root `required` was missing 3 of 9 properties.** OpenAI
   strict mode rejected with `Missing 'summary'`. Fixed.
2. **Runner used `all(.; ...)` two-arg form** with `.` as generator
   (emits array as single value). Inner condition tried `.id` on
   the array → "Cannot index array with string id." Fixed to
   `all(.[]; ...)` (iterate elements).

**Action**: pull the updated `.tdd/templates/review-completion.schema.json`
and `scripts/tdd/run-second-opinion.sh`. No config change.

### v1.9.7 — cycle abandonment durably closes the cycle (2026-05-15)

Pre-v1.9.7, writing `.tdd/CYCLE_ABANDONED.txt` only allowed `/exit`
once; the pending obligation stayed forever and a stale file could
leak across cycles. After v1.9.7: matching pending entries transition
to `status: "abandoned"`, an SHA-chained `cycle_abandoned` audit
entry is appended, and the file rotates to
`.tdd/abandoned/<cycle_id>-<unix_ts>.txt`.

**Action**: pull `.claude/hooks/session-stop-review.sh`. Add
`.tdd/abandoned/` to `.gitignore` (covered in the TL;DR above).

### v1.9.6 — CYCLE_ABANDONED deny message clarity (2026-05-15)

Pre-v1.9.6, the Stop hook block message and the bash-pretrigger gate
worded the abandonment instruction as if the agent could execute it.
The agent cannot — that's by design. Updated messages now explain
this explicitly so the operator sees what action is required of them.

**Action**: pull `.claude/hooks/session-stop-review.sh` and
`.claude/hooks/second-opinion-bash-pretrigger.sh`.

### v1.9.5 — pack now self-enforces v1.9 ceremony (2026-05-15)

The starter pack itself now runs with `no_discretion: true` in its
own config. This affects the pack's development, not your project.

**Action**: nothing required for adopters.

### v1.9.4 — legacy hook defers when no-discretion enabled (2026-05-15)

**Most critical fix in this whole arc.** v1.9.0 introduced the new
trigger system but didn't retire the legacy
`require-second-opinion.sh` hook. The legacy hook demanded
`.tdd/second-opinion-completed.md`, which the v1.9 runner does not
write; the skill that wrote it was disabled
(`disable-model-invocation: true`); the agent deadlocked on every
Edit/Write/Bash with no way out except the killswitch.

After v1.9.4: legacy hook reads
`second_opinion.no_discretion.enabled` and exits 0 (allow) when
true. The v1.9 trigger hooks own the gate in that mode.

**Action**: pull `.claude/hooks/require-second-opinion.sh`. If you
have `no_discretion.enabled: true` in your config (anything from
v1.9.0 forward), this fix is REQUIRED to avoid the deadlock.

## Breaking changes

**None.** Every v1.9.x and v1.10.x fix preserves backward
compatibility with existing `.tdd/tdd-config.json` files. The only
behavior changes that could surprise you:

| Behavior change | Version | When you'll notice |
|---|---|---|
| Tier 2 production edits no longer trigger ceremony | v1.10.1 | Refactor a file outside your `tier1_path_regexes` — no review prompt. This is the intended behavior. |
| Codex can read all project files / run all commands | v1.10.0 | Codex reviews include `cat` / `go test` / `git log` results. No file writes (enforced by prompt). |
| Stop hook writes state files | v1.10.2 | New files appear in `.tdd/cycles/` and `.tdd/active`. Gitignore them. |
| `.tdd/abandoned/` directory appears | v1.9.7 | After your first cycle abandonment. Gitignore it. |

## New config knobs (optional)

```jsonc
{
  "second_opinion": {
    "no_discretion": {
      // v1.9.1: hard cap on review iterations per cycle per review_type.
      // Default 4. Empirical: v1.9.0's own cycle ran 10 rounds and round
      // 10 introduced a regression from round 9. The cap forces ship +
      // queue remaining findings instead of indefinite churn.
      "max_review_rounds_per_cycle": 4,

      // v1.10.1: force production_edit ceremony on Tier 2 files too.
      // Default false (only Tier 1 paths fire). Set true during
      // high-risk refactor weeks. Documented in v1.10.1 release notes.
      "production_edits_all_tiers": false
    }
  }
}
```

## Known limitations after update

1. **SessionStart context auto-injection is unreliable for
   brand-new conversations** (`anthropics/claude-code#10373`). The
   hook fires but the output sometimes isn't injected. Works on
   `/clear`, `/compact`, URL resume. **Workaround built in**: run
   `/continue` or `/resume <cycle-id>` and Claude reads the state
   explicitly.

2. **Smoke suite may fail in monorepos** if your `tier1_path_regexes`
   use service-prefixed paths (e.g., `privy-tg-bot/internal/auth/...`)
   while the starter's smoke fixtures use bare paths
   (`internal/auth/handler.go`). Same root cause we hit at
   devopspoint. v1.10 backlog: host-config-isolated smoke fixtures.
   Until then, do not gate CI on the starter's smoke suite in a
   monorepo.

3. **End-to-end runner Codex smoke is still missing.** Every adopter
   bug in the v1.9.2 → v1.10.0 cycle would have been caught at
   author-time by a test that invokes real Codex against a tiny diff
   and asserts the response parses. v1.10 backlog. Until then, real
   Codex invocations remain the integration test.

## Where to file issues

- **Bug reports**: open an issue at the starter pack's repository
  with: the version you pulled (commit SHA), the exact command that
  failed, the deny message or runner output, and your
  `.tdd/tdd-config.json` `second_opinion` block.
- **Security**: do NOT open a public issue. Use the starter pack's
  GitHub Private Vulnerability Reporting channel (see `SECURITY.md`).
- **Questions**: open a Discussion on the starter pack repo.

## Audit trail

This update arc was driven entirely by adopter reports during
2026-05-15 and 2026-05-16. Ten patch + three minor releases shipped
in 48 hours. Every fix cites the adopter session that surfaced it
in the commit message. The corresponding CHANGELOG entries are at
`CHANGELOG.md` in the starter pack root.
