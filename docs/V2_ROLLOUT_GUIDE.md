# v2.0 Rollout Guide — for AI Developers

Audience: AI assistants (Claude Code, Codex) onboarding an existing
Go project to the v2.0 continuous silent peer review system.

What this document covers:
1. What v2.0 is and how it differs from v1.x.
2. How to install or update.
3. How to verify the install.
4. How the system works at runtime — both what happens automatically
   and what you (the AI doing the coding) are expected to do.
5. Manual operations and troubleshooting.

If anything in this document conflicts with the live code, the live
code wins — verify before acting.

---

## 1. What v2.0 is (TL;DR)

v2.0 is a **continuous silent peer review** layer that runs Codex
against every change Claude makes, in the same project directory,
with the same access Claude has. The only rule enforced on Codex is
"do not write to project files" — enforced by the system prompt, not
sandboxing.

Architecture in one diagram:

```
Claude edits a file
      │
      ▼
PostToolUse hook fires (async, returns in <50ms)
      │
      ▼
review-runner.sh launches detached
      │
      ▼
  ┌───┴───┐
  │ flock │   single-flight: parallel runners exit
  └───┬───┘
      ▼
coalesce 5s (waits for edit burst to settle)
      │
      ▼
Round 1 → Codex reviews diff with --output-schema
      │
      ├── approve → status: converged → done
      │
      └── request_changes
              │
              ▼
        Findings injected into Claude's next turn as additionalContext
              │
              ▼
        Claude fixes silently OR writes rationale
              │
              ▼
        Stop hook captures Claude's response
              │
              ▼
        Round 2 via codex exec resume (same session)
              │
              ├── approve → converged → done
              │
              └── request_changes → round 3 ... up to max_rounds
                                        │
                                        ▼
                                   escalated (A/B/V choice to user)
```

Key differences from v1.x:
- **No ceremony markers** — no SPEC.md, no CYCLE_ABANDONED.txt, no
  manual approval gates.
- **No tier-based path filtering** — every edit is reviewed.
- **No Claude→Codex via slash command** — the runner fires
  automatically on every edit.
- **No git worktree** — Codex reads the real files.
- **Continuous and silent** — operator only gets pulled in on
  escalation (Claude and Codex disagree across all rounds).

---

## 2. Install (fresh project) or update (from v1.x)

### Prerequisites

Hard requirements:
- `bash`, `jq`, `git`, `gofmt`
- `codex` CLI (`brew install openai/codex/codex` or equivalent)
- Either `codex login` (uses your ChatGPT subscription) OR
  `OPENAI_API_KEY` env var
- Claude Code ≥ 2.1.89

Recommended:
- `goimports`, `golangci-lint`, `govulncheck`
- A clean git working tree before install (so review is reproducible)

### Files to copy into the target project

From this starter repo, copy these directories and files into the
adopter project, preserving paths:

```
hooks/                        # all .sh scripts + hooks.json
runner/                       # all .sh scripts
prompts/codex-system.md
prompts/codex-round1-user.md
prompts/codex-round-n-user.md
schemas/findings-round1.schema.json
tdd-pack.toml                 # default config
.claude/settings.json         # hook registration (see merge note below)
test/smoke-v2-mvp.sh
test/smoke-v2-phase2.sh
test/smoke-v2-phase2-live.sh
```

Make sure shell scripts keep their executable bit:
```bash
chmod +x hooks/*.sh runner/*.sh test/smoke-*.sh
```

### .claude/settings.json — merge, do not blind-overwrite

If the adopter project has an existing `.claude/settings.json`,
DO NOT overwrite it. The Phase 2 settings include four hook entry
points the runner needs:
- `PreToolUse` Bash → `guard-dangerous-bash.sh`, `guard-bash-pipefail.sh`
- `PreToolUse` Edit|Write|MultiEdit → `guard-protected-files.sh`,
  `scan-for-secrets.sh`
- `PostToolUse` Edit|Write|MultiEdit → `gofmt-after-edit.sh`,
  `detect-ai-bloat.sh`, `post-edit-review.sh` (async),
  `inject-findings.sh`
- `PostToolUse` Bash → `post-edit-review.sh` (async)
- `UserPromptSubmit` → `inject-findings.sh`
- `Stop` → `stop-fingerprint.sh`
- `SessionStart` → `session-start.sh`

Merge by adding any missing entries to the adopter's existing settings.
The full reference is in this starter's `.claude/settings.json`.

