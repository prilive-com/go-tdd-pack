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
- `examples/tdd-cycle/` — illustrative 4-stage worked example of a
  Tier 1 TDD cycle. Each `.go` file carries `//go:build ignore` so
  `go build ./...` skips them. Snapshot, not a runnable package.
  When the templates in `.tdd/templates/` change, this example will
  drift — update deliberately at minor revisions, don't auto-sync.

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

## Subagent model choice

All 6 reviewer subagents (`go-reviewer`, `go-architect`,
`go-concurrency-reviewer`, `go-security-reviewer`, `go-test-engineer`,
`go-bloat-reviewer`) use `model: opus`. This is a **deliberate
quality-over-cost trade-off** by the user, not a missed optimization.

The original v1.1.0 spec recommended a sonnet/opus split (sonnet for
the more mechanical reviewers — bloat, test-engineer — to save tokens).
The user explicitly directed otherwise: "always use the most powerful
and latest model." That preference is durable: don't propose downgrading
agent models for cost or latency reasons in future starter versions.

The `model: opus` alias auto-tracks the latest Opus release (Opus 4.7
at the time of v1.1.x), so this scales forward without per-version
maintenance.

If a future maintainer's context changes and cost becomes a real
constraint, the cheapest first step would be flipping `go-bloat-reviewer`
to `sonnet` (mechanical pattern detection) and watching for regressions
in delete-list quality. Don't do this without explicit operator buy-in.

## Adding project-specific guards (DevOps, trading, etc.)

This pack ships **only universal Go-development safety**:

- universal git/shell hazards (--no-verify family, force-push, history rewrite, rm -rf, sudo, curl|bash)
- production database hazards (psql/mysql/mongo against production hosts, DROP/TRUNCATE on production, `--accept-data-loss`)
- generic credential leakage (cloud providers, GitHub/Slack/Anthropic/OpenAI tokens, DB DSNs with passwords, PEM private keys)

**Out of upstream scope** (intentional, v1.3.0):

- Infrastructure-as-code: `terraform destroy/apply`, `helm upgrade/install`, `kubectl`.
- Container operations: `docker push`.
- Domain-specific blast-radius commands (e.g. `cmd/sell_all` for a trading bot, `liquidate`, `force-close`, `docker volume rm <project>_*`).

If your project uses any of these, add the rules to **your project's
fork** of `.claude/hooks/guard-dangerous-bash.sh`. Pattern to copy:

```bash
# === <PROJECT NAME> PROJECT GUARDS (not upstream) ===

# IaC example (re-add if your project uses Terraform):
if echo "$COMMAND" | grep -Eq 'terraform[[:space:]]+destroy'; then
  deny "Refusing: terraform destroy. Infrastructure teardown requires explicit human execution."
fi

# k8s example (re-add if your project uses Kubernetes):
if echo "$COMMAND" | grep -Eq '^[[:space:]]*kubectl([[:space:]]|$)'; then
  ask "kubectl changes cluster state. Confirm context is not production."
fi

# Trading-bot example (project-specific blast radius):
if echo "$COMMAND" | grep -Eq '(^|[;&|])[[:space:]]*(go[[:space:]]+run[[:space:]]+\./)?cmd/sell_all'; then
  deny "Refusing: cmd/sell_all liquidates all holdings. Use the documented operator runbook only."
fi

# Volume-destruction example (re-add for any project with named volumes):
if echo "$COMMAND" | grep -Eq '(^|[;&|])[[:space:]]*docker[[:space:]]+volume[[:space:]]+rm[[:space:]].*<your-project>'; then
  deny "Refusing: docker volume rm against project volumes destroys local DB state."
fi
```

Also add the matching `permissions.deny` / `permissions.ask` entries
to your project's `.claude/settings.json` for defense-in-depth.

When you re-integrate from upstream (quarterly per the integration
guide), preserve your project guards — they live in your fork, not in
the upstream pack.

## Second-opinion skill design choices

The pack ships an optional `/second-opinion` skill
(`.claude/skills/second-opinion/SKILL.md`) that calls OpenAI Codex
CLI as a cross-model reviewer before non-trivial Tier 1
implementation work. Several design choices are deliberate.

