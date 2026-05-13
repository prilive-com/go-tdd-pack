# AI Developer Guide — go-claude-starter

Onboarding for engineers who use AI assistants (Claude Code, Codex,
similar) to build Go services and want a structured, governance-aware
workflow. This guide takes you from zero install to a complete first
TDD cycle in under an hour.

For deeper dives on any topic, see the linked references at the end of
each section.

---

## What this starter gives you

A pre-wired Go project layout where AI assistants behave predictably:
- **Hooks** intercept dangerous bash, secret leaks, and policy
  violations before they reach disk.
- **TDD ceremony** with three explicit operator approval gates on
  high-stakes paths (auth, money, migrations) — no silent edits to
  business-critical code.
- **`/second-opinion`** runs cross-model code review (Codex via
  ChatGPT) on every Tier 1 cycle.
- **Skills** drive the AI through proven workflows
  (`go-tdd-feature`, `go-tdd-bugfix`, `migration-review`, etc.) so
  you don't reinvent the loop each time.
- **Reviewer subagents** (security, architecture, concurrency,
  test-quality) provide focused critique on demand.
- **Typed test-edit exceptions** (v1.7.0) and **AST-backed
  validation** (v1.8.0) close the "AI weakens a test to make it
  pass" failure mode.

You stay in charge — the operator approves spec, red-proof, green
implementation. The AI proposes; you accept. Every gate is documented
in stderr; nothing is hidden.

---

## What this is NOT

Setting expectations early so you don't go install something that
solves a different problem:

- **Not a CI replacement.** The pack ships a sample
  `.github/workflows/ci.yml` and `.gitlab-ci.yml`, but they're
  starting points — you keep your own CI, your own deploy
  pipeline, your own secret store.
- **Not a Claude Code replacement.** The pack RUNS INSIDE Claude
  Code (and Codex via the `second-opinion` skill). You still need
  the upstream client installed and authenticated.
- **Not a binary distribution.** Everything is bash + Go source.
  The AST validator runs via `go run` (v1.9 will detect a
  pre-built binary); no `make install`, no `go install` for the
  starter itself.
- **Not multi-language.** Go-only. Python / TS / Rust starters
  are sibling projects (`py-claude-starter`, etc.); this one
  ships Go-specific rules (`go-style.md`, `go-pgx.md`) and a
  Go AST helper.
- **Not architecture enforcement.** Tier 1 paths get TDD
  ceremony, but the pack doesn't enforce hexagonal /
  clean / DDD layouts. Use `integration_guards` in
  `.tdd/tdd-config.json` for project-specific "no API X outside
  layer Y" rules.
- **Not a reviewer-bot replacement.** `/second-opinion` is a
  cross-model sanity check, not a substitute for human code
  review. Reviewer subagents (`go-reviewer`, `go-architect`,
  etc.) supplement, don't replace, your team's review process.
- **Not protection against a compromised host.** Hooks + audit
  chain detect operator mistakes and AI overreach. They do NOT
  defend against an attacker with shell access — that's an OS /
  infra concern.
- **Not a Linux-only pack.** Tested on Linux + macOS. Windows
  (native) is unsupported; use WSL.

---

## Prerequisites (5 minutes)

Required (without these, hooks fail closed loudly — `make doctor`
verifies):

| Tool | Why | Install |
|---|---|---|
| **Claude Code** ≥ 2.1.89 | The AI client. Earlier versions treat hook `permissionDecision: defer` as `allow` — defeats guardrails. | https://claude.com/claude-code |
| **Go** ≥ 1.26.2 | Required for `go fix` modernize, AST validator (v1.8.0), `testing.TB.Context()`. | https://go.dev/dl/ |
| **bash** | Hook runtime. macOS ships 3.2; install bash 5+ via brew. | `brew install bash` |
| **jq** | All hooks use jq for JSON parsing. | `brew install jq` / `apt install jq` |
| **git** | Version control + audit anchoring. | (system) |

Recommended (full enforcement):

| Tool | Why | Without it |
|---|---|---|
| `gopls` | Go language server (MCP integration) | No language-server features in Claude |
| `goimports` | Import management | `gofmt-after-edit.sh` skips import fixes |
| `golangci-lint` | Lint coverage | CI lint stage is skipped |
| `staticcheck` | Static analysis | Subset of golangci-lint runs |
| `govulncheck` | CVE scanning | CVE check skipped |
| `gitleaks` | Content-based secret scanning | Falls back to narrow regex set |
| `codex` (Codex CLI) | `/second-opinion` cross-model review | Skill exits 0 with stderr warning |

Run `make doctor` after install to see what's missing.