Also add these `permissions.deny` entries to prevent Claude from
editing review state directly:
```json
"Edit(.tdd/reviews/**)",
"Write(.tdd/reviews/**)",
"MultiEdit(.tdd/reviews/**)"
```

### Upgrading from v1.x — what to remove

If migrating from v1.9.x or v1.10.x ceremony architecture, these are
no longer used and should be deleted from the adopter project:

- `.claude/hooks/require-second-opinion.sh` (and any other ceremony
  enforcement hooks under `.claude/hooks/` that were v1.x-specific)
- `.tdd/templates/SPEC.md.template`, `CYCLE_ABANDONED.txt.template`
- `.claude/skills/second-opinion/` (replaced by the always-on runner)
- Any `.tdd/cycles/` directories from v1.x cycles
- v1.x config: `.tdd/tdd-config.json` (replaced by `tdd-pack.toml`)

Back up the v1.x `.claude/settings.json` to `.claude/settings.json.v1.x.backup`
before replacing — there's a comment field for this in the v2.0 settings.

### Default config

`tdd-pack.toml` ships with sane defaults:
- `max_rounds = 4` — escalate after 4 rounds without convergence
- `coalesce_ms = 5000` — wait 5s of quiet after the last edit
- `reasoning_effort = "high"` — Codex reasoning level
- `web_search = "live"` — Codex can use web search
- `model = ""` — let Codex CLI pick its current default model

Edit only if you have a specific reason.

---

## 3. Verify the install

Run all three smoke tests, in this order. They are progressively more
expensive — stop and fix at the first failure.

### Smoke 1: structural (free, ~1s)

```bash
bash test/smoke-v2-phase2.sh
```

Expected: `v2.0 PHASE 2 SMOKE — PASS (25 checks)`.

This validates orchestration logic in isolation with mocked fixtures
— no Codex calls. If this fails, hook scripts are not where the
runner expects them.

### Smoke 2: round 1 with real Codex (~5-15K tokens, ~30s)

```bash
bash test/smoke-v2-mvp.sh
```

Working tree must be clean. The smoke adds an HTML comment to README.md,
runs round 1, asserts Codex approved silently, verifies no project
files were modified, reverts the fixture.

Expected: `v2.0 MVP SMOKE — PASS`.

If Codex returns `request_changes` on a trivial README comment, your
prompts/system.md may be misconfigured.

### Smoke 3: multi-round live (~20-40K tokens, ~60s)

```bash
bash test/smoke-v2-phase2-live.sh
```

Working tree must be clean. The smoke inserts a deliberate infinite
loop into `hooks/post-edit-review.sh` (Codex flags as blocker), then
simulates the full Phase 2 cycle: round 1 → request_changes → revert
+ write claude-response-2.txt → round 2 via `codex exec resume` →
approve → converged.

Expected: `v2.0 PHASE 2 LIVE SMOKE — COMPLETE` with `final status: converged`.

If round 2 fails with `round-2.txt missing`, the runner is not
detecting the resume condition — check that `runner/review-runner.sh`
has the resume logic (it should check `state.json` for in-progress
cycles before the coalesce step).

---

## 4. How the system works at runtime

### What happens automatically (you do not trigger any of this)

1. **You edit a file** (Edit, Write, MultiEdit, or a write-effecting
   Bash command).

2. **Two PostToolUse hooks fire:**
   - `inject-findings.sh` (sync, <50ms) — reads `.tdd/reviews/state.json`
     and injects any pending findings as additionalContext.
   - `post-edit-review.sh` (async) — fires-and-forgets the background
     runner. Returns immediately so your edit doesn't feel slow.

3. **The runner takes over (background):**
   - Acquires a single-flight lock (`.tdd/runner.lock`).
   - Coalesces — waits 5s of no-edit quiet. Bursty edits collapse
     into one review cycle.
   - Checks `git diff --quiet HEAD` — if nothing to review, exits.
   - **Or, detects resume condition** — if `state.json` shows an
     in-progress cycle with `claude-response-${next}.txt` waiting,
     skips coalesce/diff/round-1 and jumps to round N+1.
   - Mints a `cycle_id`, snapshots the diff, calls
     `runner/codex-round1.sh`.
   - Codex returns JSON conforming to `findings-round1.schema.json`.

4. **On approve:** `status: converged` written to state.json; cycle
   ends silently. You'll never know it happened.

