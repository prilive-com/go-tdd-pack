# Integration guide

For developers who already use Claude Code in their Go project and
want to merge `go-claude-starter` into what they have.

You are NOT starting from zero. You have:

- An existing `.claude/` folder with your own settings, rules, skills,
  agents, or hooks.
- Your own project rules in `CLAUDE.md` (or similar file).
- Project-specific tools, scripts, or CI jobs.

You want to keep what works for your project AND add what is missing
from this starter.

---

## Step 0 — Before you change anything

1. Make sure your repo is clean: `git status` shows no changes.
2. Create a new branch for the integration work:

   ```bash
   git checkout -b chore/integrate-go-claude-starter
   ```

3. Clone our starter to a separate folder so you can compare files
   side by side:

   ```bash
   git clone --depth 1 \
     ssh://git@gt.devopspoint.io:2244/prompts/go-projects-claude-starter.git \
     /tmp/go-claude-starter-ref
   ```

4. Install the required local tools:

   ```bash
   cd /tmp/go-claude-starter-ref
   make doctor
   ```

   If any **required** tool is missing (red `MISS`), install it first.
   Recommended tools (yellow `WARN`) can be installed later.

5. Read this whole guide before you start moving files.

---

## Step 1 — Read these files first (45 minutes)

These are the files that explain what our system does and why. Read
them in this order:

| # | File | What you learn |
|---|---|---|
| 1 | `README.md` | What the starter is. The 6 defense layers. Runtime requirements. First-run notes. |
| 2 | `CLAUDE.md` | Operating rules for any Go project. Two workflow modes (Tier 1 vs other). Skills and agents that exist. |
| 3 | `MAINTAINING.md` | Why each design choice was made. Hook output styles. Subagent model choice. Tool installation policy. |
| 4 | `docs/process/tdd_workflow.md` | The full TDD tier model. The two human gates. Bypass procedure. |
| 5 | `examples/tdd-cycle/README.md` | A worked Tier 1 cycle from spec to refactor. Read all 4 stage folders too. |

After this you should be able to answer:

- What is a "Tier 1" path?
- What does the `require-tdd-state.sh` hook do?
- Why does our pack ship hooks AND CI gates (defense in depth)?
- What is the difference between `.claude/settings.json` and `.mcp.json`?

If you cannot answer any of these, re-read the file.

---

## Step 2 — Read these files deeper (60 minutes)

Now read the actual implementation. You do not need to memorize every
line — the goal is to know **what is in each folder** so you can
compare with your project later.

### `.claude/` (auto-loaded by Claude CLI)

| File or folder | Read for |
|---|---|
| `.claude/settings.json` | Permissions list (`allow`/`ask`/`deny`). Hook registration. MCP allowlist. |
| `.claude/allowed-modules.txt` | The slopsquat allowlist. The first line is a placeholder for your org prefix. |
| `.claude/VERSION` | Current pack version. |
| `.claude/rules/*.md` | 9 rule files. Read `go-style.md`, `go-pgx.md`, `go-tdd.md`, `go-ai-bloat.md`, `go-security.md`, `go-testing.md`. |
| `.claude/agents/*.md` | 6 reviewer subagents. Note `model: opus` on all of them — keep this. |
| `.claude/skills/*/SKILL.md` | 13 skills. Pay attention to `description:` and `disable-model-invocation:` lines. |
| `.claude/hooks/*.sh` | 8 safety scripts. The most important: `guard-dangerous-bash.sh`, `scan-for-secrets.sh`, `require-tdd-state.sh`. |

### `.tdd/` (read by hooks, not by Claude CLI)

| File | Read for |
|---|---|
| `.tdd/tdd-config.json` | The active Tier 1 path regexes and prompt keywords. Service preset by default. |
| `.tdd/presets/{service,library,cli}.json` | Alternate presets to copy over `.tdd/tdd-config.json`. |
| `.tdd/templates/*.md` | feature-plan, bugfix-plan, red-proof skeletons. |
| `.tdd/current-plan.md` | The state file (idle by default). |

### `.mcp.json` (project root, NOT inside `.claude/`)