---

## Install (one of two paths)

### Path A — New project from this starter (5 minutes)

```bash
git clone --depth 1 https://gitlab.your-domain.com/your-group/go-claude-starter.git my-service
cd my-service
rm -rf .git
go mod init github.com/your-org/my-service
git init
git add .
git commit -m "chore: bootstrap from go-claude-starter v1.8.0"
```

Customize:
- `.tdd/tdd-config.json` — set `project_name` and edit
  `tier1_path_regexes` to match YOUR high-stakes paths.
- `.claude/allowed-modules.txt` — first line should be your
  org/group prefix (slopsquat allowlist).
- `README.md` — replace the `<project-name>` placeholders.
- Pick one CI: `rm -rf .github/` (GitLab) or `rm .gitlab-ci.yml`
  (GitHub).

Verify:
```bash
make doctor                  # tools check
bash scripts/tdd-test-hooks.sh   # smoke (target: 520 passed, 0 failed)
```

### Path B — Adopt into an existing project

For an existing repo with its own `.claude/` (rules, skills, hooks),
follow [`docs/INTEGRATION_GUIDE.md`](INTEGRATION_GUIDE.md) — it covers
the merge path without losing what already works.

For an existing repo with NO `.claude/`, follow
[`docs/ADOPTION_GUIDE.md`](ADOPTION_GUIDE.md) Step 1-5 (copy + set
project name + calibrate Tier 1 + verify + commit).

---

## First-run note (important)

The starter ships a project-scoped MCP server (`gopls`) at `.mcp.json`.
Per Anthropic's CVE-2025-59536 fix, Claude Code requires explicit
**one-time user approval** before running any project MCP server.

The first time you run `claude` in this directory, accept the gopls
approval prompt (or run `/mcp` to enable manually). After that, gopls
loads automatically.

---

## Repository layout

```
.
├── CLAUDE.md            # Operating rules (auto-loaded by Claude Code)
├── AGENTS.md            # Codex / cross-agent rules
├── REVIEW.md            # Staff+ review rubric (used by go-reviewer agent)
├── .mcp.json            # Project MCP servers (gopls). MUST be at repo root.
├── Makefile             # `make doctor` / `make ci` / `make tdd-test`
│
├── .claude/             # Auto-loaded by Claude Code
│   ├── settings.json    # Permissions + hook registration + MCP allowlist
│   ├── rules/           # Loaded on demand from CLAUDE.md
│   ├── agents/          # Reviewer subagents (auto-discovered)
│   ├── skills/          # Workflow skills (invocable via /<skill-name>)
│   └── hooks/           # Safety + TDD enforcement hooks
│
├── .tdd/                # TDD ceremony state machine
│   ├── tdd-config.json     # Tier 1 path regexes + required markers + caps
│   ├── current-plan.md     # Active cycle (git-tracked)
│   ├── red-proof.md        # Captured failing-test output (gitignored)
│   ├── green-proof.md      # Captured passing-test output (gitignored)
│   ├── second-opinion-completed.md   # Codex review adjudication (gitignored)
│   ├── exceptions/         # Per-cycle typed test-edit exceptions (gitignored)
│   ├── audit/              # Sha-chained audit log (gitignored)
│   ├── codex/              # Per-round /second-opinion JSON output (gitignored)
│   └── templates/          # feature-plan / bugfix-plan / red-proof / ...
│
├── scripts/             # CI utilities + TDD smoke tests + AST helper
│   ├── doctor.sh
│   ├── tdd-test-hooks.sh   # 520-test smoke suite
│   └── tdd/
│       ├── ast/validator.go         # v1.8.0 Go AST helper
│       ├── grant-test-edit-exception.sh
│       ├── verify-audit-chain.sh
│       └── _lib_*.sh                # validator + commit-mode shared libs
│
├── specs/               # Layer 0 spec gate (Specify → Plan → Tasks)
├── docs/                # This guide + ADOPTION/INTEGRATION/process/specs
├── .github/workflows/   # GitHub Actions (delete if GitLab)
├── .gitlab-ci.yml       # GitLab CI (delete if GitHub)
└── .golangci.yml        # Lint config
```

The `.claude/` directory is auto-loaded — no `pre-commit install`,
no bootstrap script. Hooks register themselves via `settings.json`.

---

## Setup: configure your project (10 minutes)

### 1. Set the project name

```jsonc
// .tdd/tdd-config.json
{
  "project_name": "my-service",
  ...
}
```

This shows up in audit logs and hook deny messages.

### 2. Calibrate Tier 1 paths