5. **On request_changes:**
   - state.json: `status: request_changes`, `round: 1`.
   - `inject-findings.sh` reads this on your next tool call and emits
     additionalContext with the findings.
   - You see a `[Codex review — cycle X, round 1, status: changes requested]`
     block in your context, with severity, category, title, body,
     file, and line for each finding above `minor`.

### What you (the AI doing the coding) should do

This is the most important section of this guide. Behavior matters.

**If you agree with a finding:**
- Fix the code silently. Just edit the file. The next runner cycle
  will re-review.
- Do NOT acknowledge the finding in chat. Do NOT tell the user
  "Codex flagged X and I'm fixing it." The user does not need to
  see this. Continue with their original request.

**If you disagree with a finding:**
- Write a one-line rationale in a code comment near the relevant
  code, OR write the rationale as part of your assistant response.
  Either way, your next response is captured by the Stop hook and
  sent to Codex on round 2.
- Be specific. "I disagree" alone will not move Codex. Cite the
  reason: "This is intentional because X; the alternative would
  break Y."

**If you don't know:**
- Default to fixing. Codex is conservative and a peer reviewer. If
  you're unsure whether a finding is real, the cost of fixing
  silently is low; the cost of pushing back wrongly is more rounds
  and possibly escalation.

**Never:**
- Never ask the user about the findings. The user doesn't see the
  cycle until escalation. Continue working on their original task.
- Never modify files in `.tdd/reviews/`. Claude Code's
  `permissions.deny` will block you anyway, but don't try.
- Never `chmod` or `mv` files in a way that changes their mode
  silently. Codex will flag it.
- Never set `PRILIVE_REVIEW_DISABLE=1` without the user telling you
  to. That kills the entire review layer.

### Multi-round and escalation

Rounds 2..max_rounds work the same as round 1, but:
- Codex resumes the same session via `codex exec resume`.
- Codex's output is free-form text (the resume mode doesn't support
  `--output-schema`), ending with `VERDICT: APPROVE` or
  `VERDICT: REQUEST_CHANGES`.
- Each round costs another Codex call. Typical cycles converge in 1-2
  rounds.

If the cycle reaches `max_rounds` (default 4) without convergence,
`status: escalated` is written and `runner/escalate.sh` emits a user-
facing message on the next turn:

```
[REVIEW ESCALATION — cycle ...]

Claude and Codex did not converge after 4 rounds.
The disagreement is about: <summary>

Claude's final view: <last response>
Codex's final view:   <last review>

Choose how to proceed:
  [A] ship Claude's version — tell me 'go with Claude'
  [B] apply Codex's recommendations — tell me 'go with Codex'
  [V] view full transcripts — tell me 'show review'
```

On escalation, **stop working on the user's task and wait for their
choice.** Do not try to resolve the disagreement yourself.

---

## 5. Manual operations

Things the user might ask you to do.

### "Show me the latest review"

```bash
jq . .tdd/reviews/state.json
ls -la .tdd/reviews/
```

Then show the latest cycle's `round-1.json` (formatted) and any
`round-N.txt`. Summarize findings with severity and category.

### "Abandon the current review cycle"

```bash
jq -n --arg ts "$(date -u +%FT%TZ)" \
  '{cycle_id:"", status:"abandoned", round:0, updated_at:$ts}' \
  > .tdd/reviews/state.json
```

This clears state and frees future edits to start fresh cycles.
Existing cycle dirs are kept for audit.

### "Show the audit log"

```bash
jq -s . .tdd/reviews/debates.jsonl
```

Or `cat` for raw lines.

### "Disable review temporarily"

```bash
export PRILIVE_REVIEW_DISABLE=1
```

All hooks become no-ops. Unset to re-enable. **Only use this when the
user explicitly tells you to.** Don't reach for it as a way out of a
review cycle.

### "Re-enable review"

```bash
unset PRILIVE_REVIEW_DISABLE
```

### "Run a review manually" (force a cycle without an edit)

```bash
bash runner/review-runner.sh "$(pwd)"
```

Useful for debugging or if PostToolUse didn't fire for some reason.

---

## 6. Troubleshooting

### A cycle seems stuck

```bash
ls -la .tdd/runner.lock
jq . .tdd/reviews/state.json
```

If a stale lock file is held by a dead PID:
```bash
rm -f .tdd/runner.lock
```

