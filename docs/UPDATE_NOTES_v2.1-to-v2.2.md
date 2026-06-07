# Update notes: v2.1.x → v2.2.0

> **Audience.** A developer who already installed the Prilive Go TDD
> Pack at **v2.1.x** (via project-copy or plugin install) and wants to
> move to **v2.2.0**.
>
> First time installing? Read
> [`ADOPTION_GUIDE.md`](ADOPTION_GUIDE.md) instead.
>
> Coming from v2.0.x or v1.9.x? Read
> [`UPDATE_NOTES_v2.0-to-v2.1.md`](UPDATE_NOTES_v2.0-to-v2.1.md) FIRST
> to get to v2.1.x, then this guide to get to v2.2.0.

v2.2.0 is **backwards-compatible with v2.1.1** in the happy path. The
new Ops Risk Triage rail is **opt-in and default-off** — code-review-
only adopters see zero behavior change. Adopters who want runtime
command safety follow the opt-in flow below.

---

## TL;DR — what changed

- **One new feature.** The Ops Risk Triage rail: a three-layer Bash-
  command gate (deterministic parser → fast Haiku classifier → Codex
  deep ops-preflight) with ask/governed modes, session-tag-driven
  R2→R3 escalation, and ops-debt accounting.
- **Default off.** `tdd-pack.toml` ships `[ops_triage] enabled = false`.
  Until you opt in, the pack behaves exactly as v2.1.1.