The project MCP server list. Currently only `gopls`. The matching
allowlist line is `enabledMcpjsonServers: ["gopls"]` inside
`.claude/settings.json`.

### `scripts/`

| Script | Used for |
|---|---|
| `scripts/doctor.sh` | Verify required + recommended tools. |
| `scripts/install-go-tools.sh` | Install Go developer tools (with `*_VERSION` env var override). |
| `scripts/check-allowed-modules.sh` | CI: slopsquat enforcement. Default `CHECK_TRANSITIVE_MODULES=true` (strict). |
| `scripts/check-tdd-ceremony.sh` | CI: every `green(<id>):` commit on Tier 1 must have a `red(<id>):` before it. |
| `scripts/check-tdd-state-clean.sh` | CI: refuse merge if `.tdd/current-plan.md` is mid-cycle. |
| `scripts/tdd-test-hooks.sh` | Smoke test for hooks. Should report 27/27 passing. |
| `scripts/ci-go.sh` | The full CI sequence as a local script (`make ci`). |

### CI files

- `.gitlab-ci.yml` — for self-hosted GitLab.
- `.github/workflows/ci.yml` — for GitHub Actions.

You only need one of these in your project. Delete the other.

---

## Step 3 — Look at your existing project

Now open your own project. For each item in our starter, answer:

- **Do I have this?** Yes / No / Partial
- **Is mine better, equal, or weaker?**
- **Action:** Keep mine / Take theirs / Merge

Make a table. Example:

| Item | Have it? | Mine vs theirs | Action |
|---|---|---|---|
| `guard-dangerous-bash.sh` | Yes (5 patterns) | Theirs (28 patterns, incident-cited) is stronger | **Take theirs** |
| `CLAUDE.md` go style rules | No | — | **Take theirs** |
| `CLAUDE.md` project domain rules | Yes (custom for our service) | Mine is unique | **Keep mine** |
| `.claude/agents/order-reviewer.md` | Yes (project-specific) | Not in theirs | **Keep mine** |
| `.tdd/tdd-config.json` | No | — | **Take theirs (service preset)** |
| `.claude/allowed-modules.txt` | Partial (only own org) | Theirs has Go ecosystem defaults | **Merge** |

This table is the input to Step 4.

---

## Step 4 — What to keep, take, or merge

### Always TAKE FROM OURS (security-critical, you should not be weaker than us)

- `.claude/hooks/guard-dangerous-bash.sh` — 28+ deny patterns,
  incident-cited.
- `.claude/hooks/scan-for-secrets.sh` — content-based, gitleaks-aware,
  with straddle reconstruction.
- `.claude/hooks/guard-protected-files.sh` — `.env` and migration
  guard.
- `.claude/hooks/require-tdd-state.sh` — Tier 1 blocking gate with
  defensive multi-path extraction.
- `.claude/hooks/route-to-tdd.sh` — UserPromptSubmit advisory router.
- `.claude/hooks/gofmt-after-edit.sh` — auto-format.
- `.claude/hooks/detect-ai-bloat.sh` — AI-bloat advisory.
- `.claude/hooks/session-context.sh` — session start orientation.
- `.tdd/templates/*.md` — feature-plan, bugfix-plan, red-proof skeletons.
- `scripts/check-tdd-ceremony.sh` — CI red-before-green check.
- `scripts/check-tdd-state-clean.sh` — CI dirty-state check.
- `scripts/check-allowed-modules.sh` — CI slopsquat check.
- `scripts/doctor.sh` — tool inventory.
- `scripts/tdd-test-hooks.sh` — hook smoke test.

If any of these already exist in your project, **back them up** to
`/tmp/old-hooks-backup/` and then replace with ours. Do not try to
mix-and-match logic inside one script — take the whole file.

### Always KEEP YOURS (project-specific)

- Project domain rules in `CLAUDE.md` (your business invariants,
  your domain model, your team conventions).
- Project-specific reviewer agents (e.g. `order-reviewer`,
  `payment-reviewer`, `auth-reviewer` for your specific service).