Tier 1 = paths that get the FULL TDD ceremony (3 operator gates,
mandatory `/second-opinion`, AST-validated test edits). Edit
`tier1_path_regexes` in `.tdd/tdd-config.json` to match YOUR
high-stakes paths.

Default covers (edit to taste):
- Money / billing / capital / accounting
- Auth / authorization / RBAC / sessions / tokens
- Migrations (any `*.sql` in `migrations/`)
- Database / repository / transaction code
- Notifications (webhook / email / SMS)
- Reconciliation / orchestration in `internal/app/`

If you have NO high-stakes paths (e.g., a CLI helper, static-site
generator), set `tier1_path_regexes: []`. The pack still protects
against secrets, dangerous bash, and force-push — TDD ceremony just
doesn't fire anywhere.

**Don't add paths that don't actually need ceremony.** Friction
backfires when applied indiscriminately. Pick paths where a silent
regression would cause real damage.

Three presets in `.tdd/presets/` for quick switches:
```bash
cp .tdd/presets/library.json .tdd/tdd-config.json   # SDK / library
cp .tdd/presets/cli.json     .tdd/tdd-config.json   # CLI tool
cp .tdd/presets/service.json .tdd/tdd-config.json   # Service (default)
```

### 3. Slopsquat allowlist

Edit `.claude/allowed-modules.txt`. First line = your org/group
prefix (e.g., `github.com/your-org/`). The CI step
`check-allowed-modules.sh` rejects `go.mod` requires from outside
the allowlist — protects against AI suggesting a typo'd or malicious
package.

### 4. (Optional) Enable v1.8.0 features

Defaults are conservative. Opt-in via `.tdd/tdd-config.json`:

```jsonc
"test_file_policy": {
  "post_red_mechanical_update": {
    "enabled": true,                      // turn on typed test-edit exceptions
    "max_per_cycle": 5,                   // 0 = no cap
    "exception_types": [
      "mechanical_signature_propagation",
      "compile_fix_only",
      "import_only",
      "schema_predicate_correction"       // v1.8.0; opt-in
    ]
  }
}
```

When `enabled: false` (the default), the legacy
`allow_after_red_confirmed` boolean is the only post-red bypass.
When `enabled: true`, operators grant per-cycle typed exceptions
that the AST validator enforces. See "Typed test-edit exceptions"
below.

### 5. Verify install (diagnostic runbook)

Run these from repo root, in order. Each command's expected output
is shown; the next command tells you what to do if the previous
failed.

```bash
# 1. Tools check.
make doctor
# Expect: every required tool reported FOUND. If any MISSING,
# install via the table in "Prerequisites" above.

# 2. Hook scripts parse.
for f in .claude/hooks/*.sh scripts/tdd/*.sh scripts/tdd/ast/*.sh; do
  bash -n "$f" 2>&1 | grep -v '^$'
done
# Expect: no output. If errors, your bash is too old (need 5+);
# `brew install bash` and re-source.

# 3. JSON config parses.
jq empty .tdd/tdd-config.json && jq empty .claude/settings.json
# Expect: no output. If parse error, fix the JSON file named in
# the error.

# 4. AST helper compiles + runs.
go run scripts/tdd/ast/validator.go --version
# Expect: "tdd-ast-validator v1.8.0".
# If error, Go is missing or < 1.26.2 — install per Prerequisites.

# 5. Smoke suite.
bash scripts/tdd-test-hooks.sh 2>&1 | tail -3
# Expect: "Results: 520 passed, 0 failed".
# If any FAIL, run with grep:
#   bash scripts/tdd-test-hooks.sh 2>&1 | grep -E '^\s*FAIL:' | head -5

# 6. Hooks register correctly.
jq -r '.hooks // {} | keys[]' .claude/settings.json
# Expect: SessionStart, PreToolUse, PostToolUse (subset OK).
# If empty, you copied .claude/ incompletely.

# 7. (Optional) Codex CLI for /second-opinion.
codex --version 2>&1 | head -1 && codex auth status 2>&1 | head -1
# Expect: version + an auth status line. If "not authenticated",
# run `codex login` (ChatGPT auth) OR set CODEX_API_KEY.
# Without Codex, /second-opinion exits 0 with stderr warning;
# the pack still works without it.

# 8. (Optional) gopls MCP loads.
# Run `claude` once in the project root and accept the gopls
# approval prompt (CVE-2025-59536 mitigation). After that, gopls
# loads automatically in subsequent sessions.
```

If steps 1-6 all pass, install is good. Steps 7-8 are
recommended-but-optional.

### 6. Commit

```bash
git add .claude .tdd scripts docs .gitlab-ci.yml .github/ .golangci.yml Makefile
git commit -m "chore: adopt go-claude-starter v1.8.0"
```

