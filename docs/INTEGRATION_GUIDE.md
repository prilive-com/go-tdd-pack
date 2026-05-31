# Integration Guide — Prilive Go TDD Pack v2.0

> **Audience:** Adopters who want to understand or customize the
> integration between Claude Code, Codex CLI, and the pack's
> hooks/runner.
>
> If you just want to install and use the pack, read
> [`ADOPTION_GUIDE.md`](ADOPTION_GUIDE.md) first. This is the deep dive.

---

## Architecture overview

```
┌─────────────────────────────────────────────────────────────────┐
│ Claude Code session                                              │
│                                                                  │
│   User prompt                                                    │
│      ↓                                                           │
│   Claude (you) writes/edits Go file                              │
│      ↓                                                           │
│   PostToolUse hook fires:                                        │
│     hooks/post-edit-review.sh  (async, returns in <50ms)         │
│       ↓                                                          │
│       └─→ runner/review-runner.sh (background, detached)         │
│            ↓                                                     │
│            single-flight flock (.tdd/runner.lock)                │
│            ↓                                                     │
│            coalesce.sh  (waits 5s for edits to settle)           │
│            ↓                                                     │
│            check state.json — resume in-progress cycle?          │
│            ↓ (no resume)                                         │
│            git diff --quiet HEAD — anything to review?           │
│            ↓                                                     │
│            runner/tool-grounding.sh                              │
│              (gofmt, go vet, staticcheck, golangci-lint,         │
│               govulncheck — per affected Go module)              │
│            ↓                                                     │
│            codex-round1.sh                                       │
│              (codex exec --output-schema → round-1.json)         │
│            ↓                                                     │
│            on request_changes: state.json updated, runner exits  │
│            ↓                                                     │
│            (next runner invocation, via Stop hook below)         │
│            codex-round-n.sh (rounds 2+)                          │
│              (codex exec resume → VERDICT: APPROVE|REQUEST_CHANGES│
│            ↓                                                     │
│            convergence (silent) or escalation (A/B/V message)    │
│                                                                  │
│   inject-findings.sh runs on PostToolUse and UserPromptSubmit:   │
│     reads .tdd/reviews/state.json                                │
│     emits additionalContext if findings pending                  │
│       ↓                                                          │
│   Claude reads findings in next system reminder                  │
│   Claude addresses findings; Stop hook captures the response     │
│   Stop hook fires runner again for next round                    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Hook setup

The pack registers four PostToolUse hooks plus Stop and SessionStart
via `.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [
          { "type": "command", "command": "$CLAUDE_PROJECT_DIR/hooks/post-edit-review.sh", "async": true, "timeout": 5 },
          { "type": "command", "command": "$CLAUDE_PROJECT_DIR/hooks/inject-findings.sh", "timeout": 3 }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "$CLAUDE_PROJECT_DIR/hooks/post-edit-review.sh", "async": true, "timeout": 5 }
        ]
      }
    ],
    "UserPromptSubmit": [
      { "hooks": [
        { "type": "command", "command": "$CLAUDE_PROJECT_DIR/hooks/inject-findings.sh", "timeout": 3 }
      ]}
    ],
    "Stop": [
      { "hooks": [
        { "type": "command", "command": "$CLAUDE_PROJECT_DIR/hooks/stop-fingerprint.sh", "timeout": 5 }
      ]}
    ],
    "SessionStart": [
      { "hooks": [
        { "type": "command", "command": "$CLAUDE_PROJECT_DIR/hooks/session-start.sh", "timeout": 3 }
      ]}
    ]
  }
}
```

### Hook responsibilities

| Hook | Trigger | Job |
|---|---|---|
| `post-edit-review.sh` | PostToolUse (Edit/Write/MultiEdit/Bash) | Fire-and-forget background runner. Returns in <50ms. |
| `inject-findings.sh` | PostToolUse + UserPromptSubmit | Read state.json; emit additionalContext if findings pending. |
| `stop-fingerprint.sh` | Stop | Capture Claude's last response, re-fire runner for next round, fingerprint-check for missed edits. |
| `session-start.sh` | SessionStart | On resume, notify about paused cycles. |

---

## Codex CLI invocation

Round 1 uses `codex exec` with strict schema:

```bash
codex exec \
  --dangerously-bypass-approvals-and-sandbox \
  -c 'web_search="live"' \
  -c 'model_reasoning_effort="xhigh"' \
  --output-schema schemas/findings-round1.schema.json \
  -o .tdd/reviews/<cycle>/round-1.json \
  --skip-git-repo-check \
  --cd "$PROJECT_DIR" \
  <prompt>
