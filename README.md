# <project-name>

<one-line description of this Go project>

This project was bootstrapped from
[`go-claude-starter`](https://gitlab.your-domain.com/your-group/go-claude-starter)
v1.1.0. The Claude Code governance layer (rules, skills, agents, hooks)
loads automatically — no plugin install, no bootstrap script, no
`pre-commit install`. **Full enforcement requires standard local tools
(see Runtime requirements below); run `make doctor` to verify.**

> **Trust note.** This pack defines hooks that execute shell scripts on
> every Bash/Edit/Write tool call. Only clone this starter from sources
> you trust, and review `.claude/hooks/*.sh` the same way you would
> review any code that runs on your machine. (See CVE-2025-59536 — an
> earlier Claude Code vulnerability where untrusted project settings
> could trigger code execution before the user accepted the trust
> dialog.)

## Runtime requirements

**Required (without these, hooks fail closed loudly):**

- Claude Code (latest)
- Go (1.26+)
- Bash
- jq
- git

**Recommended (full enforcement / quality checks):**

- gopls          (Go language server, exposed via the gopls MCP)
- goimports      (import management; used by `gofmt-after-edit.sh`)
- staticcheck    (static analysis; used in CI)
- govulncheck    (vulnerability scanning; used in CI)
- golangci-lint  (broad lint coverage; used in CI)
- gitleaks       (content-based secret scanning; `scan-for-secrets.sh`
                  falls back to a narrow regex set without it)
- deadcode       (dead-code detection; advisory in CI)

Run `make doctor` to verify what's installed.

## First-run note (MCP approval)

This starter ships a project-scoped MCP server (`gopls`) at `.mcp.json`.
Per Anthropic's CVE-2025-59536 fix, Claude Code requires **explicit
one-time user approval** before running any project MCP server, even
when it appears in `enabledMcpjsonServers`.

The first time you run `claude` in the project, accept the gopls
approval prompt (or run `/mcp` to enable it manually). After that,
gopls loads automatically.

## Layout

```
.
├── CLAUDE.md            # Operating rules (auto-loaded by Claude CLI)
├── AGENTS.md            # Mirror of CLAUDE.md for cross-tool compatibility
├── REVIEW.md            # Staff+ review rubric (used by go-reviewer agent)
├── Makefile             # Convenience targets: make ci / make test / ...
├── .mcp.json            # Project MCP servers (gopls). MUST be at repo root,
│                        # not under .claude/ — Claude CLI only reads .mcp.json
│                        # at the project root for project-scoped MCP.
├── .claude/             # Claude CLI auto-loads this
│   ├── settings.json    # Permissions + hook registration + MCP allowlist
│   ├── allowed-modules.txt  # Slopsquat allowlist
│   ├── rules/           # Loaded on demand from CLAUDE.md
│   ├── agents/          # Reviewer subagents (auto-discovered)
│   ├── skills/          # Workflow skills (auto-discovered)
│   └── hooks/           # Safety hooks (registered via settings.json)
├── .tdd/                # TDD ceremony state machine
│   ├── tdd-config.json  # Tier 1 path regexes + required markers
│   ├── current-plan.md  # Active cycle (idle by default)
│   └── templates/       # feature-plan / bugfix-plan / red-proof
├── specs/               # Layer 0 spec gate (Specify → Plan → Tasks)
├── scripts/             # CI utilities + TDD smoke tests
├── .gitlab-ci.yml       # GitLab CI (delete if you use GitHub Actions)
├── .github/workflows/   # GitHub Actions (delete if you use GitLab)
├── .golangci.yml        # Lint config
└── docs/process/        # TDD workflow reference
```

## How to use this in a new project

```bash
git clone --depth 1 https://gitlab.your-domain.com/your-group/go-claude-starter.git my-service
cd my-service
rm -rf .git
# Customize:
#   - .tdd/tdd-config.json    project_name + tier1 regexes for your code
#   - .claude/allowed-modules.txt   add your org/group prefix as the first line
#   - README.md               replace the placeholders
#   - Pick one CI: rm -rf .github/  (if GitLab) or rm .gitlab-ci.yml (if GitHub)
go mod init <your-module-path>
git init && git add . && git commit -m "Initial commit from go-claude-starter v1.0.0"
git remote add origin <your-remote-url>
git push -u origin main
```

That's it. No bootstrap script. No `pre-commit install`. The Claude CLI
loads `.claude/` automatically when you run `claude` in this directory.
The CI picks up `.gitlab-ci.yml` or `.github/workflows/` automatically.

## Defense layers

1. **Layer 0 — Specification gate.** `specs/` directory + `specify`
   skill. Specify → Plan → Tasks → Implement.
2. **Layer 1 — TDD ceremony for Tier 1 paths.** `.tdd/current-plan.md`
   state machine + `route-to-tdd.sh` advisory router +
   `require-tdd-state.sh` blocking gate. Two human approval gates.
3. **Layer 2 — In-session prevention.** `CLAUDE.md` +
   `.claude/rules/*` + skills + subagents + safety hooks
   (`guard-dangerous-bash`, `scan-for-secrets`, `guard-protected-files`,
   `gofmt-after-edit`, `detect-ai-bloat`).
4. **Layer 3 — Mechanical floor (CI).** `.gitlab-ci.yml` /
   `.github/workflows/ci.yml`: gofmt, go vet, staticcheck, govulncheck,
   deadcode, allowed-modules, race detector, **TDD ceremony check**.
5. **Layer 4 — Review judgment.** `REVIEW.md` + reviewer subagents
   (`go-reviewer`, `go-architect`, `go-concurrency-reviewer`,
   `go-security-reviewer`, `go-test-engineer`, `go-bloat-reviewer`).
6. **Layer 5 — Cleanup.** `negative-diff` skill explicitly tasked with
   deletion after implementation.

## Tooling commands

```bash
make doctor                # verify required + recommended tools are installed
make tools                 # install Go developer tools (gopls, staticcheck, ...)
make tdd-test              # run the hook smoke tests (target: 17/17 passing)
make ci                    # run the full CI sequence locally
```

If any required tool is missing, hooks fail closed with a clear
diagnostic — `make doctor` is the fastest way to see what to install.

## When TDD ceremony applies

The `require-tdd-state.sh` hook fires only on paths matched in
`.tdd/tdd-config.json` `tier1_path_regexes`. Everything else uses
`minimal-go-change` discipline. This is deliberate — full TDD on every
typo fix kills velocity.

Default Tier 1 regexes cover money/billing, auth/security, migrations,
and orchestration. Edit them for your project.

## Updating from upstream starter

This repo was created from `go-claude-starter v1.0.0`. Updates do not
flow in automatically. Refresh quarterly:

1. Compare `.claude/`, `.tdd/templates/`, `.gitlab-ci.yml`,
   `.github/workflows/ci.yml` against the latest starter.
2. Cherry-pick changes you want.
3. Update `.claude/VERSION`.