---

## Daily use: the four common workflows

### Workflow 1 — Tier 1 cycle (full TDD ceremony)

This is what fires when you ask Claude to change a Tier 1 path
(e.g., `internal/auth/handler.go`).

**Phase 1: Spec.** Claude invokes `go-tdd-feature` (or
`go-tdd-bugfix`) skill, which copies a template into
`.tdd/current-plan.md` and asks you to fill in the spec sections.
Then it pauses with: *"Reply APPROVED SPEC to authorize red phase."*

You read the plan, push back if wrong, and reply `APPROVED SPEC`
when satisfied. Claude sets `Human approved spec: yes` in the plan.

**Phase 2: Red.** Claude writes failing acceptance tests, runs
them, captures verbatim output to `.tdd/red-proof.md`, sets
`Red phase confirmed: yes`. It pauses again with: *"Reply APPROVED
RED to authorize green phase."*

You read the red-proof to confirm tests fail for the right reason.
Reply `APPROVED RED, go ahead with green`.

**Phase 3: Green.** Claude writes the production code. Tests
transition RED → GREEN. Captures `.tdd/green-proof.md`. Then runs
`/second-opinion diff` for cross-model review. Codex returns JSON
findings; Claude writes adjudication to
`.tdd/second-opinion-completed.md`. The cycle iterates: each P0/P1
finding gets a RED test that reproduces the bypass, then a fix that
transitions it to GREEN. When findings stabilize (or you say stop),
Claude pauses with: *"Reply APPROVED IMPLEMENTATION to authorize
commit."*

You read the disposition matrix at `.tdd/disposition-matrix.md`,
confirm the trade-offs, and reply `APPROVED IMPLEMENTATION`.

**Phase 4: Commit.** Claude runs `git commit`. The commit gate
(`gate-tier1-commit.sh`) validates all four markers + green-proof +
fresh adjudication. If any fail, commit is rejected with a specific
fix in the deny message.

Total elapsed: 30-90 minutes per cycle including thinking time.
The friction is the point — you reserve it for paths where a
silent regression would matter.

For deep workflow detail: [`docs/process/tdd_workflow.md`](process/tdd_workflow.md).

### Workflow 2 — Non-Tier-1 change (light discipline)

Edits to `cmd/`, `pkg/`, `web/`, `docs/`, etc. — anything NOT
matching `tier1_path_regexes`. Standard Go discipline applies:
formatters, linters, race detector, normal review. No TDD ceremony,
no `/second-opinion`. The `minimal-go-change` skill auto-fires
nudging Claude toward smaller diffs.

You can still invoke any skill manually:
```
/specify              # Layer 0 spec gate (Specify → Plan → Tasks)
/go-test-writer       # Generate tests for an existing function
/go-modernize         # Apply Go 1.26+ modernizations (go fix)
/migration-review     # Review a SQL migration for safety
/postmortem-fix       # Capture an incident as a TDD cycle
```

Just type the slash command in Claude.

### Workflow 3 — `/second-opinion` cross-model review

Runs the Codex CLI as a read-only external reviewer. Two modes:

```
/second-opinion plan       # Reviews .tdd/current-plan.md
/second-opinion diff       # Reviews `git diff HEAD`
/second-opinion file <p>   # Reviews a specific file
/second-opinion question "<text>"   # Asks Codex a question
```

Auto-fires before Tier 1 implementation and again on the green-phase
diff. You can also invoke manually before risky operations
(migrations, refactors, security-sensitive PRs).

What gets sent to OpenAI: first 200 lines of `CLAUDE.md` (redacted)
+ the target (plan/diff/file) (redacted). What stays local: full
repo, all hooks, all rules. See [`/second-opinion` skill
docs](../.claude/skills/second-opinion/SKILL.md) for the full data
flow + redaction patterns.

### Workflow 4 — Typed test-edit exceptions (v1.7.0+)

When Claude needs to edit a test file AFTER `Red phase confirmed:
yes`, the hook denies by default (the documented "don't edit tests
in green phase" rule). For LEGITIMATE mechanical updates (call-site
propagation when a signature widens, struct field renames, import
shuffles), there's an authorized escape.

**Workflow:**

1. Claude detects the need:
   ```
   "Widening Reconcile() to (Result, error) — 12 test call sites
    need mechanical updates. Need a mechanical_signature_propagation
    exception."
   ```