```

Rounds 2+ resume the same session:

```bash
codex exec resume <session-id> \
  --dangerously-bypass-approvals-and-sandbox \
  -c 'web_search="live"' \
  <prompt>
```

**Important flag notes** (gotchas verified during build):

- `--dangerously-bypass-approvals-and-sandbox` is a **subcommand** flag.
  `--ask-for-approval` and `--search` (top-level only) won't work on
  `codex exec`. Use `-c web_search="live"` instead of `--search`.
- `--output-schema` and `-o` are **silently ignored** on `codex exec resume`
  (openai/codex#14343, #12538). Rounds 2+ parse free-form text via
  `runner/extract-verdict.sh` for `VERDICT: APPROVE | REQUEST_CHANGES`.

### Why no sandbox

User requirement: Codex must have capability parity with Claude. The
"no project writes" rule lives in `prompts/codex-system.md` and is
verified by smoke tests (`test/smoke-v2-mvp.sh` and
`test/smoke-v2-phase2-live.sh` both hash-check all project files
before and after each cycle).

---

## Configuration reference

The pack reads `tdd-pack.toml` from the user's repo root. Defaults:

```toml
[review]
# Maximum debate rounds before escalating to the user.
# Min 2, max 8. Quality-tuned default 5.
max_rounds = 5

# Wait this long after the last edit before firing review (milliseconds).
coalesce_ms = 5000

# Also fire the runner when the Stop hook sees the working tree changed
# since the last review (belt-and-suspenders).
stop_hook_fingerprint = true

# Declared but not enforced — informational only.
max_codex_calls_per_cycle = 8
max_cycle_minutes = 30

[codex]
# Empty = use Codex CLI's current default model.
model = ""

# Reasoning effort: low | medium | high | xhigh
# xhigh is supported by ChatGPT Plus/Pro/Team auth.
reasoning_effort = "xhigh"

# "live" enables web search; "disabled" omits.
web_search = "live"

[tdd]
# "criterion" = Codex flags missing tests as findings (non-blocking)
# "off"       = TDD is not checked
enforce_as = "criterion"

[severity]
# Minimum severity surfaced to Claude. Set to "nit" to show everything.
min_surface = "nit"

# Severity at which a finding becomes "must address" for convergence.
must_address = "major"

[gate]
# OPT-IN git hooks (not auto-installed).
git_pre_commit = false
git_pre_push = false

[audit]
debates_jsonl = ".tdd/reviews/debates.jsonl"
keep_transcripts = true

[disable]
env_var = "PRILIVE_REVIEW_DISABLE"
```

---

## Environment variables

| Variable | Purpose | Default |
|---|---|---|
| `PRILIVE_REVIEW_DISABLE` | `1` = disable pack for current shell | unset |
| `CLAUDE_PROJECT_DIR` | Project root (set by Claude Code) | working dir |
| `TOOL_GROUNDING_TIMEOUT_S` | Per-tool timeout in tool-grounding.sh | 60 |
| `TOOL_GROUNDING_CHAR_CAP` | Per-tool output cap in bytes | 4000 |
| `TOOL_GROUNDING_TOTAL_CAP` | Total tool-grounding output cap | 30000 |

The pack does **not** read `PRILIVE_BASE_REF`, `PRILIVE_WORKSPACE_MODE`,
`PRILIVE_BUILD_SYSTEM`, `PRILIVE_FOLLOW_SUBMODULES`, or
`PRILIVE_COMMIT_GATE` — those appear in some consultant docs but are
not implemented in this version.

---

## State files

The pack writes to `.tdd/` under your repo root:

```
.tdd/
├── .last-edit                       # mtime touched on every edit (coalesce)
├── .last-fingerprint                # working-tree hash for Stop-hook fingerprint check
├── runner.lock                      # flock for single-flight runner
└── reviews/
    ├── state.json                   # current cycle pointer (status, round, cycle_id)
    ├── debates.jsonl                # append-only audit log
    └── <cycle_id>/
        ├── diff.patch               # diff under review
        ├── round-1.json             # schema-valid round-1 findings
        ├── round-2.txt              # free-form round-2 output
        ├── round-N.txt              # rounds 3..max
        ├── claude-response-2.txt    # captured Claude response between rounds
        ├── claude-response-N.txt
        ├── codex-session-id         # Codex thread id for resume
        └── codex-stderr.log         # stderr from codex invocations
