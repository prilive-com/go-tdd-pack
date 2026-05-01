# MAINTAINING.md

For people working on the **starter pack itself**. Cloners of this
repo into a new Go project don't need to read this — delete it after
cloning if you want, or just ignore it.

## Repo identity

This is a **starter pack**, not a Claude Code plugin. There is no
plugin marketplace involvement. Each Go project gets its own copy of
the contents via `git clone` + customization. Updates do not flow in
automatically; teams cherry-pick changes from upstream when they want
them.

## Layout

- `CLAUDE.md` / `AGENTS.md` — consumer-facing operating rules. Carried
  into every cloned project. Keep concise.
- `REVIEW.md` — Staff+ review rubric. Used by the `go-reviewer` agent.
- `.claude/` — what Claude CLI loads automatically:
  - `settings.json` — permissions + hook registration. Path-based
    deny rules + dangerous-bash deny patterns. Hook timeouts in
    seconds. Edit carefully — every consumer inherits this.
  - `allowed-modules.txt` — slopsquat allowlist. Defaults to standard
    Go ecosystem; first line is the org placeholder for the cloner to
    fill in.
  - `rules/` — referenced from `CLAUDE.md`. Loaded on demand.
  - `agents/` — reviewer subagents. Auto-discovered by Claude.
  - `skills/<name>/SKILL.md` — workflow skills. Auto-discovered.
  - `hooks/*.sh` — safety hooks. Three output patterns in this repo,
    each chosen deliberately:
    - **JSON `permissionDecision` for blocking PreToolUse hooks**:
      `guard-dangerous-bash.sh`, `guard-protected-files.sh`,
      `scan-for-secrets.sh`. Emit
      `{hookSpecificOutput:{hookEventName,permissionDecision,permissionDecisionReason}}`
      and exit 0. Supports `deny`, `ask`, and `allow` (`{}` = pass).
      Used here for the dangerous-bash and secret guards because they
      need `ask` for some patterns (e.g. `git push`).
    - **Exit-2 + stderr `<claude-directive>` for the hard TDD gate**:
      `require-tdd-state.sh`. Per Anthropic docs, exit 2 takes
      precedence over `permissions.allow` rules — chosen here as
      defense in depth so the TDD gate cannot be bypassed by a future
      mis-configured allow entry.
    - **Stdout context injection (exit 0) for advisory hooks**:
      `route-to-tdd.sh` (UserPromptSubmit), `session-context.sh`
      (SessionStart) — both emit text/JSON that Claude Code injects
      into the next model request. `detect-ai-bloat.sh` (PostToolUse)
      uses `hookSpecificOutput.additionalContext` for the same effect.
    - When adding a new hook: match the pattern of the existing hook
      in the same event family. Do NOT use `systemMessage` for advisory
      output — it's shown to the user only, not to Claude.
  - **Critical: every hook that calls `jq` must check for jq FIRST.**
    PreToolUse safety hooks fail closed via static-heredoc `deny`
    (no `jq` needed to emit the JSON). The smoke test
    (`scripts/tdd-test-hooks.sh`) exits 1 with a clear error if jq is
    missing — never `exit 0 SKIP` (that lies to CI).
- `.mcp.json` (project root, NOT under `.claude/`) — Claude CLI only
  reads `.mcp.json` at the project root for project-scoped MCP. The
  `enabledMcpjsonServers: ["gopls"]` entry in `.claude/settings.json`
  is the explicit allowlist (CVE-2025-59536 defense) — it points to
  the entry inside `.mcp.json`. The CVE was about a previous bug
  where MCP servers could execute before the user accepted the trust
  dialog; current Claude Code requires explicit one-time approval
  even with the allowlist set.
- `.tdd/` — TDD ceremony machinery. `tdd-config.json` is the only file
  consumers will routinely edit (Tier 1 regexes for their code).
- `specs/README.md` — explains the Layer 0 gate (Specify → Plan →
  Tasks).
- `scripts/` — utility scripts invoked by CI and the Makefile.
  `tdd-test-hooks.sh` is the smoke test — run after any hook change.
- `.gitlab-ci.yml` + `.github/workflows/ci.yml` — both shipped; cloner
  deletes one. Keep them in sync.