- **Adopter opt-in is a four-step config copy + flip a flag.** See
  ["Enable the ops rail"](#enable-the-ops-rail) below.
- **No breaking changes.** No file-edit or code-review behavior
  changed.

Recommended flow: pull v2.2.0, leave `ops_triage.enabled = false` for
a week, then opt in (observe mode first) when you want runtime
command safety.

---

## TL;DR — happy path

```bash
# 1. Pull the v2.2.0 pack source.
git clone --depth 1 --branch v2.2.0 \
  git@github.com:prilive-com/go-tdd-pack.git /tmp/go-tdd-pack-v2.2

# 2. From your project root, refresh pack-owned trees (overwrites pack
#    files only; your CLAUDE.md / AGENTS.md / tdd-pack.toml /
#    .claude/settings.json are NOT touched here).
cd ~/your-go-project
PACK=/tmp/go-tdd-pack-v2.2

cp -R "$PACK/hooks/."    hooks/
cp -R "$PACK/runner/."   runner/
cp -R "$PACK/prompts/."  prompts/
cp -R "$PACK/schemas/."  schemas/
cp -R "$PACK/test/."     test/

# v2.2 NEW: ops-triage example configs (do NOT auto-copy without .example
# suffix — those are opt-in user-owned).
mkdir -p config
cp "$PACK/config/ops-safe-allowlist.txt.example"          config/
cp "$PACK/config/ops-catastrophic-denylist.txt.example"   config/
cp "$PACK/config/ops-session-tags.txt.example"            config/

# v2.2 NEW: /ops-preflight skill and slash command.
mkdir -p .claude/skills/ops-preflight .claude/commands
cp "$PACK/.claude/skills/ops-preflight/SKILL.md"   .claude/skills/ops-preflight/
cp "$PACK/.claude/commands/ops-preflight.md"      .claude/commands/

chmod +x hooks/*.sh runner/*.sh runner/lib/*.sh \
         scripts/tdd/*.sh test/smoke-*.sh

# 3. Reconcile your configs (see "Config merge" below). Mostly: add the
#    [ops_triage] section to tdd-pack.toml + register the three new
#    Bash hooks in .claude/settings.json.

# 4. Verify (no Codex calls, no API tokens spent).
bash test/smoke-v2-phase2.sh
bash test/smoke-tool-grounding.sh
bash test/smoke-config-default-consistency.sh
bash test/smoke-carveout-schema-consistency.sh
bash test/smoke-protect-tdd-artifacts.sh
bash test/smoke-protect-tdd-artifacts-traversal.sh
bash test/smoke-schema-strict-mode.sh
bash test/smoke-ops-triage-slice1.sh
bash test/smoke-ops-triage-slice2.sh
bash test/smoke-ops-triage-slice3.sh
bash test/smoke-ops-preflight-review.sh
bash test/smoke-ops-triage-slice5.sh
bash test/smoke-ops-triage-slice6.sh
# (smoke-plugin-manifest-v21.sh: skip on project-copy installs.)
```

If every smoke prints `PASS`, the upgrade landed. The ops rail is
installed but disabled. Continue to ["Enable the ops rail"](#enable-the-ops-rail)
when you want it on.

---

## What changed (5-minute read)

v2.2.0 adds one rail. See [`CHANGELOG.md`](../CHANGELOG.md) `## [2.2.0]`
for the full list.

### The new rail (and what each piece does)

```
Bash PreToolUse  →  hooks/ops-risk-triage.sh  (command-type, timeout 15s)
                       │
                       ├─ LAYER 1  deterministic syntax parser (no AI)
                       │     allow if safe NAME (user allowlist) AND
                       │     safe SHAPE (no >, >>, <, |, &&, ||, ;,
                       │     $(), backticks, sudo, secret-like paths)
                       │     → fast-path allow, no model, no log
                       │
                       ├─ LAYER 1b  user-owned catastrophic denylist
                       │     extended-regex patterns; in ask/governed
                       │     → hard-DENY, fail-closed backstop
                       │
                       └─ LAYER 2  Claude Haiku 4.5 fast classifier
                             temperature 0, "unknown is not safe",
                             cached by sha256(cmd+cwd+env+mode+allow_sha+deny_sha)
                             → safe_readonly / local_read / external_read /
                               local_mutation / code_mutation /
                               infra_mutation / destructive / unknown
                             escalation-worthy → emit permissionDecision:ask
                                                 + write .tdd/ops-triage/
                                                   pending-reason.txt (§9 fallback)

Bash PostToolUse →  hooks/ops-debt-track.sh   (timeout 3s)
                       Records mutating commands that ran without a
                       /ops-preflight artifact → .tdd/ops-debt/<sha>.json
                       (auto-clears when artifact appears)

                  →  hooks/ops-tag-session.sh  (timeout 3s)
                       Detects auth/container_uid/config commands →
                       appends tags to .tdd/ops-triage/session-tags.txt
                       Next Bash classifier reads these as
                       recent_operation_tags AND engine escalates
                       infra_mutation → destructive when auth/uid present

Stop hook        →   hooks/ops-debt-stop.sh   (timeout 3s)
                       Blocks turn-end while .tdd/ops-debt/*.json files
                       exist; loop-guard via stop_hook_active.

LAYER 3 (manual) →   /ops-preflight slash command
                     → runner/ops-preflight-review.sh
                       Calls codex exec --output-schema for a deep
                       ops-safety review. Writes the verdict to
                       .tdd/ops-preflight/<sha>.json — that artifact
                       is what governed mode reads to unblock
                       destructive commands.
```

### Four new modes (`[ops_triage] mode`)

| Mode | What | When to use |
|---|---|---|
| `off` | Gate disabled. Pack as before v2.2. | Default. Code-review-only adopters. |
| `observe` | Layer 1+2 classify and log; NEVER interrupts. | First week after enabling. Gather classification data on your real workload. |
| `ask` | Layer 1+2 active. Escalation-worthy → operator prompt with reason. L1b denylist → hard-deny. | Daily-use default after observe data looks right. |
| `governed` | Same as ask, PLUS `destructive` verdicts hard-DENY unless a `/ops-preflight` artifact approves. | Unattended/CI sessions. Repos where R3 mistakes are unrecoverable. |

### New artifacts under `.tdd/`

- `.tdd/ops-triage/observe.log` — JSONL classifier verdicts (one per line).
- `.tdd/ops-triage/cache/<sha>.json` — cached classifier verdicts.
- `.tdd/ops-triage/session-tags.txt` — auth/uid/config tags accumulated this session.
- `.tdd/ops-triage/pending-reason.txt` — most recent ask/deny reason (the §9 fallback).
- `.tdd/ops-preflight/<sha>.json` — Codex deep-review verdicts (the governed-mode override artifact).
- `.tdd/ops-debt/<sha>.json` — mutating commands that ran without preflight (the Stop-hook block trigger).

All six are protected by Gate 4 — Claude cannot directly write them; only the runner/hooks may.

### Three new user-editable config files

The only hardcoded surface — pack ships ZERO opinionated commands.
Each ships as `.example`; adopter copies to the non-`.example` name
and edits.

- `config/ops-safe-allowlist.txt` — safe command NAMES (literal,
  one per line). For Layer 1 fast-path.
- `config/ops-catastrophic-denylist.txt` — irreversible PATTERNS
  (extended regex, one per line). For Layer 1b backstop.
- `config/ops-session-tags.txt` — `tag: regex` mappings. For the
  session-tag detector.

### The §9 file-based reason fallback

Bug [#55889](https://github.com/anthropics/claude-code/issues/55889)
(closed not-planned) may suppress `permissionDecisionReason` text on
Bash matchers in the operator UI. Slice 3 ships a fallback: every
ask/deny ALSO writes the reason to `.tdd/ops-triage/pending-reason.txt`.

- If your UI **does** render the JSON reason: you see both.
- If your UI **does not**: `cat .tdd/ops-triage/pending-reason.txt`.

You can run the §8 sentinel test (see proposal §8) to learn which
state your Claude Code version is in, but it's not required — the
fallback works either way.

---

## Enable the ops rail

Default-off. Adopt incrementally:

### Step 1 — Copy + edit the three configs

```bash
cd ~/your-go-project
cp config/ops-safe-allowlist.txt.example          config/ops-safe-allowlist.txt
cp config/ops-catastrophic-denylist.txt.example   config/ops-catastrophic-denylist.txt
cp config/ops-session-tags.txt.example            config/ops-session-tags.txt
```

Open each and trim/extend per the inline guidance:
- The safe allowlist starts narrow (POSIX read-only + git read-only +
  docker/kubectl/helm/terraform read-only). Add commands ONLY after
  observing they fire repeatedly in `observe.log`.
- The catastrophic denylist starts with the obvious irreversibles
  (`rm -rf /`, `terraform destroy --auto-approve`, force-push to
  protected refs, `DROP DATABASE`). Add patterns specific to your
  infra that you know are unrecoverable.
- The session-tags map ships starter patterns for the three default
  tag classes (`auth`, `container_uid`, `config`). Tune to match what
  your operators actually run; do NOT change the tag NAMES (the
  classifier prompt and engine escalation both depend on them).

### Step 2 — Flip the flag in `tdd-pack.toml`

Add the `[ops_triage]` section (or update if you previously had a
stub):

```toml
[ops_triage]
enabled = true
mode = "observe"          # start here for a week
classifier = "haiku"      # haiku (recommended) | codex | none
```

`haiku` needs `ANTHROPIC_API_KEY` set in the env. If you only have
Codex auth, use `classifier = "codex"` (slower, but no extra key) or
`classifier = "none"` (deterministic-only — escalates everything not
on the safe fast-path).

### Step 3 — Register the new Bash hooks in `.claude/settings.json`

Three new hooks to register. **Merge** into your existing
`.claude/settings.json`; do not blind-overwrite (you may have other
hooks from v2.1.x or your own).

Add to `PreToolUse`:

```json
{
  "matcher": "Bash",
  "hooks": [
    { "type": "command",
      "command": "$CLAUDE_PROJECT_DIR/hooks/ops-risk-triage.sh",
      "timeout": 15 }
  ]
}
```

Add to `PostToolUse`:

```json
{
  "matcher": "Bash",
  "hooks": [
    { "type": "command",
      "command": "$CLAUDE_PROJECT_DIR/hooks/ops-debt-track.sh",
      "timeout": 3 },
    { "type": "command",
      "command": "$CLAUDE_PROJECT_DIR/hooks/ops-tag-session.sh",
      "timeout": 3 }
  ]
}
```

Add to `Stop` (alongside any existing Stop hooks):

```json
{ "type": "command",
  "command": "$CLAUDE_PROJECT_DIR/hooks/ops-debt-stop.sh",
  "timeout": 3 }
```

Validate JSON:

```bash
jq empty .claude/settings.json && echo OK
```

### Step 4 — Run for a week in observe mode

`mode = "observe"` never interrupts. The hooks classify and log to
`.tdd/ops-triage/observe.log` (JSONL). After a few days of normal
work, review:

```bash
# What commands are firing the classifier (i.e. NOT fast-pathing Layer 1)?
jq -r 'select(.verdict != "denylist_match") | .command' \
  .tdd/ops-triage/observe.log | sort | uniq -c | sort -rn | head -30

# What would have escalated if you were in ask mode?
jq -r 'select(.would_escalate == "true") | "\(.verdict)\t\(.command)"' \
  .tdd/ops-triage/observe.log | sort | uniq -c | sort -rn | head -20

# Did any catastrophic-denylist pattern fire?
jq -r 'select(.verdict == "denylist_match") | "\(.pattern)\t\(.command)"' \
  .tdd/ops-triage/observe.log | sort | uniq -c | sort -rn
```

Use this data to tune the three configs:
- If a trivially-safe command is hitting Layer 2 too often → add its
  name to the safe allowlist.
- If a genuinely irreversible command fired without a denylist match
  → add its pattern to the denylist.
- If the session-tag detector missed an auth/UID-changing command →
  add a pattern.

### Step 5 — Flip to `ask` mode

```toml
mode = "ask"
```

This is the soft middle layer going live. Escalation-worthy commands
now prompt you with the classifier's reason. The §9 file fallback
(`pending-reason.txt`) is always populated.

When a destructive verdict fires and you want a deeper opinion before
approving, run `/ops-preflight` — Claude reads
`pending-reason.txt`, builds an ops context, calls Codex via
`runner/ops-preflight-review.sh`, and reports the verdict
(approve / approve_with_checks / request_changes / block) with
findings, prechecks, postchecks, and rollback.

### Step 6 (optional) — Flip to `governed` for unattended sessions

```toml
mode = "governed"
```

Same as `ask` for non-destructive escalations. Destructive verdicts
HARD-DENY until you run `/ops-preflight` and Codex approves
(`approve` or `approve_with_checks` → artifact unblocks the command).

Use this for CI, scheduled jobs, or repos where an R3 mistake costs
hours of recovery.

---

## Verify

After step 3 (hooks registered), the offline smokes confirm the
plumbing:

```bash
bash test/smoke-ops-triage-slice1.sh                # 10 checks
bash test/smoke-ops-triage-slice2.sh                # 15 checks
bash test/smoke-ops-triage-slice3.sh                # 16 checks
bash test/smoke-ops-preflight-review.sh             # 14 checks
bash test/smoke-ops-triage-slice5.sh                # 19 checks
bash test/smoke-ops-triage-slice6.sh                # 20 checks
bash test/smoke-schema-strict-mode.sh               # 4 schemas (incl 2 new)
```

Each prints `PASS`. Total wall time under 10s; no Codex calls (smokes
use stub classifiers via `PRILIVE_OPS_TRIAGE_CLASSIFIER_BIN` and
`PRILIVE_OPS_PREFLIGHT_BIN`).

Live end-to-end (one real Codex call, ~30s, requires `codex login` +
`ANTHROPIC_API_KEY`):

```bash
bash test/smoke-v2-mvp.sh
```

---

## Manual end-to-end check

After enabling and flipping to `ask` mode:

1. Open the project in Claude Code.
2. Ask Claude to run a routine container restart:
   `bash -c "docker compose restart app"` (or similar safe-ish infra
   command).
3. You should see an ask prompt with the classifier's reason —
   either rendered in the UI directly, or visible via
   `cat .tdd/ops-triage/pending-reason.txt`.
4. Decide allow/deny.
5. After the command runs (if allowed), inspect:
   ```bash
   ls .tdd/ops-debt/        # if mutating, expect a debt entry
   tail .tdd/ops-triage/observe.log
   ```
6. (Optional) Run `/ops-preflight`. Claude builds context, calls
   Codex, reports verdict, writes `.tdd/ops-preflight/<sha>.json`.
   The debt for that command auto-clears on the next Bash.

---

## Rollback

If something misbehaves:

1. **Kill the rail for the session** — `export PRILIVE_REVIEW_DISABLE=1`.
   Hook exits 0 immediately; pack-as-before behavior.
2. **Disable in config** — set `[ops_triage] enabled = false` in
   `tdd-pack.toml`. The hooks stay registered but no-op.
3. **Hard rollback to v2.1.1** — pull v2.1.1, overwrite the
   `hooks/`, `runner/`, `prompts/`, `schemas/`, `test/` trees; remove
   `config/ops-*.txt*`, `.claude/skills/ops-preflight/`,
   `.claude/commands/ops-preflight.md`; remove the new hook
   registrations from `.claude/settings.json`; remove the
   `[ops_triage]` section from `tdd-pack.toml`. Same shape as the
   v2.0.1 hard rollback in `UPDATE_NOTES_v2.0-to-v2.1.md`.

---

## If something breaks

1. **Read `.tdd/ops-triage/observe.log`** — every classifier
   invocation is logged. `verdict: "classifier_unavailable"` means
   the Haiku call failed (check `ANTHROPIC_API_KEY`).
2. **Read `.tdd/ops-triage/pending-reason.txt`** — most recent
   ask/deny rationale.
3. **Check the cache** — `ls .tdd/ops-triage/cache/`. If you edited
   `config/ops-safe-allowlist.txt` or
   `config/ops-catastrophic-denylist.txt`, the cache key changes and
   old cached verdicts become unreachable (correct behavior). To force
   a re-classification of a specific command, delete the matching
   cache file.
4. **Stop hook stuck in a block loop** — should not happen
   (`stop_hook_active` loop guard is mandatory) but if it does, set
   `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP=1` to escape (default 8). Then
   clear all debt: `rm .tdd/ops-debt/*.json`.
5. **`/ops-preflight` fails** — runner returns exit 1 with a clear
   error to stderr. Common causes: `codex` not on PATH, `codex login`
   expired, malformed reviewer output.

File at https://github.com/prilive-com/go-tdd-pack/issues with the
relevant log excerpt and `.tdd/ops-triage/pending-reason.txt` content.

---

## Open questions for v2.3+

- **§8 ask-visibility data point** — once enough adopters run on
  v2.1.165+ with slice 3 in `ask` mode, we'll learn whether the JSON
  `permissionDecisionReason` actually surfaces on Bash matchers or if
  the §9 file fallback is the only path. The fallback works either
  way, but knowing the truth informs whether the file is still
  needed.
- **Session-tag TTL** — currently append-only within a session, no
  expiry. If stale tags cause false R2→R3 escalations in long-lived
  sessions, v2.3 may add a SessionStart-driven clear or a time-based
  TTL.
- **Cache TTL** — same shape as session-tag TTL above. Current cache
  is keyed by config SHA + command + cwd + env + mode; editing the
  configs auto-invalidates, but cached verdicts never time-expire.

---

## Related

- [`CHANGELOG.md` § 2.2.0](../CHANGELOG.md) — full release notes.
- [`docs/PROPOSAL-ops-risk-triage.md`](PROPOSAL-ops-risk-triage.md) —
  the design doc with verification findings and the §8/§9 risk
  framing.
- [`UPDATE_NOTES_v2.0-to-v2.1.md`](UPDATE_NOTES_v2.0-to-v2.1.md) —
  v2.1 upgrade guide (read first if coming from v2.0.x or v1.9.x).
- [`POSTMORTEM-v2.1.0.md`](POSTMORTEM-v2.1.0.md) — the v2.1.0
  incident; the schema strict-mode lesson + model-pin policy that
  shaped v2.2's smoke discipline.
- [`UPSTREAM_DEPENDENCY_POLICY.md`](UPSTREAM_DEPENDENCY_POLICY.md) —
  why `model = "gpt-5.5"` and `model = "claude-haiku-4-5"` are
  pinned, not floating.