```

`.tdd/` is the pack's bookkeeping. The "no project writes" rule for
Codex explicitly allows writes here. Claude is denied write access to
`.tdd/reviews/**` via `permissions.deny` in `.claude/settings.json`.

---

## State machine

```
              ┌──────────┐
              │   idle   │ ◄────────────────┐
              └────┬─────┘                  │
                   │ user edits             │
                   ▼                        │
              ┌──────────┐                  │
              │ reviewing│ (round 1)        │
              └────┬─────┘                  │
                   │                        │
        ┌──────────┴──────────┐             │
        ▼                     ▼             │
   verdict=approve    verdict=request_changes
        │                     │             │
        ▼                     ▼             │
   ┌──────────┐         ┌─────────────────┐ │
   │converged │         │request_changes  │ │
   └────┬─────┘         │(waiting for     │ │
        │               │ Claude response)│ │
        │               └────┬────────────┘ │
        │                    │              │
        │                    │ Stop hook captures response
        │                    │ → runner re-fires
        │                    ▼              │
        │               (back to reviewing) │
        │                                   │
        └───────────────────────────────────┘

   Terminal states:
     converged   — runner approved silently
     failed      — codex crashed or returned invalid output
     escalated   — max_rounds reached without convergence
     abandoned   — operator marked cycle abandoned
```

---

## Smoke tests

The pack ships three smoke suites:

```bash
# Structural — no Codex calls, ~1-2s, 25 + 12 checks
bash test/smoke-v2-phase2.sh
bash test/smoke-tool-grounding.sh

# Round 1 with real Codex — ~30s, ~5-15K tokens
bash test/smoke-v2-mvp.sh

# Multi-round live — ~60s, ~20-40K tokens, exercises Phase 2 end-to-end
bash test/smoke-v2-phase2-live.sh

# Escalation path (opt-in, more expensive)
SMOKE_PHASE2_ESCALATE=1 bash test/smoke-v2-phase2-live.sh
```

Run **structural smokes** on every change, **MVP smoke** on every
runner orchestration change, **live multi-round** on changes to the
Phase 2 resume logic, and **escalation** before each release.

---

## CI/CD compatibility

The pack is interactive-first. CI integration is not built in but is
possible by invoking the runner directly:

```yaml
- name: Generate tool grounding
  run: bash runner/tool-grounding.sh > grounding.md
```

You'd then need to script the Codex invocation yourself; the runner
currently expects a Claude Code session for the Stop-hook capture
mechanism that drives rounds 2+. CI use is best treated as a future
feature, not a current one.

---

## Common customizations

### Tune for speed instead of quality

```toml
[codex]
reasoning_effort = "high"     # was xhigh
web_search = "disabled"

[review]
max_rounds = 3
```

### Pin a specific Codex model

```toml
[codex]
model = "gpt-5-codex"   # or any specific version
```

Otherwise leave empty to track Codex CLI's current default.

### Quieter findings

```toml
[severity]
min_surface = "minor"   # drops nits from Claude's context
```

### Disable a specific tool

The pack auto-skips tools that aren't installed. If you want a tool not
to run even when installed, uninstall it from your project's PATH or
relocate it outside the Go bin path.

---

## Coverage boundaries — what the pack does and does NOT review

The runner is **opportunistic**: it only sees changes that go through
Claude Code's tool surface. Specifically, the PostToolUse hooks fire
on `Edit`, `Write`, `MultiEdit`, and `Bash` tool invocations.

That means **edits made outside Claude Code escape review entirely**.
Concrete examples:

| Action | Reviewed? |
|---|---|
| Claude calls `Edit` to change a file | ✓ Yes |
| Claude calls `Bash` running `sed -i '...' file.go` | ✓ Yes (Bash PostToolUse fires) |
| You manually run `vim file.go` in your terminal | ✗ No (no Claude Code tool involved) |
| You run `sed -i '...' file.go` from your own shell | ✗ No |
| You use your editor's GUI to save changes | ✗ No |
| Another git hook (pre-commit) modifies files | ✗ No |
| A Makefile target rewrites files | ✗ No |

This is intentional design — the pack is a **Claude Code companion**,
not a file-system watcher. The Stop hook's fingerprint check
(`hooks/stop-fingerprint.sh`) catches some of this by detecting working-
tree drift between Claude turns, but it's belt-and-suspenders, not
comprehensive coverage.

**If you need every change reviewed regardless of source**, layer a
pre-commit git hook in addition to this pack. The pack itself
intentionally does not install pre-commit hooks (see `tdd-pack.toml`
`[gate]` for opt-in shell hooks if you want them).

The runner also has a few specific failure modes worth knowing:

- **No git repository:** the pack is diff-driven (uses `git diff HEAD`).
  In a non-git directory the runner exits cleanly with a message to
  stderr explaining the situation. Either `git init` your project or
  set `PRILIVE_REVIEW_DISABLE=1`.
- **Codex auth expiry:** if your ChatGPT subscription's auth token
  expires mid-session, Codex returns 401 and the runner records the
  cycle as `failed`. The `inject-findings.sh` hook surfaces this once
  per failed cycle with a hint to run `codex login`. The runner is
  fail-open — your edits continue; subsequent cycles will work once
  you re-authenticate.
- **Runner output / debugging:** the runner's stdout+stderr are
  appended to `.tdd/runner.log`. Tail this to see what Codex actually
  printed when things look wrong.

---

## Debugging

If something isn't working:

1. **Is `PRILIVE_REVIEW_DISABLE` set?** `echo $PRILIVE_REVIEW_DISABLE`
   — must be empty or `0`.
2. **Is Codex authenticated?** Run `codex login` and check
   `~/.codex/auth.json` exists.
3. **Are hooks registered?** `jq '.hooks' .claude/settings.json`
   should show the entries above.
4. **Is the runner being invoked?** Make an edit, then check
   `ls -la .tdd/reviews/` — should show a new cycle dir.
5. **Does Codex run?** Inspect the cycle's `round-1.json` — should be
   non-empty JSON. If empty, check `codex-stderr.log` in the same dir.
6. **Are findings being injected?** Check `.tdd/reviews/state.json`
   — `"status": "request_changes"` means findings exist.

To clear stale state:

```bash
rm -f .tdd/runner.lock
jq -n --arg ts "$(date -u +%FT%TZ)" \
  '{cycle_id:"", status:"abandoned", round:0, updated_at:$ts}' \
  > .tdd/reviews/state.json
```

---

## Further reading

- [`ADOPTION_GUIDE.md`](ADOPTION_GUIDE.md) — install and verify
- [`AI_DEVELOPER_GUIDE.md`](AI_DEVELOPER_GUIDE.md) — for AI assistants
- [`MONOREPO_ADOPTION_GUIDE.md`](MONOREPO_ADOPTION_GUIDE.md) — monorepo specifics
- [`V2_IMPLEMENTATION_SPEC.md`](V2_IMPLEMENTATION_SPEC.md) — full design spec
- [`V2_ROLLOUT_GUIDE.md`](V2_ROLLOUT_GUIDE.md) — install instructions for AI assistants

---

_Last updated: 2026-05-18 for v2.0._