2. Claude runs the grant helper to create a PENDING entry:
   ```bash
   scripts/tdd/grant-test-edit-exception.sh \
     --type mechanical_signature_propagation \
     --paths "internal/modules/capital/**/*_test.go" \
     --symbol Reconcile \
     --operations edit_existing_tests \
     --reason "PR4 widens Reconcile to (Result, error); 12 call sites need updates"
   ```

3. Claude surfaces the entry to YOU and asks `APPROVED EXCEPTION
   E-001?`. You read the scope and reason, push back if wrong.

4. You reply `APPROVED EXCEPTION E-001` (batch syntax: `APPROVED
   EXCEPTIONS E-001, E-002` or `APPROVED EXCEPTIONS E-001 through
   E-005`).

5. Claude approves the entry:
   ```bash
   scripts/tdd/grant-test-edit-exception.sh --approve E-001
   ```
   (Computes binding hashes; appends `granted` event to
   `.tdd/audit/<cycle-id>.jsonl` with `prev_sha`-chained integrity.)

6. Hook now allows test edits matching the scope. The validator
   library (regex + AST AND-gate) verifies each edit:
   - **edit_existing_tests** → no assertion-helper changes, no test
     deletions, no empty `t.Run` additions.
   - **create_new_tests** → file must contain `func TestXxx(...)` AND
     at least one assertion.
   - **import_only** → only changes inside import declarations.
   - **schema_predicate_correction** (v1.8.0) → AST-validated pure
     rename of `--old-name` → `--new-name`; any other change rejects.

7. Auto-expiry on next git commit (HEAD-bound; `binding.head_at_approval`).

**Killswitches:**
- `TEST_EDIT_EXCEPTION_DISABLE=1` — bypass entire system.
- `TDD_AST_VALIDATOR_DISABLE=1` — fall back to regex-only validation.

Both honor-system; document use in commit message.

For full design: [`docs/specs/typed-test-edit-exceptions-v1.7.0-spec.md`](specs/typed-test-edit-exceptions-v1.7.0-spec.md)
and [`docs/specs/ast-validator-and-audit-integrity-v1.8.0-spec.md`](specs/ast-validator-and-audit-integrity-v1.8.0-spec.md).

---

## What the AI sees vs. what you see

