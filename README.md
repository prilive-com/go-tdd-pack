<div align="center">

# Prilive Go TDD Pack

**Continuous silent peer review between Claude Code and OpenAI Codex CLI for Go projects.**

[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![DCO](https://img.shields.io/badge/DCO-signed--off-brightgreen)](CONTRIBUTING.md)
[![Keep a Changelog](https://img.shields.io/badge/changelog-Keep%20a%20Changelog-orange)](CHANGELOG.md)
<!-- TODO: add CI status badge once GitHub Actions is configured on the public repo -->

**[Quickstart](#quickstart) · [How it works](#how-it-works) · [Install](#install) · [Monorepos](docs/MONOREPO_ADOPTION_GUIDE.md) · [Security](SECURITY.md)**

</div>

---

## The problem

AI coding agents are fast, but prompt-only discipline breaks down. A model can decide that "this change is mechanical, no review needed" — and now the model is deciding whether its own safety process applies. That's not safe.

Prilive Go TDD Pack v2.0 changes the default:

> **Claude does not decide whether Codex review is needed. The runner does.**

The pack runs continuous, silent peer review on every meaningful Go code change. Claude implements; Codex reviews; findings are silently injected into Claude's next turn; Claude addresses them or pushes back. The user only sees finished code, or — when Claude and Codex can't converge — a single A/B/V escalation question.

---

## What's different about this pack

- **Codex runs with the same access as Claude** — full project read, full shell, full network, no sandbox, no copy. The "no project writes" rule lives in Codex's system prompt, verified by a smoke test, not by sandbox flags. Capability parity beats artificial restrictions for review quality.
- **Tool-grounded** — `go vet`, `gofmt`, `staticcheck`, `golangci-lint`, and `govulncheck` run on every cycle. Their output goes verbatim into Codex's prompt so reviews cite tool evidence, not hallucinations.
- **Monorepo-aware** — single-module repos, monorepos with multiple `go.mod` files at any depth, nested modules, polyglot repos, and Go files with no enclosing `go.mod` are all handled by a layout-agnostic affected-module algorithm. Discovery is driven by the diff, not by where the script is invoked from.
- **Multi-round resume** — round 1 uses strict JSON schema; rounds 2+ resume the same Codex session via `codex exec resume`, so the reviewer remembers its prior analysis. Default cap: 5 rounds before escalation.
- **Confidence-scored findings** — every finding includes a 1-5 confidence score so Claude can triage by certainty as well as severity. `[blocker/correctness c=4]` reads differently from `[blocker/correctness c=1]`.
- **Quality-first defaults** — `reasoning_effort = "xhigh"`, full repo tree access via tools, no diff truncation, no cheap-model fallback. Token economy is not a constraint; review depth is.
- **Free with a ChatGPT subscription** — Codex CLI uses your existing ChatGPT Plus/Pro/Team auth. No per-token billing if you're on a subscription.

---

## How it works

```
You ask Claude for a change
  ↓
Claude implements (Edit/Write/MultiEdit)
  ↓
PostToolUse hook fires the runner in background (returns in <50ms)
  ↓
Runner waits 5s for edits to settle (coalesce)
  ↓
Runner runs tool grounding per affected Go module:
  gofmt -l, go vet, staticcheck, golangci-lint, govulncheck
  ↓
Codex round 1 — strict JSON via --output-schema
  ↓
  ├── approve → cycle converged → done (silent)
  └── request_changes
        ↓
        Findings injected into Claude's next turn as additionalContext
        ↓
        Claude fixes silently OR writes a one-line rationale
        ↓
        Stop hook captures Claude's full response
        ↓
        Codex round 2 — resumes session, returns VERDICT: APPROVE | REQUEST_CHANGES
        ↓
        Repeat up to max_rounds (default 5)
        ↓
        If converged → done. If not → A/B/V escalation message to user.
```

The user sees: finished code, or one short escalation question.

The user does NOT see: ceremony markers, plan files, approval prompts, per-edit progress updates.

---

## Requirements

**Required:**
- [Claude Code](https://docs.claude.com/en/docs/claude-code) 2.1.89 or newer
- [OpenAI Codex CLI](https://github.com/openai/codex) — install and authenticate with `codex login`
- Go 1.22 or newer
- Git 2.25 or newer
- `bash` 4+, `jq` 1.6+

**Recommended Go tooling** (the pack degrades gracefully if missing, showing `NOT INSTALLED` in Codex's prompt):
- `staticcheck` — `go install honnef.co/go/tools/cmd/staticcheck@latest`
- `golangci-lint` — see [install guide](https://golangci-lint.run/welcome/install/)
- `govulncheck` — `go install golang.org/x/vuln/cmd/govulncheck@latest`

The pack resolves tools from `PATH` and `$(go env GOPATH)/bin`.

---

## Install

### Clone into an existing Go project

```bash
git clone https://github.com/prilive-com/go-tdd-pack.git /tmp/go-tdd-pack

cp -R /tmp/go-tdd-pack/hooks .
cp -R /tmp/go-tdd-pack/runner .
cp -R /tmp/go-tdd-pack/prompts .
cp -R /tmp/go-tdd-pack/schemas .
cp -R /tmp/go-tdd-pack/test .
cp /tmp/go-tdd-pack/tdd-pack.toml .
cp /tmp/go-tdd-pack/CLAUDE.md .
cp /tmp/go-tdd-pack/AGENTS.md .

# Merge the hook entries from /tmp/go-tdd-pack/.claude/settings.json into
# your project's .claude/settings.json (do NOT blind-overwrite — see
# docs/V2_ROLLOUT_GUIDE.md §2 for the merge procedure).

chmod +x hooks/*.sh runner/*.sh test/smoke-*.sh

# Verify
bash test/smoke-v2-phase2.sh        # 25 unit checks, no Codex calls
bash test/smoke-tool-grounding.sh   # 12 fixture checks
```

That's it. On your next Claude Code session, Codex will start reviewing changes automatically.

Full step-by-step install: [`docs/ADOPTION_GUIDE.md`](docs/ADOPTION_GUIDE.md).
Rollout guide for AI assistants doing the install: [`docs/V2_ROLLOUT_GUIDE.md`](docs/V2_ROLLOUT_GUIDE.md).

---

## Quickstart

Open any Go project where the pack is installed and ask Claude to make a change:

```
Add a Retry function to internal/http/client.go with exponential backoff.
```

Claude writes the code. About 5 seconds after Claude's edits settle, Codex begins reviewing in the background. You won't see this happen — it's silent by design.

If everything converges silently, you'll see finished code. If Claude and Codex disagree across all rounds, you'll see one short message:

```
[REVIEW ESCALATION — cycle <id>]

Claude and Codex did not converge after 5 rounds.
The disagreement is about: <one-sentence summary>

Claude's final view:  <one paragraph>
Codex's final view:   <one paragraph>

Choose how to proceed:
  [A] ship Claude's version — tell me 'go with Claude'
  [B] apply Codex's recommendations — tell me 'go with Codex'
  [V] view full transcripts
```

That's the entire user-facing surface. Everything else is internal.

To see the most recent review at any time, ask Claude "show me the latest review" — it reads `.tdd/reviews/state.json` and the latest cycle directory.

---

## Repository layouts supported

| Layout | Status |
|---|---|
| Single-module Go repo (`go.mod` at root) | ✓ Fully supported |
| Monorepo with multiple `go.mod` files at any depth | ✓ Fully supported (per-module sections) |
| Nested modules (child `go.mod` inside parent module) | ✓ Walked nearest-first |
| Polyglot monorepo (Go + non-Go) | ✓ Only Go-affected modules are tooled |
| Repo with no Go code | ✓ Pack emits "no Go modules touched" status |
| `vendor/`, `testdata/`, `node_modules/` | ✓ Excluded from analysis |
| Empty `go.mod` (Grab-style exclude marker) | ✓ Honored |

Detailed monorepo guide: [`docs/MONOREPO_ADOPTION_GUIDE.md`](docs/MONOREPO_ADOPTION_GUIDE.md).

**Not yet supported** (no plans unless real demand surfaces): Bazel/Buck2/Pants build system orchestration, `go.work` workspace mode toggles, submodule recursion. Native per-module tooling works fine inside Bazel-managed Go repos as long as `go.mod` exists.

---

## Configuration

The pack reads `tdd-pack.toml` from the repo root. Defaults are tuned for quality:

```toml
[review]
max_rounds = 5
coalesce_ms = 5000

[codex]
model = ""                  # empty = use Codex CLI's current default
reasoning_effort = "xhigh"  # max reasoning supported by ChatGPT Plus/Pro/Team
web_search = "live"         # enables Codex web search during review

[severity]
min_surface = "nit"         # Claude sees every finding; can filter on its end
```

Full config reference: [`docs/INTEGRATION_GUIDE.md`](docs/INTEGRATION_GUIDE.md).

**Emergency disable** for the current shell:

```bash
export PRILIVE_REVIEW_DISABLE=1
```

---

## Documentation

| Topic | File |
|---|---|
| Install into a new or existing project | [`docs/ADOPTION_GUIDE.md`](docs/ADOPTION_GUIDE.md) |
| How AI developers should work with v2.0 | [`docs/AI_DEVELOPER_GUIDE.md`](docs/AI_DEVELOPER_GUIDE.md) |
| Hook setup, config reference, state machine | [`docs/INTEGRATION_GUIDE.md`](docs/INTEGRATION_GUIDE.md) |
| Go monorepo specifics | [`docs/MONOREPO_ADOPTION_GUIDE.md`](docs/MONOREPO_ADOPTION_GUIDE.md) |
| Rollout / install instructions for AI assistants | [`docs/V2_ROLLOUT_GUIDE.md`](docs/V2_ROLLOUT_GUIDE.md) |
| v2.0 design spec | [`docs/V2_IMPLEMENTATION_SPEC.md`](docs/V2_IMPLEMENTATION_SPEC.md) |
| Latest update instructions | [`docs/UPDATE_2026-05-17.md`](docs/UPDATE_2026-05-17.md) + [monorepo fix](docs/UPDATE_2026-05-17_monorepo-fix.md) |
| Release history | [`CHANGELOG.md`](CHANGELOG.md) |
| Claude operating rules | [`CLAUDE.md`](CLAUDE.md) |
| Codex operating rules | [`AGENTS.md`](AGENTS.md) |
| Security policy | [`SECURITY.md`](SECURITY.md) |
| Contribution policy | [`CONTRIBUTING.md`](CONTRIBUTING.md) |
| GitHub repo setup scripts (for the maintainer) | [`scripts/github-setup/RUNBOOK.md`](scripts/github-setup/RUNBOOK.md) |

---

## Safety and trust

- **Codex never edits your project files.** The rule is in Codex's system prompt at `prompts/codex-system.md` and verified empirically by smoke tests. Run them any time you upgrade Codex CLI.
- **No sandboxing of Codex.** Codex runs with the same machine access Claude has — your full project, your shell, your network. This is intentional: capability parity beats artificial restrictions for review quality. The "no project writes" rule holds because it's a clear, narrow instruction Codex respects — not because of OS-level enforcement.
- **Emergency switch.** `PRILIVE_REVIEW_DISABLE=1` disables the entire pack for the current shell.
- **No telemetry.** The pack doesn't phone home. Codex invocations go directly from your machine to OpenAI's Codex CLI (which uses your auth, your subscription).

---

## What the gate does NOT cover

The pre-write gate (`PRILIVE_PRE_REVIEW_EXPERIMENTAL=1`) reviews every `Write`, `Edit`, `MultiEdit`, `NotebookEdit`, and `Bash` action **Claude Code is about to take** through its tool API. That covers a lot — but it does not cover everything. Two architectural ceilings to know about:

### Opaque payloads

The reviewer sees the command Claude proposes, not what it runs inside. Examples:

- `python -c '<script>'` — the reviewer sees the `-c` flag, not the Python code's behavior beyond the visible string.
- `node -e '<script>'` — same problem.
- `echo <base64> | base64 -d | sh` — the reviewer sees the encoded blob, not the decoded command.
- `ssh host` — opens an interactive shell on a remote host. **Every command run inside the SSH session is invisible to any Claude-side hook.** Only the `ssh host` invocation itself is reviewed.

The classification prompt treats opaque wrappers as state-changing by default (fail-closed), so they don't slip through as "read-only". But for actual content review, the reviewer is judging only the visible wrapper text.

### Remote-host changes (and any change outside Claude)

The gate is a Claude Code hook. It cannot see:

- Cron jobs running on the host.
- Commands typed by a human in a different terminal.
- Other agents running on the same machine.
- Anything that happens on a server Claude SSHed into.
- Background processes Claude itself spawned earlier in the session (`nohup … &`).

These are not bugs. They are the architectural ceiling of any client-side hook approach.

### What would close them

The two real options if you need to cover these:

1. **Route all shell through one governed executor.** Deny raw `Bash`; force every command through a wrapper script that logs + reviews each `argv[]`. Removes the opaque-payload class. Requires giving up `Bash` flexibility.
2. **OS-level audit / sandbox.** seccomp, eBPF, `auditd`, or a container with a syscall-gated runtime. Closes both classes but is host-level work, not pack-level.

Both are out of scope for this pack. If your threat model needs them, treat the gate as defense in depth — not the only line.

---

## Security

Found a security issue? Please **do not** open a public issue.

- **Preferred:** [Open a private security advisory](https://github.com/prilive-com/go-tdd-pack/security/advisories/new) via GitHub's Private Vulnerability Reporting.
- **Fallback:** Email the address in [`SECURITY.md`](SECURITY.md).

Security-sensitive issue categories include: hook bypass, runner convergence bypass, Codex review artifact tampering, secret leakage through review context, and Codex writing to the real repository (no-write-rule violation).

---

## Contributing

Contributions welcome.

1. Sign off your commits — the project uses [Developer Certificate of Origin](https://developercertificate.org/) via the [cncf/dco2 GitHub App](https://github.com/apps/dco).
2. Read [`CONTRIBUTING.md`](CONTRIBUTING.md) before opening a PR.
3. High-risk changes (hooks, runner state machine, Codex prompts, tool grounding, audit artifacts, config schema, settings.json) require discussion in an issue first.

```bash
git commit -s -m "Your change description"
```

---

## Project status

- **Current public line:** v2.0.x
- **License:** Apache-2.0
- **Maintainer:** Prilive ([github.com/prilive-com](https://github.com/prilive-com))
- **Primary audience:** Go teams using Claude Code and Codex CLI
- **Production usage:** validated on one real Go monorepo as of 2026-05-18
- **Legacy support:** v1.x ceremony architecture is no longer maintained. New adoption should use v2.0.

---

## License

Apache License 2.0 — see [`LICENSE`](LICENSE).

Copyright 2026 Prilive.

---

## Acknowledgements

This pack builds on:

- **Anthropic** — Claude Code platform and plugin ecosystem
- **OpenAI** — Codex CLI
- **`honnef.co/go/tools`** (`staticcheck`) — Go static analyzer
- **`golangci-lint`** — comprehensive linter aggregator
- **`golang.org/x/vuln/cmd/govulncheck`** — Go vulnerability scanner