- Project-specific skills (e.g. `replay-restarter`,
  `backtest-runner` — workflows that only make sense for your
  project).
- Project-specific path-scoped rules (e.g. `paths/internal/orders.md`
  — rules that apply only when editing that path).
- Your CI jobs that test your specific business logic.
- Your `go.mod`, your code, your tests, your migrations.

### MERGE these

#### `CLAUDE.md`

Our `CLAUDE.md` has generic Go rules. Your `CLAUDE.md` has project
rules. Merge by section:

```markdown
# CLAUDE.md — <Your Project Name>

## Project context              <- KEEP YOURS
... your project description ...

## Two workflow modes          <- TAKE OURS
... Tier 1 vs other ...

## Project-specific rules      <- KEEP YOURS
... business invariants ...

## Go quality rules (always)   <- TAKE OURS, then add yours
... ours ...
... your additions ...

## Testing rules               <- TAKE OURS
...

## Skills available            <- MERGE: ours + yours
- (our 13 skills)
- replay-restarter (yours)
- backtest-runner (yours)

## Reviewer agents available   <- MERGE: ours + yours
- (our 6 agents)
- order-reviewer (yours)
- payment-reviewer (yours)
```

After merge, copy `CLAUDE.md` to `AGENTS.md` (or set up the CI sync
check from `.gitlab-ci.yml`):

```bash
cp CLAUDE.md AGENTS.md
```

#### `.claude/settings.json`

Take ours as the base. Then add any **extra** entries from yours:

- `permissions.allow` — add your project's safe Bash commands
  (e.g. `Bash(make migrate)`, `Bash(./scripts/replay *)`).
- `permissions.ask` — add anything risky-but-needed for your project.
- `permissions.deny` — keep all of ours, add any project-specific
  denies.
- `hooks` section — keep all of ours. Add your project hooks AFTER
  ours (so ours run first as the safety floor).

**Do not** weaken our `permissions.deny` list. Do not add
`enableAllProjectMcpServers: true` (CVE-2025-59536).

#### `.tdd/tdd-config.json`

Start from `.tdd/presets/service.json` (or `library.json` / `cli.json`
depending on your project type). Then:

- Add your project-specific Tier 1 paths to `tier1_path_regexes`.
  Example: `(^|/)internal/orders/.*\\.go$` for an orders service.
- Add your project-specific keywords to `tier1_prompt_keywords`.
  Example: `"order"`, `"fill"`, `"position"` for a trading bot.
- Set `project_name` to your real project name.

#### `.claude/allowed-modules.txt`

Take ours as the base. Then:

- Add your org/group prefix as the first line. Example:
  `gitlab.your-domain.com/your-team/`.
- Add any extra modules your project uses that are not on the
  default list.

Verify on `pkg.go.dev` that every module is real before adding.

#### `.claude/rules/`

Take all 9 of our rule files. Add your own project-domain rule files
(e.g. `orders.md`, `auth.md`). Reference them from your merged
`CLAUDE.md`.

#### `.claude/agents/`

Take all 6 of our reviewer agents. Add your project-specific agents
(e.g. `order-reviewer.md`). Reference them from your merged
`CLAUDE.md`.

#### `.claude/skills/`

Take all 13 of our skills. Add your project-specific skills with
their own `SKILL.md` files. Apply the same description-quality rules
(see `.claude/skills/specify/SKILL.md` and any of our other skills as
templates).

#### `.golangci.yml`

If you do not have a v2 lint config: take ours as-is.

If you have a v1 config: take ours and add your project-specific
linter overrides under the v2 structure (`linters.settings.<name>`,
`linters.exclusions.rules`). Do not mix v1 and v2 keys (this is the
exact bug v1.1.1 fixed in our pack).

#### `Makefile`

If you have a Makefile: keep yours, add any of our targets you do not
have (`doctor`, `tdd-test`, `tools`, `ci`). If our `deadcode` target
clashes with yours, prefer the version with `DEADCODE_ALLOW_FAILURE`
support.

#### CI files (`.gitlab-ci.yml` or `.github/workflows/ci.yml`)

