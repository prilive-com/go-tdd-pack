# Adoption Guide — Prilive Go TDD Pack v2.0

> **For new adopters.** Step-by-step install and verification path.
> Read once; you should not need to come back after your first review
> cycle runs successfully.

If you're moving from a v1.x ceremony install, just replace the pack
files (this guide also serves as the v1.x→v2.0 cutover). v2.0 does
not read v1.x state.

---

## Step 1 — Prerequisites

```bash
claude --version   # need 2.1.89 or newer
codex --version    # need 0.125 or newer
go version         # need 1.22 or newer
git --version      # need 2.25 or newer
bash --version     # need 4 or newer
jq --version       # need 1.6 or newer
```

If anything is missing:

- **Claude Code:** https://docs.claude.com/en/docs/claude-code
- **Codex CLI:** install per https://github.com/openai/codex, then `codex login`
- **Go:** https://go.dev/dl/
- **bash/jq on macOS:** `brew install bash jq`

Authenticate Codex:

```bash
codex login
```

If you have ChatGPT Plus/Pro/Team, Codex usage is free under your
subscription. Otherwise an OpenAI API key works (per-token billing).

---

## Step 2 — Install recommended Go tooling

The pack's tool grounding works best when these are on PATH. Without
them, the pack degrades gracefully — Codex sees `NOT INSTALLED` in
the prompt and softens related recommendations — but review quality
is lower.

```bash
go install honnef.co/go/tools/cmd/staticcheck@latest
go install golang.org/x/vuln/cmd/govulncheck@latest

# golangci-lint v2 — official install:
curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh \
  | sh -s -- -b $(go env GOPATH)/bin
```

Verify everything is on PATH:

```bash
which staticcheck govulncheck golangci-lint
```

If `not found`, ensure `$(go env GOPATH)/bin` is in `PATH`. On most
shells:

```bash
echo 'export PATH="$HOME/go/bin:$PATH"' >> ~/.bashrc
```

Open a new terminal so the change takes effect.

---

## Step 3 — Install the pack

```bash
git clone https://github.com/prilive-com/go-tdd-pack.git /tmp/go-tdd-pack
cd ~/your-go-project

cp -R /tmp/go-tdd-pack/hooks .
cp -R /tmp/go-tdd-pack/runner .
cp -R /tmp/go-tdd-pack/prompts .
cp -R /tmp/go-tdd-pack/schemas .
cp -R /tmp/go-tdd-pack/test .
cp /tmp/go-tdd-pack/tdd-pack.toml .
cp /tmp/go-tdd-pack/CLAUDE.md .
cp /tmp/go-tdd-pack/AGENTS.md .

chmod +x hooks/*.sh runner/*.sh test/smoke-*.sh
```

Then **merge the hook registration** from
`/tmp/go-tdd-pack/.claude/settings.json` into your project's
`.claude/settings.json`. Do NOT blind-overwrite — your project may
have other hooks. Full merge procedure in
[`V2_ROLLOUT_GUIDE.md`](V2_ROLLOUT_GUIDE.md) §2.

---

## Step 4 — Verify the install

Three smoke tests, in order. Stop and fix at the first failure.

```bash
bash test/smoke-v2-phase2.sh        # ~1s, no Codex calls, 25 checks
bash test/smoke-tool-grounding.sh   # ~2s, no Codex calls, 12 fixture checks
bash test/smoke-v2-mvp.sh           # ~30s, 1 real Codex call
```

Expected results:

- `v2.0 PHASE 2 SMOKE — PASS (25 checks)`
- `TOOL-GROUNDING SMOKE — PASS (12 checks)`
- `v2.0 MVP SMOKE — PASS`

If the first two fail, the install is broken — check that scripts have
executable bits and the hook paths in `.claude/settings.json` are correct.

If the MVP smoke fails on dirty tree, commit or stash your changes
first (it adds an HTML comment to README.md as a fixture and refuses to
run if other changes are present).

---

## Step 5 — Try a real change

Open Claude Code in your project:

```bash
cd ~/your-go-project
claude
```

Ask Claude to make a small change:

```
Add a small Add function in math.go that returns a + b, and a test.
```

Claude writes the code. About 5 seconds after Claude's edits settle,
the pack runs Codex in the background. You won't see anything happen —
that's by design.

If everything works, you'll see one of two outcomes:

- **Silent convergence:** Claude continues, you get the finished
  feature. Codex approved.
- **Escalation:** A short A/B/V message appears if Claude and Codex
  can't converge across all rounds. Pick A, B, or V.

To see the most recent review state at any time, ask Claude
"show me the latest review" — it reads `.tdd/reviews/state.json`
and the latest cycle directory.

---

## Step 6 — Configure (optional)

The default `tdd-pack.toml` is tuned for maximum review quality:

```toml
[review]
max_rounds = 5            # escalate after 5 rounds without convergence
coalesce_ms = 5000        # 5s edit-settle window

[codex]
model = ""                # empty = use Codex CLI's current default
reasoning_effort = "xhigh"
web_search = "live"

[severity]
min_surface = "nit"       # Claude sees every finding

[disable]
env_var = "PRILIVE_REVIEW_DISABLE"
```

Adjust if your priorities differ. Common tweaks:

- `reasoning_effort = "high"` — faster cycles, slightly lower quality
- `web_search = "disabled"` — if your environment forbids egress
- `max_rounds = 3` — quicker escalation when convergence stalls