| Surface | Auto-loaded by AI | Triggered by AI | Visible to operator |
|---|---|---|---|
| `CLAUDE.md` | ✓ every conversation | — | yes |
| `AGENTS.md` | ✓ for Codex / cross-agent | — | yes |
| `.claude/rules/*.md` | on-demand (referenced from CLAUDE.md) | — | yes (read-only) |
| `.claude/skills/*/SKILL.md` | discovered as `/skill-name` | yes (when invoked) | yes (read-only) |
| `.claude/agents/*.md` | discovered as Task subagents | yes (auto or manual) | yes (read-only) |
| `.claude/hooks/*.sh` | runtime via `settings.json` | — | hooks emit stderr to operator |
| `.tdd/current-plan.md` | read by hooks | written by skills | yes (operator approves changes) |
| `.tdd/exceptions/*.json` | read by hooks + grant helper | written by grant helper | yes (gitignored; operator's local) |
| `.tdd/audit/*.jsonl` | read by hooks | written by grant helper | yes (gitignored; sha-chained) |

**Key principle**: AI proposes; operator approves. Every gate
prints to stderr; nothing happens silently.

---

## Stable error codes (stderr deny messages → operator action)

When a hook denies, the stderr output starts with a stable prefix.
Match the prefix to the operator action:

| Stderr prefix / phrase | Source | Operator action |
|---|---|---|
| `[require-tdd-state] BLOCKED edit to Tier 1 high-stakes path(s):` | `require-tdd-state.sh` | Read the `<claude-directive>` block; reply with the missing APPROVED marker, OR set `Red phase confirmed: yes` after capturing red-proof. |
| `[require-tdd-state] BLOCKED edit to Tier 1 test file(s) after red phase confirmed:` | `require-tdd-state.sh` | Either grant a typed exception (see "Workflow 4") OR return to red phase explicitly. |
| `[require-tdd-state] BLOCKED: audit log missing or empty` | `require-tdd-state.sh` (v1.8.0 AC5) | Audit log was deleted/truncated. Re-run grant helper to regenerate, OR investigate suspected tamper. |
| `[require-tdd-state] BLOCKED: audit log missing 'granted' event(s)` | `require-tdd-state.sh` (v1.8.0 round-7 F3) | Approved exception ID has no matching grant in audit log. Operator tampered with log OR a grant failed silently. Re-run `grant-test-edit-exception.sh --approve E-NNN`. |
| `[require-tdd-state] BLOCKED: audit-log chain integrity check failed` | `verify-audit-chain.sh` (v1.8.0 AC5) | Sha-chain mismatch detected. Audit log was edited mid-cycle. Investigate; cannot proceed without operator review. |
| `[require-tdd-state] BLOCKED: max_per_cycle exceeded` | `require-tdd-state.sh` (v1.8.0 AC4) | Over-cap on approved exceptions. Either revert to red phase + re-spec OR raise `max_per_cycle` in `.tdd/tdd-config.json` with documented reason in commit. |
| `[require-tdd-state] DEPRECATED: test_file_policy.allow_after_red_confirmed` | `require-tdd-state.sh` (v1.7.0 AC7) | Migrate to typed exceptions before v2.0.0. Warning is rate-limited (one per hook invocation). |
| `[lib_test_edit_exception] AST REPORT (subcmd=...):` | `_lib_test_edit_exception.sh` (v1.8.0) | AST validator rejected the edit. Read the JSON report on stderr — it names the file, line, and reason. Common: helper-shape changed in `mech_sig_prop`, off-scope identifier in `compile_fix_only`, non-rename in `schema_predicate_correction`. |
| `[lib_test_edit_exception] WARN: TDD_AST_VALIDATOR_DISABLE=1` | `_lib_test_edit_exception.sh` (v1.8.0 AC6) | Killswitch active; regex-only validation. Document in next commit message. |
| `[lib_test_edit_exception] WARN: Go unavailable` | `_lib_test_edit_exception.sh` (v1.8.0 AC6) | Go binary not on PATH. Install Go ≥ 1.26.2 for stricter governance, or accept regex-only fallback. |
| `[lib_test_edit_exception] BLOCKED: schema_predicate_correction: ast_required` | `_lib_test_edit_exception.sh` (v1.8.0 round-2 F1) | This exception type has NO regex fallback. Install Go OR pick a different exception type (`mechanical_signature_propagation`, `compile_fix_only`, `import_only`). |
| `[require-second-opinion] BLOCKED:` | `require-second-opinion.sh` | `/second-opinion` was not run for this Tier 1 cycle, OR the adjudication is stale (>60min). Re-run `/second-opinion diff`. |
| `[guard-dangerous-bash] BLOCKED:` | `guard-dangerous-bash.sh` | The bash command matched a deny pattern (`--no-verify`, `terraform destroy`, force-push, etc.). Ask operator if the action is intended. |
| `[scan-for-secrets] BLOCKED:` | `scan-for-secrets.sh` | Content matched a secret pattern (AWS key, GitHub token, JWT, etc.). Remove the secret OR scrub it from the diff. |
| `[guard-protected-files] BLOCKED:` | `guard-protected-files.sh` | Edit to a path protected by `.claude/settings.json` `permissions.deny`. Operator must explicitly authorize. |
| `[gate-tier1-commit] BLOCKED:` | `gate-tier1-commit.sh` | Commit-time validation failed (missing M4, stale adjudication, etc.). Address the specific cause from the deny message. |
| `PLAN_REVIEW_REQUIRED` | `second-opinion-plan-trigger.sh` (v1.9.0 AC4) | Plan write blocked. Run `scripts/tdd/run-second-opinion.sh plan_review <cycle-id>`. |
| `TEST_REVIEW_REQUIRED` | `second-opinion-test-trigger.sh` (v1.9.0 AC5) | Test write blocked. Run `scripts/tdd/run-second-opinion.sh test_review <cycle-id>`. |
| `PRODUCTION_EDIT_REVIEW_REQUIRED` | `second-opinion-production-trigger.sh` (v1.9.0 AC6) | First production .go edit per `base_git_sha`. Run `scripts/tdd/run-second-opinion.sh production_edit <cycle-id>`; subsequent edits in the cycle unblock. |
| `PRODUCTION_SCOPE_DRIFT` | `second-opinion-production-trigger.sh` (v1.9.0 AC6) | File outside the completion's recorded scope. Run a fresh review OR split the change. |
| `REVIEW_SCOPE_MISMATCH` | trigger hooks (v1.9.0) | `scope_hash` differs from completion — proposed content changed. Re-review. |
| `REVIEW_COMPLETION_EXPIRED` | trigger hooks (v1.9.0) | Completion was for an older `base_git_sha`. HEAD advanced. Re-review. |
| `CODEX_OUTPUT_NON_CONFORMANT` | `run-second-opinion.sh` (v1.9.0 AC3) | Codex output failed jq schema validation after retries. Check `.tdd/codex/` logs; may indicate `--output-schema` silently ignored (openai/codex#15451 with MCP, or #4181 codex-family). |
| `MODEL_NOT_SCHEMA_COMPATIBLE` | `run-second-opinion.sh` (v1.9.0 AC3) | Configured model silently drops `--output-schema`. Pin `CODEX_MODEL=gpt-5.5`. |

Every deny message also includes a `<claude-directive>` block with
the explicit fix. If you read it and it doesn't help, see the
"Hook deadlock" gotcha below.

---

## Common gotchas

### "Hook denied my edit, what now?"

Read the deny message — every deny includes a `<claude-directive>`
block with the specific fix. Common causes:

| Missing marker | Operator action |
|---|---|
| M1 (Human approved spec) | Reply `APPROVED SPEC` after reviewing plan |
| M2 (Red phase confirmed) | AI captures `.tdd/red-proof.md`; AI sets marker |
| M3 (Green phase authorized) | Reply `APPROVED RED, go ahead with green` |
| M4 (Implementation reviewed) | Reply `APPROVED IMPLEMENTATION` after reading diff + adjudication |
| Stale `/second-opinion` (>60min) | Re-run `/second-opinion diff` |

### "I want to edit a test mid-green"

Phase-aware test policy denies this by default. Two paths:

**Authorized: typed exception** (preferred).
1. AI invokes `grant-test-edit-exception.sh` with the right type.
2. You reply `APPROVED EXCEPTION E-001`.
3. Edit goes through with AST validation.

**Return to red** (when the exception types don't fit).
1. You authorize return-to-red explicitly.
2. AI sets `Red phase confirmed: no` in the plan.
3. AI edits the test, re-runs, captures new `red-proof.md`.
4. AI sets `Red phase confirmed: yes` again.
5. You re-approve: `APPROVED RED, go ahead with green`.

**Emergency-only:** `test_file_policy.allow_after_red_confirmed:
true` in tdd-config.json. Document reason in commit. Deprecated;
removed in v2.0.0.

### "/second-opinion returned no output"

Check `.tdd/second-opinion-debug.log`. Common causes:

- **Codex CLI not installed** — `make doctor` reports it.
- **Codex not authenticated** — `codex login` (ChatGPT auth) OR set
  `CODEX_API_KEY` (API-key auth).
- **Default model `gpt-5.5` requires ChatGPT auth** — with API-key,
  the skill auto-falls-back to `gpt-5.4`.
- **Network timeout** — skill exits 0 silently; audit log records
  the skip.
- **Bubblewrap sandbox issue** — environment variables changed
  during the session; restart Claude.

### "Hook deadlock — I cannot proceed"

STOP. Surface to the operator. Do NOT modify the hook script. Hooks
are governance infrastructure; patching them mid-cycle is
unauthorized modification.

The escape hatches are:
- Operator flips a config flag in tdd-config.json with reason in
  commit.
- Operator sets a killswitch env var (`SECOND_OPINION_DISABLE=1`,
  `TDD_COMMIT_GATE_DISABLE=1`, `TEST_EDIT_EXCEPTION_DISABLE=1`,
  `TDD_AST_VALIDATOR_DISABLE=1`).
- Real bug → file an upstream issue.

If a deadlock happens, the hook design is wrong, not your
workflow. Report it.

### "Smoke tests fail after I install"

```bash
bash scripts/tdd-test-hooks.sh 2>&1 | grep FAIL | head -5
```

Most common failures:
- `jq` missing → `brew install jq` / `apt install jq`.
- bash version (macOS default is 3.2) → `brew install bash`.
- AST tests need `go` — install Go ≥ 1.26.2.
- Validator path mismatch — verify `scripts/tdd/ast/validator.go`
  exists.

### "How do I update from upstream starter?"

Updates do not flow automatically. Refresh quarterly:

```bash
git remote add starter https://gitlab.your-domain.com/your-group/go-claude-starter.git
git fetch starter
git diff starter/main -- .claude .tdd scripts docs
# Cherry-pick changes you want
```

The pack ships a CHANGELOG with version notes; check
`docs/VERSION_NOTES.md` for breaking changes.

---

## Killswitches reference

| Env var | Effect | Use when |
|---|---|---|
| `TDD_COMMIT_GATE_DISABLE=1` | Skip commit-gate validation | Hook-bug emergency |
| `SECOND_OPINION_DISABLE=1` | Skip /second-opinion entirely | Codex outage / quota |
| `SECOND_OPINION_HASH_DISABLE=1` | Skip diff-sha binding check | Stale adjudication recovery |
| `SECOND_OPINION_PASS_A_DISABLE=1` | Skip Codex's blind-design Pass A | Pass A noisy on a refactor |
| `TEST_EDIT_EXCEPTION_DISABLE=1` | Bypass typed test-edit exceptions | Emergency test edit |
| `TDD_AST_VALIDATOR_DISABLE=1` | Fall back to regex-only validator | AST false-positive on legit edit |

All honor-system. Document use in the next commit message.

---

## Defense layers

The pack is layered defense — each layer catches what the next layer
above missed:

1. **Layer 0 — Spec gate.** `specs/` directory + `specify` skill.
   Specify → Plan → Tasks → Implement.
2. **Layer 1 — TDD ceremony.** `.tdd/current-plan.md` state machine
   + four-marker model (M1/M2/M3/M4) + `require-tdd-state.sh` hook.
3. **Layer 2 — In-session prevention.** `CLAUDE.md` + `.claude/rules/*` +
   skills + subagents + safety hooks (`guard-dangerous-bash`,
   `scan-for-secrets`, `guard-protected-files`, `gofmt-after-edit`,
   `detect-ai-bloat`, `guard-bash-pipefail`).
4. **Layer 3 — Mechanical CI floor.** `.gitlab-ci.yml` /
   `.github/workflows/ci.yml`: gofmt, go vet, staticcheck,
   govulncheck, deadcode, allowed-modules, race detector, TDD
   ceremony check.
5. **Layer 4 — Review judgment.** `REVIEW.md` + reviewer subagents
   (`go-reviewer`, `go-architect`, `go-concurrency-reviewer`,
   `go-security-reviewer`, `go-test-engineer`, `go-bloat-reviewer`).
6. **Layer 5 — Cleanup.** `negative-diff` skill explicitly tasked
   with deletion after implementation.

You don't see all of these every day. They light up when relevant
(layer 0 on a new feature, layer 1 on a Tier 1 edit, layer 4 when
you ask for a review).

---

## Where to read more

| Topic | File |
|---|---|
| Fresh project adoption | [`docs/ADOPTION_GUIDE.md`](ADOPTION_GUIDE.md) |
| Merge into existing `.claude/` | [`docs/INTEGRATION_GUIDE.md`](INTEGRATION_GUIDE.md) |
| Full TDD workflow (21-step) | [`docs/process/tdd_workflow.md`](process/tdd_workflow.md) |
| TDD discipline rules | [`.claude/rules/go-tdd.md`](../.claude/rules/go-tdd.md) |
| Go style + idioms | [`.claude/rules/go-style.md`](../.claude/rules/go-style.md) |
| Security rules | [`.claude/rules/go-security.md`](../.claude/rules/go-security.md) |
| Testing rules | [`.claude/rules/go-testing.md`](../.claude/rules/go-testing.md) |
| pgx / database patterns | [`.claude/rules/go-pgx.md`](../.claude/rules/go-pgx.md) |
| Integration guards | [`.claude/rules/go-integration-guards.md`](../.claude/rules/go-integration-guards.md) |
| AI bloat detection | [`.claude/rules/go-ai-bloat.md`](../.claude/rules/go-ai-bloat.md) |
| `/second-opinion` design | [`docs/specs/second-opinion-v1.6.0-spec.md`](specs/second-opinion-v1.6.0-spec.md) |
| Typed test-edit exceptions | [`docs/specs/typed-test-edit-exceptions-v1.7.0-spec.md`](specs/typed-test-edit-exceptions-v1.7.0-spec.md) |
| AST validator + audit chain | [`docs/specs/ast-validator-and-audit-integrity-v1.8.0-spec.md`](specs/ast-validator-and-audit-integrity-v1.8.0-spec.md) |
| Hook smoke tests | [`scripts/tdd-test-hooks.sh`](../scripts/tdd-test-hooks.sh) |
| Pack maintenance | [`MAINTAINING.md`](../MAINTAINING.md) |
| For Codex / cross-agent | [`AGENTS.md`](../AGENTS.md) |

---

## Summary in one paragraph

Clone the starter, customize `.tdd/tdd-config.json` (project name +
Tier 1 path regexes), run `bash scripts/tdd-test-hooks.sh` (expect
520 passing), commit. Use Claude Code normally — non-Tier-1 work is
unaffected; Tier 1 edits trigger the four-marker TDD ceremony with
three operator approval gates. When Claude needs to edit a test
post-red, it requests a typed exception (`grant-test-edit-exception.sh`),
you approve `E-NNN`, and AST-validated mechanical edits proceed. If
any hook denies unexpectedly, read the stderr — every deny includes
a specific fix. Never modify hooks to make a deny go away; STOP and
surface to the operator. The pack ships v1.8.0 with AST-backed
validation, audit-log sha-chain integrity, and Codex cross-model
review — opt-in via config flags, all default-safe.