Take ours as the base. Then add your project-specific CI jobs (build,
deploy, integration tests, etc.) as additional jobs. Make sure these
new jobs are not blocking our safety jobs — keep `tdd-state-clean`,
`tdd-ceremony-check`, `allowed-modules`, `agents-md-sync` as
required.

---

## Step 5 — Step-by-step merge

Do this on the integration branch.

```bash
# In your project, on the integration branch.
cd /path/to/your-project

# 1. Back up your current setup so you can compare or revert.
mkdir -p /tmp/integration-backup
cp -r .claude .mcp.json CLAUDE.md AGENTS.md REVIEW.md \
      .gitlab-ci.yml .github .golangci.yml Makefile \
      scripts /tmp/integration-backup/ 2>/dev/null || true

# 2. Copy each of our files in. For files that need merging,
#    edit in place after the copy.

REF=/tmp/go-claude-starter-ref

# Files to take wholesale (security-critical):
mkdir -p .claude/hooks .tdd/templates .tdd/presets scripts docs/process
cp $REF/.claude/hooks/*.sh           .claude/hooks/
cp $REF/.tdd/templates/*.md          .tdd/templates/
cp $REF/.tdd/presets/*.json          .tdd/presets/
cp $REF/scripts/check-tdd-ceremony.sh \
   $REF/scripts/check-tdd-state-clean.sh \
   $REF/scripts/check-allowed-modules.sh \
   $REF/scripts/doctor.sh \
   $REF/scripts/tdd-test-hooks.sh \
   $REF/scripts/install-go-tools.sh \
   $REF/scripts/changed-go-files.sh \
   $REF/scripts/check-deadcode.sh \
   $REF/scripts/ci-go.sh             scripts/
cp $REF/docs/process/tdd_workflow.md docs/process/
chmod +x .claude/hooks/*.sh scripts/*.sh

# Files to take as base, then merge yours into:
#    .claude/settings.json
#    .claude/allowed-modules.txt
#    .tdd/tdd-config.json
#    CLAUDE.md
#    AGENTS.md
#    REVIEW.md
#    .gitlab-ci.yml or .github/workflows/ci.yml
#    .golangci.yml
#    Makefile
#
# For each, open both versions side by side and merge by hand.

# 3. Take our reviewer agents AND skills (do not lose yours):
cp -r $REF/.claude/agents/*.md  .claude/agents/   # add ours alongside yours
cp -r $REF/.claude/skills/*     .claude/skills/   # add ours alongside yours
cp -r $REF/.claude/rules/*.md   .claude/rules/    # add ours alongside yours

# 4. Pick the right TDD preset for your project type.
#    Service is the default; switch if needed:
# cp .tdd/presets/library.json .tdd/tdd-config.json
# cp .tdd/presets/cli.json     .tdd/tdd-config.json

# 5. If you do not have one yet, copy our state file:
cp $REF/.tdd/current-plan.md .tdd/current-plan.md

# 6. Set version and check.
cp $REF/.claude/VERSION .claude/VERSION

# 7. Make sure AGENTS.md is byte-identical to CLAUDE.md.
cp CLAUDE.md AGENTS.md
```

---

## Step 6 — Test the merge

```bash
# 1. JSON files all parse.
for f in $(find . -name '*.json' -not -path './.git/*'); do jq empty "$f"; done

# 2. Shell scripts have no syntax errors.
for f in .claude/hooks/*.sh scripts/*.sh; do bash -n "$f"; done

# 3. YAML files all parse.
python3 -c "import yaml; [yaml.safe_load(open(f)) for f in ['.gitlab-ci.yml','.github/workflows/ci.yml','.golangci.yml']]"

# 4. AGENTS.md mirrors CLAUDE.md.
diff CLAUDE.md AGENTS.md > /dev/null && echo OK

# 5. Required tools are installed.
make doctor

# 6. Hook smoke tests pass (target 27/27).
make tdd-test

# 7. Try a dangerous command — should be denied.
echo '{"tool_input":{"command":"git commit --no-verify"}}' \
  | bash .claude/hooks/guard-dangerous-bash.sh \
  | jq -r '.hookSpecificOutput.permissionDecision'
# Expected: deny

# 8. Try a Tier 1 path edit — should be blocked (no plan file with
#    approvals yet).
echo '{"tool_input":{"file_path":"internal/payments/charge.go"}}' \
  | bash .claude/hooks/require-tdd-state.sh
echo "exit code: $?"
# Expected: exit 2 with a <claude-directive> message
```