Full config reference: [`INTEGRATION_GUIDE.md`](INTEGRATION_GUIDE.md).

---

## Step 7 — Monorepo / unusual layouts

If your repo is a monorepo with multiple `go.mod` files at any depth,
nested modules, or polyglot, the pack auto-detects via diff-driven
discovery. You don't need to configure anything — see
[`MONOREPO_ADOPTION_GUIDE.md`](MONOREPO_ADOPTION_GUIDE.md) for details.

---

## Daily workflow

There isn't one. The pack runs automatically on every meaningful Go
edit. Your interaction is:

- Write code with Claude normally.
- If you see an escalation, choose A / B / V.
- If you want to see the latest review, ask Claude "show me the latest
  review".

That's it.

---

## Activating the pre-write gate

The pre-write gate is **off by default**. Turn it on by editing
`tdd-pack.toml`:

```toml
[pre_review]
enabled = true
```

Commit that change and Claude Code in this project gates every
`Write`, `Edit`, `MultiEdit`, `NotebookEdit`, and `Bash` action
through Codex before it runs.

**Activation precedence** (highest first):

1. `PRILIVE_REVIEW_DISABLE=1` in env → gate OFF (global kill switch).
2. `PRILIVE_PRE_REVIEW_EXPERIMENTAL=1` in env → gate ON for this
   shell, regardless of config. Useful for trying the gate in one
   terminal without committing a config change.
3. `[pre_review] enabled = true` in `tdd-pack.toml` → persistent
   project default.
4. Otherwise → gate OFF (advisory PostToolUse review still runs).

---

## Architectural ceiling — what the gate cannot catch

The pre-write gate hooks into Claude Code's `PreToolUse` event for
`Write`, `Edit`, `MultiEdit`, and `NotebookEdit`. Every file-change
action through Claude's tool API goes through the gate. Two scope
boundaries to know about:

### 1. The pack reviews file changes, not commands

v2.1 removed the Bash matcher. Runtime command safety is a separate
concern from code review and out of scope for this pack:

- The starter pack's job is to catch bad code before it lands. The
  reviewer judges proposed file content for correctness, safety, and
  data-loss risk.
- Sending every `pwd` / `ls` / `git status` through Codex was wasteful
  for ChatGPT-subscription users (~6 seconds per call) and an
  architectural mismatch with the pack's mission.
- If you need command-level safety — destructive-command interception,
  data-loss prevention against `rm -rf`, audit of every shell
  invocation — that belongs in a runtime-ops tool, not a TDD pack.
  Consider devopspoint (or a similar sibling plugin) for that
  responsibility.
- Claude Code's own permission system already covers the obviously
  dangerous cases (`sudo`, `kubectl delete`, `rm -rf /`, etc.) at the
  prompt layer, before they ever hit a hook.

### 2. Anything outside Claude's tool API

The gate is a hook **inside Claude Code**. It does not see:

- Cron jobs on the host.
- Commands you (or anyone else) type in a different terminal.
- Other agents running on the same machine.
- Anything that happens on a server Claude SSHed into.
- Background processes Claude itself spawned earlier in the session
  (`nohup … &`, `&` jobs that survive the launching turn).
- File changes from `git pull`, `git checkout`, IDE auto-save, formatter
  hooks fired by your editor, etc.

These are out-of-band changes. Claude Code's hook event never fires
because Claude's tool API was never involved.

### 3. What would close the ceiling

If you need full coverage of file changes across all sources (not just
Claude's tool API), the real option is **OS-level audit / sandbox** —
seccomp filter, eBPF tracepoint, `auditd`, or a container with a
syscall-gated runtime that hooks `execve()` at the kernel boundary.
That closes both the out-of-band class and gives you universal coverage,
but it is host-level work, not pack-level.

Treat this pack as defense in depth — one strong line that covers what
Claude itself does to your code — not the only line.

---

## Emergency switch

```bash
export PRILIVE_REVIEW_DISABLE=1
```

Disables the pack for the current shell. Unset to re-enable.

Use this if Codex auth breaks, you're in the middle of a big refactor
and don't want review yet, or the pack misbehaves.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| No review after edits | Codex CLI not authenticated | `codex login` |
| "NOT INSTALLED" lines in reviews | staticcheck/govulncheck/golangci-lint missing from PATH | See Step 2 |
| Reviews very slow | xhigh reasoning on a large monorepo | Drop `reasoning_effort = "high"` |
| Always escalates | Real disagreement; system working as designed | Use A/B/V to decide |
| "no module-affecting files" on every review | Pack run from above your Go project | Run Claude from inside the project root |
| Stale `.tdd/runner.lock` blocking | Previous runner crashed | `rm -f .tdd/runner.lock` |

---

## What to expect over time

- **First few cycles:** A few escalations as Codex calibrates to your
  code style.
- **Steady state:** Most cycles converge silently. Escalations happen
  on real design disagreements.
- **Long term:** You stop noticing the pack except when it catches a
  real bug before you ship.

---

## Next steps

- Read [`AI_DEVELOPER_GUIDE.md`](AI_DEVELOPER_GUIDE.md) — what your AI
  assistant should know about working under v2.0.
- Skim [`INTEGRATION_GUIDE.md`](INTEGRATION_GUIDE.md) if you want to
  understand the hook/runner mechanics.

---

_Last updated: 2026-05-18 for v2.0._