### What it is

A read-only Codex review of a plan, diff, or snippet. Returns
findings as advisory context. Claude stays the final adjudicator.
Codex is treated as a peer reviewer, not authority.

### What it is NOT

- Not a CI gate (failing Codex's tastes does not block anything).
- Not a hook (no PostToolUse / Stop auto-fire).
- Not multi-round debate. Single pass per invocation.
- Not authoritative. Codex catches things AND misses things AND
  sometimes invents things.
- Not free of cost: each call uses ChatGPT subscription tokens (or
  API credits if `CODEX_API_KEY` is set).

### Design choices and why

**Manual / auto-skill invocation, no PostToolUse + Stop hooks.**

A previous spec proposed PostToolUse on `ExitPlanMode` and Stop hooks
firing Codex automatically every Tier 1 ceremony. Rejected at first
shipping because:

- The skill auto-invokes via Claude's skill-description matching when
  the description matches the user's intent. That is selective —
  Claude decides per-task. PostToolUse hooks fire on every matching
  tool event; cost and procedural weight are fixed regardless of
  whether the review would add value.
- Procedural weight on top of the existing TDD ceremony was high
  (Round 1 + Claude rebuttal + Round 2 + adjudication on every
  Tier 1 plan and every Tier 1 diff).
- Sycophancy risk in the OPPOSITE direction (Claude defers to
  "External Reviewer") is real and unmeasured. Manual / per-task
  invocation makes it easy to opt out when noise > signal.
- We have no real-world data yet on how often the second opinion
  actually catches something Claude missed. Building infrastructure
  before evidence is the wrong order.

If real-world use shows the skill is invoked frequently and catches
real defects, revisit auto-fire hooks in a future version with usage
data, NOT before.

**Single-pass review, no Round 2.**

A previous spec proposed a 2-round debate (Round 1 → Claude rebuttal
→ Round 2). Rejected for the same cost / weight reasons. If a
developer wants a second pass after the first, they invoke the skill
again with refined input. Cheaper and clearer.

**Codex is fully optional.**

`make doctor` reports Codex as optional. The pack works without it.
Developers who do not want cross-model review never invoke the skill.
Failures (codex missing, not logged in, timeout, network) are silent
and non-blocking — the skill exits 0 with a one-line note.

**Tier-aware model selection (v1.2.0).**

The skill auto-invokes on **any non-trivial code change**, not just
Tier 1 paths. To keep cost and latency reasonable across that broad
scope, the skill picks the model based on whether the diff touches a
Tier 1 path:

- Touches a Tier 1 path (per `.tdd/tdd-config.json` regexes) →
  `SECOND_OPINION_MODEL_TIER1` (default `gpt-5.5`, the newest frontier).
- Otherwise → `SECOND_OPINION_MODEL_DEFAULT` (default `gpt-5.4-mini`,
  faster and cheaper).

This converts the Tier 1 concept from "gating yes/no" into "how deep
should the review be." Both defaults are overrideable per env var.
`SECOND_OPINION_MODEL` (legacy single knob) still works — if set, both
tiers use that model.

`gpt-5.5` requires ChatGPT auth (not API key). If a developer has only
`CODEX_API_KEY` set, the skill silently falls back to
`SECOND_OPINION_FALLBACK_MODEL` (default `gpt-5.4`); `make doctor`
warns about this combination so the developer knows what to expect.

**Mechanical filters keep volume sensible.**

Removing the Tier 1 path filter from auto-invocation means the skill
could theoretically fire on every code change. To prevent noise and
budget burn, the skill applies four cheap mechanical guards before
invoking Codex on a diff:

1. `skip_globs` — never review files matching these paths regardless
   of size: `*.md`, `*.txt`, `CHANGELOG*`, `README*`, `LICENSE*`,
   `.editorconfig`, `.gitignore`, `go.sum`, `.github/*`,
   `.gitlab-ci.yml`. Keeps docs / lockfiles / CI configs out.
2. `min_substantive_lines: 5` — drops whitespace-only and pure-comment
   `+/-` lines from the count. A 50-line gofmt diff reads as 0
   substantive lines and skips. A 6-line bug fix reviews.
3. Lower bound: 10 total `+/-` lines.
4. Upper bound: 2000 total `+/-` lines (lowered from 4000 in v1.2.0
   per 2026 AI-review benchmarks — quality drops above ~1000-2000).

If you want stricter scope (e.g. revert to Tier-1-only), set the env
var `SECOND_OPINION_DISABLE=1` for non-Tier-1 sessions, or future
versions can reintroduce a `tier1_only` mode if real usage shows the
broad scope creates too much noise.

**Why no rate budget / per-hour cap.**

Consultant proposals included per-session and per-hour rate budgets
(typical of hook-based CI tools like CodeRabbit). The skill mechanism
already throttles naturally — Claude only invokes when its judgment
matches the description. We don't ship the rate budget machinery
because it solves a problem the skill architecture doesn't have.

**Why no policy.json or new scripts.**

A consultant proposed adding `.second-opinion/policy.json`, eight
scripts (classify / build-packet / redact / run / check-adjudication /
clean / route), and a templates directory. Rejected because the
single-file skill is the right shape for "copy folder and forget."
Adding nine files for one optional feature drifts the pack toward
framework. If the trial shows the skill needs modes / state /
templates, revisit in a later release with usage data.

**Anti-deference framing in the prompt and in the skill body.**

The prompt tells Codex: be skeptical, downgrade severities when in
doubt, do NOT pad with praise, zero findings is acceptable. The
skill body tells Claude: do not change a plan or piece of code
solely because the reviewer said so; the reason is the underlying
technical claim. P0/P1 findings require written rationale (3 / 2
sentences) regardless of stance.

**Single env var override, no config file.**

`SECOND_OPINION_MODEL` to switch models, `SECOND_OPINION_DISABLE=1`
to silence. No `.claude/second-opinion.json`. No JSON schemas. Less
to maintain, less to drift.

### Where this lives

- `.claude/skills/second-opinion/SKILL.md` — the skill itself.
- `scripts/doctor.sh` — reports `codex` as optional with auth check.
- `MAINTAINING.md` (this section) — rationale.
- `CLAUDE.md` — one-line entry under "Skills available".

That's it. Two new code locations + two doc additions. If the
feature proves valuable, expansions go in a separate version with
real usage data.

### Branch / merge policy for this feature

This skill was developed on the `feature/second-opinion` branch and
should not merge to `main` until at least 2-4 weeks of real-world
use confirms it adds value. If usage data shows it does not add
value (rarely invoked, findings rarely useful, sycophancy creeps in),
the branch is abandoned. main stays at the version before the skill
was added.

## MCP server registration

Project MCP servers live at `.mcp.json` in the repo root, NOT under
`.claude/`. Claude CLI only reads `.mcp.json` at the project root. The
`enabledMcpjsonServers: ["gopls"]` entry in `.claude/settings.json` is
the explicit allowlist (CVE-2025-59536 defense) — it points to the
entry inside `.mcp.json`. The CVE was about a previous bug where MCP
servers could execute before the user accepted the trust dialog;
current Claude Code requires explicit one-time approval even with the
allowlist set.

Keep `.mcp.json` minimal and schema-shaped (`{"mcpServers": {...}}`).
Do not add `_comment` arrays — this prose belongs here.

## Tool installation policy

`scripts/install-go-tools.sh` defaults every tool to `@latest` (with
env-var override per tool, e.g. `STATICCHECK_VERSION=2026.1.1`).
`govulncheck` is intentionally always `@latest` because vulnerability
databases need fresh data.

For team-wide reproducibility, **pin in your CI** by setting the
`*_VERSION` env vars in your CI variables. The CI files
(`.gitlab-ci.yml`, `.github/workflows/ci.yml`) call `make tools`
instead of inlining `go install ...@latest`, so env-var overrides
take effect end-to-end.

The starter does NOT pin upstream defaults to specific tags because:
- The right pinned version varies by Go release.
- A stale pinned default would silently rot between starter releases.
- Honest "@latest by default; pin in your CI" is more sustainable than
  "we pin for you" with quarterly maintenance debt.

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