If anything fails, stop and fix before going further.

---

## Step 7 — Open a CI run

```bash
git add -A
git commit -m "chore: integrate go-claude-starter v1.2.0"
git push -u origin chore/integrate-go-claude-starter
```

Open the merge request / pull request. CI should run:

- `fmt-vet`
- `agents-md-sync`
- `test`
- `staticcheck`
- `deadcode` (advisory)
- `allowed-modules`
- `govulncheck`
- `golangci-lint`
- `tdd-ceremony-check` (only fires if you touched a Tier 1 path)
- `tdd-state-clean`

Fix anything red. Most common first-time issues:

| Symptom | Likely cause | Fix |
|---|---|---|
| `allowed-modules` fails | Your existing `go.mod` requires modules not on our default allowlist | Add the module prefixes to `.claude/allowed-modules.txt` after verifying each on `pkg.go.dev` |
| `golangci-lint` fails on settings | Your old v1 config keys clashed with our v2 keys | Re-read Step 4 → `.golangci.yml` section |
| `agents-md-sync` fails | You edited `CLAUDE.md` after the integration commit | `cp CLAUDE.md AGENTS.md && git commit --amend` |
| `tdd-ceremony-check` fails | You touched a Tier 1 path without the `red(<id>):` → `green(<id>):` pattern | Either redo the work as a proper TDD cycle, or document the bypass in the MR description (see `docs/process/tdd_workflow.md` "Bypass procedure") |
| Hook says "jq missing" | jq is not in CI image | Add `apk add --no-cache jq` (Alpine) or `apt-get install -y jq` (Debian) to your CI before the hook step |

---

## Step 8 — Tell your team

After the merge lands on `main`, tell your team:

- "We integrated `go-claude-starter v1.2.0`."
- "Read `CLAUDE.md` — there are new rules for Tier 1 paths."
- "If your edit gets blocked by `[require-tdd-state]`, read
  `docs/process/tdd_workflow.md` — you need to use the
  `go-tdd-feature` or `go-tdd-bugfix` skill."
- "First time you run `claude`, accept the gopls MCP approval prompt
  once."
- "Run `make doctor` to check your local tools."

---

## When to re-integrate

This starter is not a plugin. Updates do not flow in automatically.

Plan to re-integrate every quarter:

1. `git fetch` the starter repo at `/tmp/go-claude-starter-ref`.
2. Read its `CHANGELOG.md` (or `git log`) since your last
   integration.
3. Compare changed files. Apply the changes that matter to your
   project.
4. Bump `.claude/VERSION` in your project to match.
5. Run all 8 tests from Step 6.
6. Open a "chore: refresh go-claude-starter to vX.Y.Z" MR.

---

## When NOT to use this starter

- Your project is not in Go (use a sibling starter like
  `py-claude-starter` or write your own).
- Your project has no Claude Code use (this starter is only useful
  with Claude Code).
- Your project is a tiny throwaway script (the ceremony cost is too
  high for the value).

---

## Questions to ask the team if unclear

- Which CI platform do we use — GitLab or GitHub Actions? (Pick one,
  delete the other.)
- What is our org/group module prefix for `allowed-modules.txt`?
- Which paths in our project are Tier 1 (high stakes)?
- Do we have project-specific reviewer agents that should run
  alongside the generic ones?
- Do we have any local tools or shell aliases that should be in the
  permission allow list?
- Who owns `.claude/hooks/` updates? (Usually the team lead or
  security champion.)

---

## Help

If something is unclear:

- Re-read the file mentioned in the table at the top.
- Open the matching file in `/tmp/go-claude-starter-ref` and compare
  with your project.
- Ask in the team chat with a link to the specific file or rule.
