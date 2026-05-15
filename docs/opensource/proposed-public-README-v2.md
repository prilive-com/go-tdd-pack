<!--
PUBLIC README — go-claude-forge — VERSION 2 (final synthesis)
==============================================================

Supersedes: proposed-public-README.md
Synthesizes:
  • Verified content from the existing CLAUDE.md, README.md, MAINTAINING.md (counts,
    Mode A/B, six defense layers, Makefile targets, MAINTAINING note about
    starter-pack-not-plugin)
  • Anthropic's documented marketplace layout (plugins/<name>/ subdirectory)
  • Verified prior-art citations (nizos/tdd-guard 2.1k★, hamelsmu/claude-review-loop
    663★, openai/codex-plugin-cc 18.8k★)
  • Honest competitive positioning vs openai/codex-plugin-cc
  • Real script paths (scripts/doctor.sh not scripts/tdd/doctor.sh)
  • Real config keys (tier1_path_regexes, enforcement_mode: strict|warn|off,
    second_opinion.no_discretion.*)
  • Real version (v1.9.6, includes legacy-hook defer + dogfood mode)

Final naming (locked, no more pivots):
  GitHub org:           prilive-com
  Repo:                 go-claude-forge
  Plugin name:          go-claude-forge
  Marketplace name:     prilive-com
  Install:              /plugin marketplace add prilive-com/go-claude-forge
                        /plugin install go-claude-forge@prilive-com
  Plugin commands:      /go-claude-forge:<name>

Placeholders still to resolve before publishing:
  BADGE-ID         OpenSSF Best Practices project ID (apply at bestpractices.dev)
  YEAR             current year in citation block
  conduct@         real contact email for Code of Conduct enforcement
  security@        real contact email for SECURITY.md (PVR is primary; email is fallback)
  co-maintainer    real co-maintainer (≥2 required for credible CoC enforcement)
-->

<div align="center">

# go-claude-forge

**Governance scaffolding for AI-assisted Go development with Claude Code.**

*Move discipline from prompts to hooks the AI cannot route around.*