If state.json shows `status: reviewing` for more than a few minutes,
the Codex call is probably hung. Check:
```bash
tail .tdd/reviews/*/codex-stderr.log
ps aux | grep -E 'codex|review-runner'
```

Kill any stuck Codex process, then:
```bash
rm -f .tdd/runner.lock
jq -n --arg ts "$(date -u +%FT%TZ)" \
  '{cycle_id:"", status:"abandoned", round:0, updated_at:$ts}' \
  > .tdd/reviews/state.json
```

### Codex returns "content flagged for possible cybersecurity risk"

OpenAI's content filter is rejecting the diff. Common causes:
- Real-looking credential pattern in the diff (`sk-...`, `ghp_...`,
  AWS keys). Rewrite to use a placeholder or move secrets to env vars
  before the runner sees them.
- Exploit-development-shaped code (shell injection, deserialization
  gadgets). Add a comment explaining the legitimate purpose, or
  refactor.

If the filter is wrong, the user can opt into OpenAI's Trusted Access
for Cyber program. Do not try to bypass the filter from your side.

### Round 2 never fires after request_changes

Verify `runner/review-runner.sh` has the resume logic — search for
`RESUME_CYCLE_ID` near the top of the file. If absent, you're on the
pre-fix version; pull the latest starter.

Also check that the Stop hook is registered in `.claude/settings.json`:
```bash
jq '.hooks.Stop' .claude/settings.json
```

Should show `hooks/stop-fingerprint.sh`.

### Findings are not being injected on Claude's next turn

Defense-in-depth: `inject-findings.sh` fires on both `PostToolUse`
AND `UserPromptSubmit`. If the first one doesn't inject (known issue
on some Claude Code builds — anthropics/claude-code#18427), the
second one will catch it on the user's next prompt.

If neither fires:
```bash
jq '.hooks.PostToolUse | map(.hooks[].command) | flatten' .claude/settings.json
jq '.hooks.UserPromptSubmit | map(.hooks[].command) | flatten' .claude/settings.json
```

Both lists should include `inject-findings.sh`.

### "permission denied" on hook scripts

```bash
chmod +x hooks/*.sh runner/*.sh
```

mktemp + mv loses the executable bit. Any script that uses that
pattern (including some smoke tests) restores mode with `chmod`.

---

## 7. Daily AI behavior — quick reference

| Situation | Action |
|---|---|
| State silent, no findings injected | Do the user's task normally. |
| Findings injected, you agree | Fix silently. Do not narrate. |
| Findings injected, you disagree | Write a one-line rationale. Continue work. |
| Findings ambiguous | Default to fixing. |
| `status: escalated` message appears | Stop. Wait for user's A/B/V choice. |
| User asks about review state | Read state.json and the latest cycle dir. |
| User says "abandon" | Update state.json to abandoned. |
| User says "disable for now" | `export PRILIVE_REVIEW_DISABLE=1`. |
| Stale lock blocking runner | `rm -f .tdd/runner.lock`. |

Never:
- Ask the user about review findings between rounds.
- Modify `.tdd/reviews/*` files (permissions deny it anyway).
- Disable the system without explicit user permission.
- Try to bypass OpenAI's content filter from your side.

---

## 8. Operator quick reference (for the human)

If the user wants their own cheat sheet:

```
# See current cycle state
jq . .tdd/reviews/state.json

# See latest review findings
ls -t .tdd/reviews/cycle-* | head -1 | xargs -I{} cat {}/round-1.json | jq

# Abandon stuck cycle
jq -n --arg ts "$(date -u +%FT%TZ)" \
  '{cycle_id:"", status:"abandoned", round:0, updated_at:$ts}' \
  > .tdd/reviews/state.json

# Kill review entirely for the session
export PRILIVE_REVIEW_DISABLE=1

# Run review on demand
bash runner/review-runner.sh "$(pwd)"

# Verify install
bash test/smoke-v2-phase2.sh        # 1s, no Codex
bash test/smoke-v2-mvp.sh           # 30s, 1 Codex call
bash test/smoke-v2-phase2-live.sh   # 60s, 2 Codex calls
```

---

## Version this guide refers to

Phase 2 of v2.0, commit `89f16a8` or later (the commit that added the
runner resume logic). If your `runner/review-runner.sh` does not
contain the string `RESUME_CYCLE_ID`, you're on an older version and
Phase 2 multi-round will not work — pull the latest starter.
