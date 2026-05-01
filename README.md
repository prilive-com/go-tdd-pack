# <project-name>

<one-line description of this Go project>

This project was bootstrapped from
[`go-claude-starter`](https://gitlab.your-domain.com/your-group/go-claude-starter)
v1.0.0. The Claude Code governance lives under `.claude/` and works
automatically — no per-clone setup required.

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

## Recommended local tools

```bash
# Go developer tools
make tools                 # runs scripts/install-go-tools.sh

# System tools (install via your package manager)
#   jq           — required for TDD hooks
#   golangci-lint — recommended
#   gitleaks     — strongly recommended (used by scan-for-secrets.sh)
```

If `jq` is missing, the TDD gate hook will block edits with an
informative message. Install once and forget.

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