[![CI](https://github.com/prilive-com/go-claude-forge/actions/workflows/ci.yml/badge.svg)](https://github.com/prilive-com/go-claude-forge/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/prilive-com/go-claude-forge?sort=semver)](https://github.com/prilive-com/go-claude-forge/releases)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/prilive-com/go-claude-forge/badge)](https://scorecard.dev/viewer/?uri=github.com/prilive-com/go-claude-forge)
[![SLSA Level 3](https://slsa.dev/images/gh-badge-level3.svg)](https://slsa.dev)
[![Keep a Changelog](https://img.shields.io/badge/changelog-Keep%20a%20Changelog-orange)](CHANGELOG.md)

**[Quickstart](#quickstart) · [How it works](#how-it-works) · [Configuration](#configuration) · [Worked example](#worked-example) · [Docs](docs/)**

</div>

---

## The problem

AI coding agents move fast — and rationalize unsafe shortcuts when tired:

> *"This change is small."*
> *"This is only Tier 2."*
> *"This is just a test."*
> *"The previous review is fresh enough."*
> *"I will run /second-opinion before commit."*

You can read the transcript and watch it happen. You add a rule to `CLAUDE.md` ("always run /second-opinion before commit"). The agent honors it for a while. Then it adjudicates its own diff as "mechanical enough to skip" and moves on. The discipline lives in the prompt; the bypass lives in the model.

**Prompts can't hold a rule the model is allowed to interpret.**

## What this is

`go-claude-forge` is a layered governance scaffold for Go projects that use Claude Code. It moves discipline from prompts into **hooks that fail closed** when their preconditions aren't met.

```text
Prompt discipline says:
  "Claude should remember to do the right thing."

go-claude-forge says:
  "Claude cannot proceed unless the required proof exists."
```

The inviolable rule, enforced by `disable-model-invocation: true` on the `/second-opinion` skill itself:

> **The AI does not decide whether `/second-opinion` is required. The hooks decide.**

The model literally cannot invoke `Skill(second-opinion)` to rationalize its own work. Only the runner script can call Codex, and only when an open obligation matches a known scope.

## Position vs. related work

Cross-model review (Claude + Codex) is also available via OpenAI's official [`codex-plugin-cc`](https://github.com/openai/codex-plugin-cc). Pure TDD enforcement is available via [`nizos/tdd-guard`](https://github.com/nizos/tdd-guard).

This pack differs by adding **deterministic governance** on top of both:

- `/second-opinion` is **invoke-only** — the model cannot call it to clear its own diff.
- The runner is the **single legitimate Codex caller**, and only when a hook has registered an obligation.
- Review completions are **SHA-chained into a tamper-evident audit log**.
- Tier 1 detection is **path-regex-driven**, not prompt-interpretable.
- Git hook backstops survive **`git commit --no-verify`**.

Use `codex-plugin-cc` if you want the review tool. Use `tdd-guard` if you want TDD enforcement standalone. Use this pack if you want the review *forced* by the workflow, the discipline *enforced* by the path, and the trail *auditable* after the fact.

## What's included (v1.9.6)

Verified counts from the current repo:

| Component | Count | Source of truth |
|---|---|---|
| Safety / state hooks | 17 | `.claude/hooks/*.sh` |
| Workflow / reviewer skills | 14 | `.claude/skills/*/SKILL.md` |
| Reviewer subagents | 6 | `.claude/agents/*.md` |
| Project rule files | 10 | `.claude/rules/*.md` |
| Plan / proof / matrix templates | 8 | `.tdd/templates/*.md` |
| Tier 1 path presets | 3 | `.tdd/presets/{library,cli,service}.json` |
| Hook smoke tests | 564 cases | `scripts/tdd-test-hooks.sh` (target: 564/564 passing) |
| Worked example cycle | 4 stages | `examples/tdd-cycle/{01-spec,02-red,03-green,04-refactor}/` |

## Feature status

This is the **v1.9.6 first public release**. The project matured privately through v1.0.0 → v1.9.6 before being opened. Honest about what's stable, what's still moving, what's experimental:

| Feature | Status | Since |
|---|---|---|
| Mode A / Mode B routing (`tier1_path_regexes`) | Stable | v1.0.0 |
| Safety hooks (`guard-dangerous-bash`, `scan-for-secrets`, `guard-protected-files`) | Stable | v1.0.0 |
| TDD state machine (`require-tdd-state.sh` + plan/red/green markers) | Stable | v1.2.x |
| `/second-opinion` skill via Codex CLI | Stable | v1.6.0 |
| Git hook backstops (`pre-commit` + `prepare-commit-msg`) | Stable | v1.6.x |
| Graduated enforcement (`enforcement_mode: strict\|warn\|off`) | Stable | v1.6.x |
| Typed test-edit exceptions (replaces all-or-nothing boolean) | Stable | v1.7.0 |
| AST validator + SHA-chained audit log | Stable | v1.8.0 |
| No-discretion enforcement (plan/test/production triggers) | Stable | v1.9.0 |
| Round cap for /second-opinion (default 4) | Stable | v1.9.1 |
| Legacy hook defers when no-discretion enabled | Stable | v1.9.4 |
| Self-enforcement on this pack itself | Stable | v1.9.5 |
| Plugin marketplace distribution (Claude Code) | New | v1.9.6 |
| Host-config-isolated smoke fixtures | Backlog | v1.10.x |
| End-to-end runner Codex smoke | Backlog | v1.10.x |
| DevOps profile (Terraform / K8s / Helm) | Spec drafted | v2.0.x |

## Quickstart

This pack supports two distribution paths. Pick the one that fits how you work.

### Path A — Claude Code plugin install (recommended for new projects)

```bash
# In Claude Code, one-time:
/plugin marketplace add prilive-com/go-claude-forge

# Install
/plugin install go-claude-forge@prilive-com

# Verify
make doctor
```

After install, all plugin commands are namespaced by plugin name:

```
/go-claude-forge:plan
/go-claude-forge:second-opinion
/go-claude-forge:audit
```

### Path B — Starter-pack clone (the v1.8.0 model, still supported)

Per the upstream MAINTAINING.md, through v1.8.0 this was distributed exclusively as a starter pack: "There is no plugin marketplace involvement. Each Go project gets its own copy." That path still works. v1.9.6 adds plugin install as a second option; it doesn't replace the clone path.

For projects that prefer a checked-in, customizable copy with no plugin runtime dependency:

```bash
git clone --depth 1 https://github.com/prilive-com/go-claude-forge.git my-service
cd my-service
rm -rf .git

# Customize:
#  - .tdd/tdd-config.json        project_name + tier1 regexes for your code
#  - .claude/redact-patterns.txt project-specific secret patterns
#  - README.md                   replace placeholders
#  - Pick one CI: rm -rf .github/ (if GitLab) or rm .gitlab-ci.yml (if GitHub)

go mod init <your-module-path>
git init && git add . && git commit -m "Initial commit from go-claude-forge v1.9.6"
git remote add origin <your-remote-url>
git push -u origin main

# Verify
make doctor
make tdd-test    # target: 564/564 hook smoke tests passing
```

### First-run note (MCP approval)

The pack ships a project-scoped MCP server (`gopls`) at `.mcp.json`. Per Anthropic's CVE-2025-59536 fix, Claude Code requires **explicit one-time user approval** before running any project MCP server. The first time you run `claude` in the project, accept the `gopls` approval prompt (or run `/mcp` to enable it manually). After that, gopls loads automatically.

### Validate the marketplace before publishing (maintainers only)

```bash
claude plugin validate .
```

Anthropic recommends this before sharing a marketplace publicly.

## How it works

### Mode A vs Mode B

The actual rule from this pack's `CLAUDE.md`:

> **Mode A — High-stakes paths (TDD ceremony required).** Files matching regexes in `.tdd/tdd-config.json` `tier1_path_regexes` require the `go-tdd-bugfix` or `go-tdd-feature` skill. The `require-tdd-state.sh` PreToolUse hook blocks production-code edits without an approved plan.
>
> **Mode B — All other code.** Use the `minimal-go-change` skill. No TDD ceremony, but the standard discipline still applies (red-before-green where tractable, race detector green, etc.).

The path determines the mode. The AI doesn't choose.

### The six defense layers

```
Layer 0 — Specification gate.   specs/ + specify skill. Specify → Plan → Tasks → Implement.
Layer 1 — TDD ceremony (Tier 1). .tdd/current-plan.md state machine + require-tdd-state.sh
                                  blocking gate. Two human approval gates.
Layer 2 — In-session prevention. CLAUDE.md + .claude/rules/* + skills + subagents + safety
                                  hooks (guard-dangerous-bash, scan-for-secrets,
                                  guard-protected-files, gofmt-after-edit, detect-ai-bloat).
Layer 3 — Mechanical floor (CI). gofmt, go vet, staticcheck, govulncheck, deadcode,
                                  allowed-modules, race detector, TDD ceremony check.
Layer 4 — Review judgment.       REVIEW.md + reviewer subagents (go-reviewer,
                                  go-architect, go-concurrency-reviewer,
                                  go-security-reviewer, go-test-engineer,
                                  go-bloat-reviewer).
Layer 5 — Cleanup.               negative-diff skill explicitly tasked with deletion
                                  after implementation.
```

Each layer is independent. CI is the deterministic floor when in-session enforcement is bypassed.

### The three trigger points (Layer 1, v1.9.0+)

Once `second_opinion.no_discretion.enabled: true`, every meaningful AI action fires a `PreToolUse` hook scoped to a verifiable obligation:

```mermaid
sequenceDiagram
  autonumber
  participant U as You
  participant C as Claude Code
  participant H as Pack hooks
  participant O as Codex /second-opinion (runner)
  participant L as SHA-chained audit log

  U->>C: "Add feature X"
  C->>H: Write .tdd/current-plan.md
  H-->>C: BLOCKED — plan_review obligation pending
  C->>O: scripts/tdd/run-second-opinion.sh plan_review <cycle-id>
  O-->>L: completion + chained SHA
  L-->>H: scope_hash matches → unblock
  C->>H: Write *_test.go (red phase)
  H-->>C: BLOCKED — test_review obligation pending
  C->>O: scripts/tdd/run-second-opinion.sh test_review <cycle-id>
  O-->>L: completion + chained SHA
  L-->>H: unblock; red confirmed
  C->>H: Edit production .go
  H-->>C: BLOCKED — production_edit obligation
  Note over C,O: One completion covers all production edits<br/>in this cycle until next commit
  C->>U: Receipts ready · commit gate runs final review
```

| Trigger | Fires on | Obligation |
|---|---|---|
| **Plan write** | Writes to `.tdd/current-plan.md`, `.tdd/plans/**`, `docs/specs/*.md` | `plan_review_completion` matching `sha256(cycle_id ‖ plan_path ‖ content_hash)` |
| **Test write** | Substantive writes / creates of `*_test.go` | `test_review_completion` matching `sha256(cycle_id ‖ test_path ‖ package_hash)` |
| **Production edit** | Writes to any production `.go` outside test / governance / infra dirs | `production_edit_review_completion` matching `sha256(cycle_id ‖ base_git_sha ‖ tier)` — one completion covers all production edits in the cycle until next commit |

Read-only inspection (Bash `grep`, Read, `git diff`) does **not** fire a trigger. Friction is bounded by commit count, not file count.

### Defense-in-depth at install time

```
Layer 1 — Claude Code hooks   →  AI-side enforcement (PreToolUse / PostToolUse / Stop)
Layer 2 — Git hooks           →  prepare-commit-msg backstop (NOT bypassed by --no-verify)
Layer 3 — Server-side CI      →  PR-level re-check against the same rules
Layer 4 — SHA-chained audit   →  Tamper-evident record verifiable offline
```

Layer 2 is load-bearing: per official Git documentation, `git commit --no-verify` skips ONLY `pre-commit` and `commit-msg`. It does **NOT** skip `prepare-commit-msg`. This pack installs both, so `--no-verify` cannot reach the Tier 1 gate.

### Why hooks, not only prompts

```
Skills explain the workflow.
Rules document the conventions.
Hooks enforce the gates — fail-closed when preconditions are missing.
Git hooks catch commits made outside Claude Code.
CI re-checks everything before merge.
```

## Configuration

The single source of truth is `.tdd/tdd-config.json`. Three preset variants ship in `.tdd/presets/{library,cli,service}.json` — start with the closest match, then customize.

### Real configuration keys

```jsonc
{
  "project_name": "my-service",

  // Graduated enforcement. Default: strict.
  // Security hooks (guard-dangerous-bash, guard-protected-files,
  // scan-for-secrets) ignore this — strict-only by design.
  "enforcement_mode": "strict",        // "strict" | "warn" | "off"
  "enforcement_mode_overrides": {},    // per-hook overrides

  // Tier 1 = full TDD ceremony required. The hook fires only on paths
  // matching ANY of these regexes. Everything else is Mode B.
  "tier1_path_regexes": [
    "(^|/)internal/(.+/)?(auth|authorization|rbac|policy|security|crypto|secret|session|token)[^/]*/.*\\.go$",
    "(^|/)internal/(.+/)?(payment|billing|invoice|ledger|accounting|balance)[^/]*/.*\\.go$",
    "(^|/)migrations/.*\\.sql$",
    "(^|/)cmd/(.+/)?(destructive|admin|migrate)/.*\\.go$",

    // Pack-self entries — keep these to prevent the agent from
    // silently relaxing its own oversight by editing the governance code.
    "(^|/)\\.claude/hooks/(gate-tier1-commit|guard-dangerous-bash|guard-protected-files|scan-for-secrets|require-tdd-state|require-second-opinion)\\.sh$",
    "(^|/)\\.claude/skills/second-opinion/SKILL\\.md$",
    "(^|/)\\.tdd/tdd-config\\.json$"
  ],

  // Markers that must be present (= "yes") in .tdd/current-plan.md before
  // production edits (edit time) or commit (commit time).
  "required_markers_edit_time": [
    "Human approved spec: yes",
    "Red phase confirmed: yes",
    "Green phase authorized: yes"
  ],
  "required_markers_commit_time": [
    "Human approved spec: yes",
    "Red phase confirmed: yes",
    "Green phase authorized: yes",
    "Implementation reviewed: yes"
  ],

  // /second-opinion configuration.
  "second_opinion": {
    "model_tier1":   "gpt-5.5",
    "model_default": "gpt-5.5",
    "fallback_model": "gpt-5.4",

    // No-discretion mode (v1.9.0+). When enabled, the v1.9 trigger hooks
    // own the review gate. The legacy require-second-opinion.sh defers
    // (since v1.9.4).
    "no_discretion": {
      "enabled": true,
      "max_review_rounds_per_cycle": 4,
      "required_for": {
        "plan_writes":      true,
        "test_writes":      true,
        "production_edits": true
      }
    }
  },

  // Trivial paths skip /second-opinion entirely.
  "trivial_paths": [
    "*.md", "*.txt", "*CHANGELOG*", "*README*", "*LICENSE*",
    ".editorconfig", ".gitignore", "go.sum", ".github/*", ".gitlab-ci.yml"
  ]
}
```

### Switching presets

```bash
# Library / SDK (everything in pkg/ is a one-way door)
cp .tdd/presets/library.json .tdd/tdd-config.json

# CLI (cmd/, runner code, destructive subcommands)
cp .tdd/presets/cli.json .tdd/tdd-config.json

# Service (active default — money, auth, migrations, notifications)
cp .tdd/presets/service.json .tdd/tdd-config.json
```

Then set `project_name` and adjust regexes for your code.

### Rollout

Use `warn` mode during onboarding; flip to `strict` once the team is comfortable:

```jsonc
// During rollout — hooks print warnings but allow
"enforcement_mode": "warn"

// Once ready — hooks block
"enforcement_mode": "strict"
```

### Killswitches (emergency only — document in commit message)

| Variable | Effect |
|---|---|
| `TDD_COMMIT_GATE_DISABLE=1` | bypass `gate-tier1-commit.sh` |
| `SECOND_OPINION_DISABLE=1` | bypass `require-second-opinion.sh` |
| `SECOND_OPINION_HASH_DISABLE=1` | bypass F5 hash binding only |
| `TDD_GIT_HOOK_DISABLE=1` | bypass both git-side hooks |

Each killswitch is documented in `CLAUDE.md` and emits a stderr advisory when used.

## Worked example

A complete Tier 1 TDD cycle (spec → red → green → refactor) lives in [`examples/tdd-cycle/`](examples/tdd-cycle/). Each of the four stage directories shows what `.tdd/current-plan.md`, `.tdd/red-proof.md`, the test, and the implementation look like at that gate:

```
examples/tdd-cycle/
├── README.md
├── 01-spec/      current-plan.md
├── 02-red/       current-plan.md, cents_test.go, red-proof.md
├── 03-green/     current-plan.md, cents_test.go, cents.go
└── 04-refactor/  current-plan.md, cents_test.go, cents.go
```

Read the four-stage README to see how the markers transition from `no` → `yes` and what each hook does to gate the transitions.

For the runner-driven (v1.9.0+) flow specifically:

1. Claude writes plan → plan-trigger fires → run `scripts/tdd/run-second-opinion.sh plan_review <cycle-id>` → operator approves spec.
2. Claude writes red test → test-trigger fires → run `scripts/tdd/run-second-opinion.sh test_review <cycle-id>` → operator approves red.
3. Claude edits production → production-trigger fires (first edit only) → run `scripts/tdd/run-second-opinion.sh production_edit <cycle-id>` → subsequent edits proceed until next commit.
4. `go test ./... && go test -race ./...` → operator approves green.
5. `git commit` → commit gate runs final-diff review → commit lands.

## Error codes

| Code | Meaning |
|---|---|
| `PLAN_REVIEW_REQUIRED` | A plan/spec write needs second-opinion review |
| `TEST_REVIEW_REQUIRED` | A test write or create needs second-opinion review |
| `PRODUCTION_EDIT_REVIEW_REQUIRED` | A production code edit needs second-opinion review |
| `REVIEW_SCOPE_MISMATCH` | The review exists but does not match this file or scope |
| `REVIEW_TYPE_MISMATCH` | A review of another type cannot satisfy this action |
| `REVIEW_COMPLETION_EXPIRED` | The review was bound to an old base Git SHA or stale plan |
| `PRODUCTION_SCOPE_DRIFT` | The current file list differs from the obligation's recorded list |
| `CODEX_OUTPUT_NON_CONFORMANT` | Codex output did not match the required schema |
| `MODEL_NOT_SCHEMA_COMPATIBLE` | The configured Codex model is in a family known to silently drop `--output-schema` |
| `WAIVER_REQUIRED` | A scoped operator waiver is required |
| `WAIVER_PATTERN_ABUSE` | Cycle has hit the `max_per_cycle` waiver cap |

Each error block tells you the exact command to resolve it.

## Escape hatches (used sparingly)

Real engineering sometimes ships hotfixes at 2 AM. So:

- `TDD_COMMIT_GATE_DISABLE=1` — bypass commit gate (audit-logged)
- `SECOND_OPINION_DISABLE=1` — bypass second-opinion (audit-logged)
- Operator waiver: `.tdd/waivers/OPERATOR_WAIVER_<sha>.txt` — single-SHA, signed by approval marker
- Cycle abandonment: `echo "APPROVED CYCLE ABANDONMENT" > .tdd/CYCLE_ABANDONED.txt` — **only the operator can do this; the agent has no path** (Edit/Write/Bash all denied by design). Real shell, outside Claude Code.

Every bypass is recorded with operator identity in the SHA-chained audit log. Quarterly review of the bypass rate is part of the recommended workflow.

## Verification commands

```bash
make doctor       # verify required + recommended tools are installed
make tools        # install Go developer tools (gopls, staticcheck, ...)
make tdd-test     # run hook smoke tests (target: 564/564)
make ci           # run the full CI sequence locally
make test         # go test ./...
make race         # go test -race ./...
make vuln         # govulncheck ./...
make staticcheck  # staticcheck ./...
make lint         # golangci-lint run ./...
make fmt          # gofmt + goimports
make tidy         # go mod tidy
```

If any required tool is missing, hooks fail closed with a clear diagnostic. `make doctor` is the fastest way to see what to install.

**Required tools** (without these, hooks fail closed loudly):

- Claude Code ≥ 2.1.89
- Go ≥ 1.26.2
- `bash`, `jq`, `git`, `gofmt`

**Recommended tools** (full enforcement):

- `gopls` (Go language server, exposed via the gopls MCP)
- `goimports` (import management; used by `gofmt-after-edit.sh`)
- `staticcheck`, `govulncheck`, `golangci-lint`, `deadcode` (used in CI)
- `gitleaks` (content-based secret scanning; `scan-for-secrets.sh` falls back to a narrow regex set without it)
- `codex` ≥ 0.4 (for `/second-opinion`)

## Verifying a release

Every tagged release ships with cosign keyless signatures, SLSA v1.0 provenance, and SBOMs in both SPDX and CycloneDX formats (planned for the first public-tagged release):

```bash
# Verify signature
cosign verify-blob \
  --certificate-identity-regexp 'https://github.com/prilive-com/go-claude-forge/' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  --signature go-claude-forge-vX.Y.Z.tar.gz.sig \
  go-claude-forge-vX.Y.Z.tar.gz

# Verify SLSA provenance
slsa-verifier verify-artifact \
  --provenance-path go-claude-forge-vX.Y.Z.intoto.jsonl \
  --source-uri github.com/prilive-com/go-claude-forge \
  --source-tag vX.Y.Z \
  go-claude-forge-vX.Y.Z.tar.gz
```

If either check fails, do not install. [Open a security advisory.](#security)

## Compatibility

| `go-claude-forge` | Claude Code | Go | OpenAI Codex CLI |
|---|---|---|---|
| **1.9.x** (current) | ≥ 2.1.89 | 1.26.2+ | ≥ 0.4 |
| 1.10.x (planned) | ≥ 2.x | 1.26.2+ | ≥ 0.5 |

**Claude Code floor explanation:** versions < 2.1.89 silently treat hook `permissionDecision: "defer"` as `allow` in non-interactive mode, defeating the guardrail. Two relevant CVEs were co-disclosed Feb 2026 (CVE-2025-59536 hooks RCE + MCP consent bypass; CVE-2026-21852 API-key exfiltration). See [`CLAUDE.md`](CLAUDE.md) for the full security note.

**Known upstream caveats — mitigated automatically by the runner:**

- `openai/codex#4181` — `--output-schema` silently dropped for `gpt-5-codex` family. Runner pins to `gpt-5.5` and fails closed if an incompatible model is configured (`MODEL_NOT_SCHEMA_COMPATIBLE`).
- `openai/codex#15451` — `--output-schema` silently ignored when MCP servers are active. Runner verifies output conformance with `jq`, not flag-trust.

## What gets sent to OpenAI when `/second-opinion` runs

Transparent by design:

- The first 200 lines of `CLAUDE.md`, after redaction
- The target (plan / diff / file / question), after redaction
- The anti-sycophancy prompt template (no project data)

What stays local:

- The full `CLAUDE.md`, all rules files, all hooks
- The full repo (Codex sandbox is `read-only` AND `--cd "$PWD"`)
- Session rollout (`--ephemeral`)

To harden the data path:

- **Project-specific redaction**: edit `.claude/redact-patterns.txt` (template at `.claude/redact-patterns.txt.example`). Universal patterns for cloud keys, DSNs, PEM, JWT, vendor-agnostic named-variable secrets, and Telegram tokens are already in the skill.
- **ChatGPT data setting**: Settings → Data Controls → "Improve the model for everyone: OFF" disables training-on-your-data (Plus / Pro / Team). Business / Enterprise / API are opt-out by default.

## What this isn't

To save your time:

- **Not a Claude Code replacement.** Runs inside Claude Code; you still need the upstream client installed and authenticated.
- **Not a replacement for human review.** `/second-opinion` surfaces disagreement between models so a human can act. Two AIs agreeing is not the same as being right.
- **Not a Go linter / static analyzer / security scanner.** Uses `golangci-lint`, `staticcheck`, `govulncheck`, `gosec`, `nilaway`, `deadcode` — doesn't replace them.
- **Not a generic policy-as-code framework.** Picked breadth-of-Claude-Code over depth-of-policy.
- **Not a guarantee that AI-generated code is correct.** Reduces a specific class of bypass; does not make arbitrary code safe.
- **Not a magic safety layer for arbitrary shell commands.** `guard-dangerous-bash.sh` catches common patterns; you still review.
- **Not a binary distribution.** Everything is bash + Go source.
- **No telemetry.** Ever. No usage analytics, no error reporting, no phone-home.

## Repository layout

Following Anthropic's documented marketplace layout (`plugins/<name>/` subdirectory):

```
go-claude-forge/                       ← marketplace catalog root
  .claude-plugin/
    marketplace.json                   ← name: "prilive-com", lists go-claude-forge
  plugins/
    go-claude-forge/                   ← the plugin itself (matches plugin name)
      .claude-plugin/
        plugin.json                    ← name: "go-claude-forge", version: 1.9.6
      .claude/
        hooks/                         ← 17 enforcement hooks
        skills/                        ← 14 workflow / reviewer skills
        agents/                        ← 6 reviewer subagents
        rules/                         ← 10 project rule files
        settings.json                  ← hook registration
      .tdd/
        templates/                     ← 8 plan / proof / matrix templates
        presets/                       ← 3 Tier 1 path presets
        tdd-config.example.json
      scripts/
        tdd/
          ast/validator.go             ← AST validator (Go) for typed exceptions
          run-second-opinion.sh        ← single legitimate Codex caller
          ...
        git-hooks/                     ← pre-commit + prepare-commit-msg
        install-git-hooks.sh
        doctor.sh
        tdd-test-hooks.sh
      Makefile                         ← make doctor, make tdd-test, make ci, ...
      AGENTS.md                        ← Codex reviewer instructions
      CLAUDE.md                        ← Pack maintainer's instructions
      MAINTAINING.md                   ← Pack maintainer onboarding
      README.md                        ← Plugin-internal README

  docs/                                ← stays at marketplace root
  examples/                            ← stays at marketplace root
  README.md                            ← public-facing README (this file)
  LICENSE, NOTICE, CHANGELOG.md, CONTRIBUTING.md, CODE_OF_CONDUCT.md, SECURITY.md
```

Single-plugin-at-marketplace-root is also supported by Anthropic via the `metadata.pluginRoot` shortcut, but the `plugins/<name>/` subdirectory pattern is the documented canonical layout and is what the official walkthrough uses.

## Documentation

Real files (no fantasy Diátaxis tree — flat structure matching the actual repo):

| Topic | File |
|---|---|
| First-time AI developer onboarding | [`docs/AI_DEVELOPER_GUIDE.md`](docs/AI_DEVELOPER_GUIDE.md) |
| Single-project install | [`docs/ADOPTION_GUIDE.md`](docs/ADOPTION_GUIDE.md) |
| Multi-service Go monorepo (single root install pattern) | [`docs/MONOREPO_ADOPTION_GUIDE.md`](docs/MONOREPO_ADOPTION_GUIDE.md) |
| CI/CD integration | [`docs/INTEGRATION_GUIDE.md`](docs/INTEGRATION_GUIDE.md) |
| Release process | [`docs/RELEASE_GUIDE.md`](docs/RELEASE_GUIDE.md) |
| Update notes between versions | [`docs/DEVELOPER_UPDATE_NOTES.md`](docs/DEVELOPER_UPDATE_NOTES.md) |
| Full TDD workflow (21-step) | [`docs/process/tdd_workflow.md`](docs/process/tdd_workflow.md) |
| `/second-opinion` design rationale | [`docs/specs/second-opinion-v1.6.0-spec.md`](docs/specs/) |
| Typed exception system | [`docs/specs/typed-test-edit-exceptions-v1.7.0-spec.md`](docs/specs/) |
| AST validator + audit chain | [`docs/specs/ast-validator-and-audit-integrity-v1.8.0-spec.md`](docs/specs/) |
| OSS launch playbook (generic + this pack) | [`docs/opensource/`](docs/opensource/) |
| Pack maintenance | [`MAINTAINING.md`](MAINTAINING.md) |
| Cross-agent operating rules (Codex) | [`AGENTS.md`](AGENTS.md) |
| Staff+ review rubric | [`REVIEW.md`](REVIEW.md) |

## Cross-language reuse

The `/second-opinion` skill and the cross-model review mechanism are largely language-agnostic — they operate on git diffs, plans, and files. The broader pack (TDD hooks, AST validator at `scripts/tdd/ast/validator.go`, doctor checks, the `go-*` skills) is Go-specific by design.

If you want the same review discipline for other languages, the planned path is sibling packs under the same org: `py-claude-forge`, `ts-claude-forge`, etc., each with its own `tier1_path_regexes` and language-specific skills, while sharing the cross-model review pattern and audit-chain infrastructure. The DevOps adaptation is the first cross-language proof and lives in `docs/specs/`.

## Roadmap

**Planned for v1.10.x:**

- Host-config-isolated smoke fixtures (so `make tdd-test` passes in monorepos and adopters with narrower Tier 1 regexes)
- End-to-end runner smoke that invokes Codex against a tiny diff (would have caught the v1.9.0–.3 schema bugs at author-time)
- Stack-composition smoke class (catches inter-hook contradictions like the v1.9.4 deadlock)
- Path-aware audit log routing for monorepos (optional, opt-in)
- Guided installer for the clone-path install
- Container image for CI use

**Spec drafted, not yet implemented:**

- DevOps profile (Terraform / K8s / Helm) sharing this pack's audit-chain and second-opinion infrastructure

**Deliberately not planned:**

- Fully autonomous production operations
- Hidden review bypasses
- Unscoped global waivers
- AI-only approval for protected changes
- Telemetry

## Security

For anything that could bypass a Tier 1 gate, the SHA-chained audit chain, or a security hook: **do not open a public issue**. Use [GitHub Private Vulnerability Reporting](https://github.com/prilive-com/go-claude-forge/security/advisories/new) or email **security@** (PGP fingerprint in [`SECURITY.md`](SECURITY.md)).

**Trust note:** this pack defines hooks that execute shell scripts on every Bash/Edit/Write tool call. Only install from sources you trust, and review `.claude/hooks/*.sh` the same way you would review any code that runs on your machine. See [CVE-2025-59536](https://nvd.nist.gov/vuln/detail/CVE-2025-59536) — an earlier Claude Code vulnerability where untrusted project settings could trigger code execution before the user accepted the trust dialog.

Response SLA: acknowledgment within 72 hours, severity triage within 14 days, fix released within 90 days for P0/P1. Earlier if exploited in the wild.

Full policy, threat model, out-of-scope items: [`SECURITY.md`](SECURITY.md).

## Contributing

The review bar scales with risk:

- **Docs, examples, typos** → open a PR; review within 14 days.
- **Bug fixes** → open a PR with a regression test; review within 14 days.
- **Hook behavior, schema, or `/second-opinion` workflow changes** → open an issue first with a written proposal; we discuss before code.

Every contribution is reviewed by Claude Code running this pack on itself (the pack self-enforces since v1.9.5). If the pack's own hooks would block your change in a user's repo, they block it here too. Intentional.

All commits require **DCO sign-off** (`git commit -s`). The [DCO GitHub App](https://github.com/apps/dco) enforces this on every PR.

**AI-assisted contributions** are welcome with disclosure — add an `Assisted-by:` trailer naming the tool. PRs that look LLM-output without disclosure may be closed without review. Full policy in [`CONTRIBUTING.md`](CONTRIBUTING.md).

Code of conduct: [Contributor Covenant 3.0](CODE_OF_CONDUCT.md) (released 2025; latest version). Enforcement: **conduct@**. Decision-making: [`GOVERNANCE.md`](GOVERNANCE.md).

## Project status

- **Current version:** v1.9.6 (first public release after internal v1.0.0 → v1.9.6 lineage; see [`CHANGELOG.md`](CHANGELOG.md))
- **Maintenance:** Prilive
- **Cadence:** patches as needed; minor releases quarterly
- **Backwards compatibility:** `enforcement_mode` schema and hook event interfaces are stable; CHANGELOG `Removed` and `Security` sections call out breaks loudly
- **Path forward:** v1.9.x consolidates plugin distribution + no-discretion enforcement; v1.10.x clears the smoke / installer / observability backlog; v2.0.x extracts a DevOps profile (Terraform / K8s / Helm) sharing the same audit-chain and second-opinion infrastructure

## License

Apache License 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

The patent grant in Apache 2.0 is deliberate: this project will be adopted by employees of patent-holding companies; we want their contributions to flow without ambiguity.

## Citation

If this project influences your work:

```bibtex
@software{go_claude_forge_YEAR,
  title   = {go-claude-forge: Governance scaffolding for AI-assisted Go development with Claude Code},
  author  = {Dvornikov, Anton},
  year    = {YEAR},
  url     = {https://github.com/prilive-com/go-claude-forge},
  version = {1.9.6}
}
```

Or use the **Cite this repository** button on GitHub (rendered from `CITATION.cff`).

## Acknowledgments

Prior art and inspiration (verified active projects):

- [`nizos/tdd-guard`](https://github.com/nizos/tdd-guard) — automated TDD enforcement for Claude Code; multi-language test-first validation. Different focus (TDD enforcement standalone); influenced our state-machine framing.
- [`hamelsmu/claude-review-loop`](https://github.com/hamelsmu/claude-review-loop) — two-phase Claude+Codex review loop. Different focus (review after task completion); influenced our review-completion artifact pattern.
- [`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc) — OpenAI's official plugin bringing Codex into Claude Code. Different focus (cross-model review tool); our pack adds enforcement and audit-chain on top of the same review pattern.
- The [Anthropic Claude Code](https://code.claude.com) team — for the hook architecture, MCP integration, and plugin system this builds on.
- The [Sigstore](https://www.sigstore.dev/) and [SLSA](https://slsa.dev/) communities for supply-chain primitives.
- Every reviewer whose finding became a regression test.

---

<div align="center">

*Built layer by layer · Dogfooded on its own development · Apache 2.0*

</div>