- `.golangci.yml`, `.editorconfig`, `.gitignore`, `Makefile` — standard
  Go project boilerplate.

## Common maintenance tasks

### Add a new dangerous-bash deny pattern

1. Edit `.claude/hooks/guard-dangerous-bash.sh`. Cite the incident or
   CVE in the comment.
2. Add a smoke test in `scripts/tdd-test-hooks.sh` proving the new
   pattern is denied.
3. Run `bash scripts/tdd-test-hooks.sh` — must pass.
4. Bump the patch version of `.claude/VERSION`.

### Add a new Tier 1 path regex default

1. Edit `.tdd/tdd-config.json`.
2. Add a smoke test in `scripts/tdd-test-hooks.sh` exercising the new
   pattern (with the actual file layout you expect).
3. Run `bash scripts/tdd-test-hooks.sh`.
4. Bump the minor version (consumers may want to opt in).

### Add a new skill

1. Create `.claude/skills/<name>/SKILL.md` with frontmatter
   (`name`, `description`).
2. The `description` is what Claude uses to decide when to invoke it —
   write it specifically.
3. Reference the new skill from `CLAUDE.md`'s "Skills available" list.
4. Bump the minor version.

### Add a new reviewer agent

1. Create `.claude/agents/<name>.md` with frontmatter
   (`name`, `description`, `tools`, `model`).
2. `tools` takes plain tool names (`Read, Grep, Glob, Bash`); scoped
   patterns like `Bash(go vet *)` are NOT valid in agent frontmatter
   (only in skill `allowed-tools` and `permissions.allow`).
3. Reference the new agent from `CLAUDE.md`'s "Reviewer agents
   available" list.

### Update Go version floor

1. Edit `.gitlab-ci.yml` `GO_VERSION` and `.github/workflows/ci.yml`
   `setup-go` version.
2. Update `CLAUDE.md` "Go 1.26+ specifics" section (or whatever the
   new floor is).
3. Update `.claude/rules/go-style.md` "Go 1.26+ specifics" section.
4. Bump the **major** version (consumers' CI may break).

## Versioning

Semver in `.claude/VERSION`:

- **Patch** — tightening a deny pattern, fixing a hook bug, doc polish
- **Minor** — new agent / skill / rule / hook / Tier 1 default
- **Major** — change existing hook output shape, remove/rename agent
  or skill, bump Go/Claude Code floor, change `.claude/settings.json`
  defaults in a way that could break consumers

## Release

This is a starter, not a published artifact. "Release" means:

1. Bump `.claude/VERSION`.
2. Tag the commit: `git tag v1.x.y && git push --tags`.
3. Update `README.md` references if the version is shown.
4. Tell the team in the channel where they should look for upstream
   changes (since updates don't auto-flow).

## Smoke tests

```bash
make tdd-test            # runs scripts/tdd-test-hooks.sh
for f in $(find . -name '*.json' -not -path './.git/*'); do jq empty "$f"; done
for f in .claude/hooks/*.sh scripts/*.sh; do bash -n "$f"; done
```

These are not yet wired into CI for the starter repo itself — they're
intended to be run by hand before pushing.

## What does NOT belong in the starter

- Any project-specific domain rules, agents, or skills (those go in
  the project's own `.claude/` after cloning).
- Hardcoded module paths, organization names, or service names.
- A bootstrap script. The starter works by edit-after-clone, not by
  running a script. Keeping it script-free is a feature.
- A `pre-commit-config.yaml`. We deliberately rely on CI as the
  deterministic floor; pre-commit would require a per-clone
  `pre-commit install` step, which violates "works automatically by
  existing in the project folder."

## Hook bug awareness

Hooks are in-session prevention, not a security boundary. The
deterministic floor is CI. Known classes of issues to watch in Claude
Code releases:

- PreToolUse exit-2 occasionally not blocking Edit/Write on some
  versions (Bash blocks reliably).
- macOS `permissions.allow/deny` rules occasionally unreliable.
- Some Opus releases stop on hook block instead of acting on the
  feedback — `<claude-directive>` markup in stderr mitigates this.

When Anthropic confirms a fix to any of the above, advisory hooks can
be promoted to enforcement. Document the change in `.claude/VERSION`.
