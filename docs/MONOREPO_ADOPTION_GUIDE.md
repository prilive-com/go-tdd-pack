# Monorepo Adoption Guide

How to install and run `go-claude-starter` in a Go monorepo where multiple
services live under one repository root and a single Claude CLI agent
operates from that root.

**Pack version targeted:** ≥ v1.9.3
**Audience:** Operators adopting the pack into a multi-service Go monorepo.
**Status:** Canonical guide. Updates land here when the patterns change.

---

## 1. When this pattern fits

Use this guide if **all** of the following are true:

- The repository contains 2+ Go services in sibling top-level directories.
- A single Claude CLI agent operates from the repository root.
- Each service has its own logical boundary (independent deploy, independent
  test command), but cycles often touch one service at a time.
- You want one shared TDD ceremony, one shared audit log, one shared
  second-opinion history.

If instead each service has its own dedicated agent session and the agent
`cd`s into the service before each task, the per-service install pattern
(one full pack per service) is simpler. That pattern is not covered here.

---

## 2. The architecture decision

Two patterns are valid for monorepos. This guide picks one and explains why.

### Pattern A — Single root install (this guide)

```
repo-root/
├── .claude/                 ← one install
├── .tdd/                    ← one cycle metadata, one audit log
├── scripts/tdd/             ← one set of helpers
├── service-a/
├── service-b/
└── service-c/
```

- One `.claude/` and `.tdd/` at the repo root.
- One audit log, one current-plan, one cycle at a time.
- Tier 1 regexes use service prefixes: `(^|/)service-a/internal/auth/.*\.go$`.
- Hooks read `.tdd/tdd-config.json` from `CLAUDE_PROJECT_DIR` (or `pwd`).
  As long as the agent stays at root, no patches needed.

### Pattern B — Per-service install (not this guide)

```
repo-root/
├── .claude/                 ← thin coordinator
├── .tdd/                    ← root cycles only
├── service-a/
│   ├── .claude/             ← full install
│   └── .tdd/                ← per-service cycle, audit, history
├── service-b/
│   ├── .claude/
│   └── .tdd/
...
```

- Each service has its own full install.
- Workflow: `cd <service> && claude` per task.
- Per-service audit isolation, per-service ceremony.
- 1 + N installs to maintain.

### Why this guide picks Pattern A

| Criterion | Pattern A | Pattern B |
|---|---|---|
| Matches single-root-agent workflow | yes | breaks it |
| Maintenance cost (1 install vs N+1) | low | high |
| Per-service audit isolation | no | yes |
| Cross-service ceremony cost | low | high |
| Hook patches needed | no | no |
| Pack-self regex governance | one place | N places |

Pattern A is the right default. Switch to Pattern B only if the audit
isolation matters more than the workflow simplicity (e.g., separate teams
own separate services with no shared review chain).

### What you give up with Pattern A

- Cross-service edits cannot run in parallel cycles. One TDD cycle is
  active at a time across the repo.
- The audit log is shared across all services.
- Service-internal Tier 1 calibration lives in the root config file,
  not next to the service code.

If these become painful in 6+ months, the upgrade path is a custom hook
patch that adds path-aware routing (read `.tdd/services.json`, find the
closest containing service directory). Real engineering work — 1-2 days.

---

## 3. Pre-install checklist

Run from the repo root:

```bash
# 1. Pack source on disk
ls $HOME/go-projects-claude-starter && \
  git -C $HOME/go-projects-claude-starter rev-parse --short HEAD
# Expect ≥ v1.9.3.

# 2. Required tools
for t in jq bash git gofmt go; do
  command -v $t >/dev/null && echo "$t: ok" || echo "$t: MISSING"
done
# All must say "ok".

# 3. Strongly recommended
for t in codex gitleaks goimports golangci-lint; do
  command -v $t >/dev/null && echo "$t: ok" || echo "$t: missing (recommended)"
done
# codex is mandatory for /second-opinion.

# 4. Service inventory
ls -d */ | grep -vE '^(\.claude|\.tdd|scripts|docs|migrations|images|logs|archive)/$'

# 5. Module layout
find . -maxdepth 2 -name go.mod
# If multiple results, use go.work (Step 4.6).

# 6. Pre-existing pack state
ls -la .claude/ .tdd/ 2>/dev/null || echo "no pre-existing pack state"
```

Do not proceed without `codex` if you intend to use `/second-opinion`.

---

## 4. Install steps

### 4.1 Backup any existing state

```bash
[ -d .claude ] && tar -czf .claude.backup.$(date +%Y%m%d).tgz .claude
[ -d .tdd ]    && tar -czf .tdd.backup.$(date +%Y%m%d).tgz .tdd
```

### 4.2 Copy the pack from a starter checkout

```bash
STARTER="$HOME/go-projects-claude-starter"

cp -R "$STARTER/.claude" .
cp -R "$STARTER/.tdd"    .
mkdir -p scripts/tdd scripts/tdd/ast
cp -R "$STARTER/scripts/tdd/"* scripts/tdd/
cp    "$STARTER/scripts/tdd-test-hooks.sh" scripts/

chmod +x .claude/hooks/*.sh
chmod +x scripts/tdd/*.sh scripts/tdd-test-hooks.sh
```

### 4.3 Replace `.tdd/tdd-config.json` with the monorepo template

See **Section 5**.

### 4.4 Add `.tdd/services.json`

See **Section 6**. Informational registry. Hooks do not read it today.

### 4.5 Append the monorepo block to root `CLAUDE.md`

See **Section 7**. Append, do not replace.

### 4.6 (Optional) Initialize `go.work` if services are separate modules

```bash
go work init ./service-a ./service-b ./service-c ...
go work sync
```

Skip if all services share a single root `go.mod`.

### 4.7 Smoke test

```bash
bash scripts/tdd-test-hooks.sh 2>&1 | tail -3
```

**Expected: failures.** See **Section 14** for why and what to do.

---

## 5. `.tdd/tdd-config.json` template

Replace `service-a`, `service-b`, etc. with your real service folder names.
The Tier 1 regex blocks are starter guesses — calibrate per **Section 12**.

```json
{
  "$schema_note": "Pack v1.9.3 monorepo config. One root install, N services. Tier 1 regexes use service prefixes. Hooks read this file from CLAUDE_PROJECT_DIR or pwd.",

  "enforcement_mode": "strict",

  "second_opinion": {
    "model_tier1":   "gpt-5.5",
    "model_default": "gpt-5.5",
    "fallback_model": "gpt-5.4",

    "no_discretion": {
      "enabled": true,
      "max_review_rounds_per_cycle": 4
    }
  },

  "tier1_path_regexes": [
    "(^|/)migrations/.*\\.sql$",
    "(^|/)docker-compose\\.ya?ml$",

    "(^|/)service-a/(cmd|internal/(auth|storage|config))/.*\\.go$",
    "(^|/)service-b/(cmd|internal/(auth|storage|config))/.*\\.go$",
    "(^|/)service-c/(cmd|internal/(auth|storage|config))/.*\\.go$",

    "(^|/)\\.claude/hooks/(gate-tier1-commit|guard-dangerous-bash|guard-protected-files|scan-for-secrets|require-tdd-state|require-second-opinion|second-opinion-bash-pretrigger|second-opinion-plan-trigger|second-opinion-test-trigger|second-opinion-production-trigger|second-opinion-posttool-backstop|session-stop-review)\\.sh$",
    "(^|/)\\.claude/skills/second-opinion/SKILL\\.md$",
    "(^|/)\\.tdd/tdd-config\\.json$",
    "(^|/)\\.tdd/services\\.json$",
    "(^|/)scripts/tdd/(run-second-opinion|runner-context-pack|hash-review-scope|validate-review-completion)\\.sh$",
    "(^|/)scripts/tdd/ast/validator\\.go$"
  ],

  "trivial_paths": [
    "*.md", "*.txt",
    "CHANGELOG*", "*/CHANGELOG*",
    "README*", "*/README*",
    "LICENSE*", "*/LICENSE*",
    ".editorconfig", ".gitignore", "*/.gitignore",
    "go.sum", "*/go.sum",
    ".github/*", "*/.github/*",
    ".gitlab-ci.yml",
    "logs/*", "images/*",
    "*.tar.gz"
  ]
}
```

### Notes on the config

- `enforcement_mode: "strict"` — hooks fail closed (block) when ceremony
  markers are missing.
- Tier 1 regexes are intentionally generous. False positives trigger
  ceremony for nothing (annoying); false negatives let dangerous code
  ship unreviewed (incident). Bias toward false positives.
- `trivial_paths` skip the pre-flight diff filter that decides whether
  to invoke Codex. Be conservative — these paths bypass review.
- The pack-self regex entries (`.claude/hooks/...`, `.tdd/tdd-config.json`)
  exist so the agent cannot quietly relax its own oversight. **Do not
  delete them.** This was the indulgence pattern that surfaced in a real
  adopter audit — the agent narrowed Tier 1 to make its own life easier
  and lost oversight of the very files that govern it.

---

## 6. `.tdd/services.json` template

Informational registry. Hooks do not read this file today. It exists for:

- Humans (`what is the test command for service X?`).
- Helper scripts in **Section 10**.
- Future automation (path-aware routing in a possible v1.10).

```json
{
  "version": 1,
  "monorepo_root": "REPO_NAME_HERE",
  "note": "Informational only. Hooks do not read this. See helper scripts in scripts/tdd/.",

  "services": {
    "service-a": {
      "root": "service-a",
      "language": "go",
      "module_file": "service-a/go.mod",
      "test_command":  "cd service-a && go test ./...",
      "race_command":  "cd service-a && go test -race ./...",
      "build_command": "cd service-a && go build ./...",
      "production_globs": ["service-a/**/*.go"],
      "test_globs":       ["service-a/**/*_test.go"]
    },
    "service-b": {
      "root": "service-b",
      "language": "go",
      "module_file": "service-b/go.mod",
      "test_command":  "cd service-b && go test ./...",
      "race_command":  "cd service-b && go test -race ./...",
      "build_command": "cd service-b && go build ./...",
      "production_globs": ["service-b/**/*.go"],
      "test_globs":       ["service-b/**/*_test.go"]
    }
  },

  "shared": {
    "paths": [
      "docker-compose.yml",
      "migrations/**",
      "docs/**"
    ],
    "verification_command": "docker compose config"
  }
}
```

If a service is not Go (Node, Python, ...), edit `language` and the
commands accordingly.

---

## 7. Root `CLAUDE.md` block to append

Append this to the existing root `CLAUDE.md`. Replace `<service-a>`,
`<service-b>`, ... with real names.

```markdown
## Pack Governance — Monorepo

This repo uses `go-claude-starter` v1.9.3 installed once at the root.
Hooks are active for every Claude Code session started from this directory.

### Repository shape

This is a Go microservices monorepo. Services:

- `<service-a>` — <one-line purpose>
- `<service-b>` — <one-line purpose>
- ...

Shared paths:

- `migrations/` — SQL migrations (Tier 1)
- `docker-compose.yml` — service orchestration (Tier 1)
- `docs/`, `images/`, `logs/` — non-code

### Working rule

Before editing, classify the change:

1. **Single-service** — only one service folder is touched.
2. **Cross-service** — two or more service folders, OR shared paths, are touched.
3. **Governance** — `.claude/`, `.tdd/`, `scripts/tdd/`, root CLAUDE.md/AGENTS.md.

The Tier 1 regexes in `.tdd/tdd-config.json` cover security, storage, config,
and entry-point paths in each service plus all shared and governance paths.
A Tier 1 edit requires the full ceremony: plan + research + red proof + second
opinion + green proof + commit gate.

### One cycle at a time

This pack supports one TDD cycle active at a time across the whole repo.
The cycle plan in `.tdd/current-plan.md` may target one service or several.

If you need to start work on a different concern while a cycle is active,
either finish the current cycle, abandon it explicitly with
`echo "APPROVED CYCLE ABANDONMENT" > .tdd/CYCLE_ABANDONED.txt`, OR start
a second Claude CLI session in a fresh checkout/worktree of the repo.

### The inviolable rule

You do not decide whether `/second-opinion` is required. The hooks decide.

The skill `second-opinion` has `disable-model-invocation: true` — the model
literally cannot invoke `Skill(second-opinion)`. The only legitimate caller
of `codex exec` for review is `scripts/tdd/run-second-opinion.sh`.

If a hook blocks an action with "obligation required," run the named runner
script. Do not work around the block by editing hooks, deleting Tier 1
regexes from the config, or setting killswitch env vars without operator
approval.

### Service-specific rules

Each service may have its own `<service>/CLAUDE.md` describing service-local
conventions. Read the service's CLAUDE.md before editing inside that service.

### Service registry

`.tdd/services.json` lists each service's test, race, and build commands.
The hooks do not read this file; helper scripts in `scripts/tdd/` do.
Use these helpers to run only the affected service's tests:

    scripts/tdd/run-affected-tests.sh
```

---

## 8. Per-service `<service>/CLAUDE.md` template

Each service should have its own `CLAUDE.md` with service-local rules.

```markdown
# CLAUDE.md — <service-name>

This file describes rules specific to this service. Root rules live in
`../CLAUDE.md`. Pack governance applies (see root CLAUDE.md "Pack Governance
— Monorepo").

## What this service does

<2-3 sentences. The single-sentence answer to "if this service is broken,
what user-visible thing breaks?">

## Tier 1 paths inside this service

Listed in `.tdd/tdd-config.json` at the repo root. For this service:

- `<service>/cmd/...` — entry point. Bootstrap bugs are silent in unit tests.
- `<service>/internal/<critical-package>/...` — <one-sentence reason>.
- ...

When in doubt, treat a path as Tier 1.

## Test commands

- Unit:    `cd <service> && go test ./...`
- Race:    `cd <service> && go test -race ./...`
- Build:   `cd <service> && go build ./...`

## Service-specific conventions

<Concrete rules. Examples:
- "All HTTP handlers go through the middleware in internal/middleware."
- "Database access uses pgx; no lib/pq.">

## Dependencies on other services

<List the contracts this service produces or consumes.
Example: "Reads from the `articles` table written by article-extractor.">

## Common pitfalls

<Service-specific gotchas. Delete this section if none.>
```

---

## 9. Per-service `<service>/AGENTS.md` template

`AGENTS.md` is read by Codex (and other reviewer agents) before a review.
Per-service `AGENTS.md` lets reviewers anchor findings on specific concerns.

```markdown
# AGENTS.md — <service-name>

Reviewer notes for `/second-opinion` working on this service.

## Service mission

<One paragraph. What this service does, who depends on it, what breaks if
it ships a bug.>

## Tier 1 review checklist

For each Tier 1 path in this service, list the specific things to check.

- `cmd/<service>/main.go` — entry point
  - Config is read before any DB connection.
  - Graceful shutdown handlers registered.
  - Structured logging initialized before workers spawn.

- `internal/<critical-pkg>/...` — <pkg purpose>
  - <Specific check 1>
  - <Specific check 2>

## Tier 2 review patterns

Standard Go review:

- Error wrapping with `fmt.Errorf("...: %w", err)`.
- `context.Context` flows through every I/O call.
- No goroutine leaks.
- Table-driven tests with `t.Run(name, ...)`.
- No `log.Fatal` in library code.

## Findings format

P0/P1/P2/P3 severity. Every P0/P1 finding must include:

- concrete failure mode
- file path and line evidence
- reproduction or scenario
- required fix
- test that would catch it

Output must conform to the schema at
`<repo-root>/.tdd/templates/review-completion.schema.json`.

## Service dependencies (for cross-service reviews)

If this review touches a contract shared with another service, also read:

- `<other-service>/AGENTS.md`
- `<other-service>/api/`
- `migrations/` for shared schema changes
```

---

## 10. Helper scripts

Create these in `scripts/tdd/`. They make the monorepo workflow practical
by reading `.tdd/services.json`.

### 10.1 `scripts/tdd/changed-services.sh`

```bash
#!/usr/bin/env bash
# List unique services touched by current diff (vs given ref, default HEAD).
set -euo pipefail

base="${1:-HEAD}"
config=".tdd/services.json"
[ -f "$config" ] || { echo "missing $config" >&2; exit 2; }

# Build a regex of service roots from services.json.
roots=$(jq -r '.services | to_entries[] | .value.root' "$config" \
        | tr '\n' '|' | sed 's/|$//')

git diff --name-only "$base" 2>/dev/null | awk -v R="$roots" -F/ '
  BEGIN { split(R, a, "|"); for (i in a) svc[a[i]] = 1 }
  $1 in svc                                  { print $1; next }
  /^docker-compose\.yml$|^migrations\//      { print "shared"; next }
' | sort -u
```

### 10.2 `scripts/tdd/run-service-tests.sh`

```bash
#!/usr/bin/env bash
# Run tests for one service.
set -euo pipefail

svc="${1:?service name required}"
config=".tdd/services.json"
[ -f "$config" ] || { echo "missing $config" >&2; exit 2; }

cmd=$(jq -r --arg s "$svc" '.services[$s].test_command // empty' "$config")
[ -z "$cmd" ] && { echo "unknown service: $svc" >&2; exit 2; }

eval "$cmd"
```

### 10.3 `scripts/tdd/run-affected-tests.sh`

```bash
#!/usr/bin/env bash
# Run tests only for services touched in current diff.
set -euo pipefail

base="${1:-HEAD}"
services=$(scripts/tdd/changed-services.sh "$base")
[ -z "$services" ] && { echo "no service changes detected"; exit 0; }

failed=()
for svc in $services; do
  case "$svc" in
    shared)
      echo "== shared (docker-compose config) =="
      docker compose config >/dev/null && echo "ok" || failed+=("compose-config")
      ;;
    *)
      echo "== $svc =="
      scripts/tdd/run-service-tests.sh "$svc" || failed+=("$svc")
      ;;
  esac
done

if [ "${#failed[@]}" -gt 0 ]; then
  echo "FAILED: ${failed[*]}" >&2
  exit 1
fi
echo "all affected services passed"
```

```bash
chmod +x scripts/tdd/changed-services.sh scripts/tdd/run-service-tests.sh scripts/tdd/run-affected-tests.sh
```

---

## 11. TDD cycle workflow

### 11.1 Single-service cycle (most common)

1. Operator writes a one-line goal in chat: "add retry on 429 in service-a."
2. Agent writes plan to `.tdd/current-plan.md`. Plan-write trigger fires.
3. Run `scripts/tdd/run-second-opinion.sh plan_review <cycle-id>`.
4. Operator reviews disposition matrix; replies `APPROVED PLAN` (or rejects).
5. Agent writes the failing test (red phase). Test-write trigger fires.
6. Run `scripts/tdd/run-second-opinion.sh test_review <cycle-id>`.
7. Operator confirms red. `APPROVED RED`.
8. Agent writes production code. Production-edit trigger fires on first edit.
9. Run `scripts/tdd/run-second-opinion.sh production_edit <cycle-id>`.
10. Subsequent production edits in the same cycle do not re-block until commit.
11. Tests go green. `APPROVED GREEN`.
12. Commit gate fires. Final-diff second-opinion runs.
13. Commit lands.

### 11.2 Cross-service cycle

Same flow, with two additions:

- The plan in `.tdd/current-plan.md` lists every affected service explicitly
  in an "Affected services" section.
- After green, run `scripts/tdd/run-affected-tests.sh` to verify each touched
  service in isolation.

There is no separate "cross-service review type" in the starter. Codex sees
the full diff (which spans services) and reviews accordingly. The per-service
`AGENTS.md` files give Codex the context it needs.

### 11.3 If the cycle deadlocks

If `/second-opinion` cannot complete (Codex API error, network down, broken
schema), and the runner-required obligation cannot be cleared:

1. **Do not** delete the obligation file or the audit log.
2. **Do not** edit the runner to bypass the call.
3. Report the error verbatim to the pack maintainer.
4. While waiting, abandon the cycle:
   `echo "APPROVED CYCLE ABANDONMENT" > .tdd/CYCLE_ABANDONED.txt`.
   Work-in-progress code stays on disk; cycle metadata is dead. Re-do under
   a fresh cycle ID once upstream is fixed.

---

## 12. Tier 1 calibration per service

The Tier 1 regex list in `.tdd/tdd-config.json` is a starting guess. Calibrate
to the actual layout of each service.

### How to calibrate

For each service:

```bash
ls -d <service>/{cmd,internal,api,migrations,pkg} 2>/dev/null
ls <service>/internal/ 2>/dev/null
```

For each `internal/<package>/`, ask:

- Does this package handle authentication, sessions, tokens, secrets? → Tier 1.
- Does this package read or write the database? → Tier 1.
- Does this package handle user-controlled input that affects storage or
  display? → Tier 1.
- Is this an entry point (`cmd/.../main.go`)? → Tier 1.
- Is this configuration loading (`internal/config/`)? → Tier 1.
- Is this pure business logic with no I/O? → Tier 2 unless the algorithm
  itself is security-critical (e.g., deduplication hashing, URL canonical
  form, pricing math, signature verification).

### Pack-self regexes are not optional

The pack-self entries in Tier 1 (`.claude/hooks/*`, `.tdd/tdd-config.json`,
`.claude/skills/second-opinion/SKILL.md`, `scripts/tdd/run-second-opinion.sh`,
the AST validator) exist so the agent cannot edit its own oversight code
without ceremony. If you delete them, the agent can edit governance code
silently and the audit log will not show those changes as Tier 1. Keep them.

This is incident-driven, not theoretical. A real adopter audit found exactly
this drift: the agent had quietly removed pack-self regexes from its config
during adaptation, freeing itself to edit hooks without review.

---

## 13. Phased rollout schedule

Do not roll out Tier 1 to all services at once. Calibrate one, then expand.

| Week | Action | Verification |
|---|---|---|
| 1 | Install at root. Tier 1 calibrated for the most-edited service only. Other services have empty Tier 1 entries (Tier 2 by default). | One real cycle in the calibrated service. Cycle commits cleanly. Audit log entry chains to commit. |
| 2 | Add Tier 1 entries for the next service. Pilot one cycle there. | Same. |
| 3-N | Add Tier 1 for one service per week. Pilot one cycle each. | Same. |
| N+1 | Review the audit log. Count: bypass count, waiver count, abandoned-cycle count. | Numbers should be low. If high, calibration is too aggressive. |
| ongoing | Adjust regexes as new packages appear. Quarterly review of "accepted P0/P1" rate. | — |

Why phased: the Tier 1 list has consequences. Set it too tight, every edit
triggers ceremony and developers learn to bypass. Set it too loose, dangerous
code ships unreviewed. Each service deserves its own calibration based on
real workflow friction.

---

## 14. Known limitations and caveats

### 14.1 Smoke tests will fail at install (until pack v1.9.4)

The starter's `scripts/tdd-test-hooks.sh` uses fixture paths like
`internal/payments/charge.go` (no service prefix). Monorepo Tier 1 regexes
use prefixes (`(^|/)service-a/internal/...`). The fixture paths do not
match → hooks classify them as non-Tier-1 → tests expect block → fail.

This is a known starter-side defect tracked for v1.9.4 (host-config-isolated
smoke fixtures). Until v1.9.4 ships:

- Do **not** gate CI on the starter's smoke suite in a monorepo.
- Run smoke as a sanity check (it confirms hooks are executable and parse
  JSON), but do not expect 0 failures.
- Real verification: run a real cycle on a real change. If the cycle commits
  cleanly with audit-log entries, the install works.

### 14.2 `services.json` is informational, not enforced

The hooks do not read `.tdd/services.json`. They read `.tdd/tdd-config.json`
only. The service registry exists for humans, helper scripts, and future
tooling.

If you add or remove a service, update both files. The Tier 1 regex in
`tdd-config.json` is what actually governs.

### 14.3 No path-aware audit log routing

There is one shared audit log at `.tdd/audit/audit.jsonl`. A waiver granted
for service A is recorded in the same SHA chain as a green proof for
service B. Fine for a small team; limits per-service audit isolation.

### 14.4 One cycle at a time

The starter assumes one TDD cycle is active per project root. For parallel
work on two unrelated changes, run two Claude CLI sessions in two checkouts
or git worktrees.

### 14.5 No automatic cross-service contract verification

The pack does not check that, e.g., a struct-field rename in service A is
reflected in service B. The plan must call out cross-service contracts
explicitly. Codex will catch obvious mismatches if both files are in the
diff; subtle wire-format drift between separate cycles will not be caught.

---

## 15. Common pitfalls and recovery

| Pitfall | What goes wrong | Recovery |
|---|---|---|
| Two cycles started in parallel | The second overwrites `.tdd/current-plan.md`. Audit log gets confused. | Abandon both cycles. Re-do one at a time. |
| Tier 1 regex too narrow | Dangerous edits skip review. | Widen the regex. Note the gap in `governance-incident.md`. |
| Tier 1 regex too wide | Trivial edits trigger ceremony. Developers learn to bypass. | Narrow the regex. The pack should fail closed for security-relevant paths only. |
| Runner deadlock from upstream API change | Pending obligation cannot be cleared. Stop hook blocks every Bash. | Capture the error verbatim. Do not patch the runner locally. Report to maintainer. While waiting, abandon the cycle. |
| Operator approves everything without reading | Ceremony becomes theater. Real findings get lost. | Quarterly review of "accepted P0/P1" rate. If high, retrain on disposition-matrix discipline. |
| Killswitches in `.bashrc` | Reviews silently skipped globally. | Killswitches are session-only. Remove from shell rc files. CI must re-check the gate on PR. |
| Cross-service edit in a single-service cycle | Reviewer context misses cross-service implications. | Abandon the cycle. Re-plan as cross-service. |
| Smoke tests fail at install | ~80-100 failures on the starter's smoke suite. | Expected. See Section 14.1. |

---

## 16. End-to-end example: first real cycle

Walk through one real cycle to prove the install works.

```bash
cd <repo-root>
claude

# In Claude:
# > "Plan a small change in service-a: add retry-with-backoff for upstream 429s."

# Claude writes .tdd/current-plan.md.
# Plan-write trigger fires.
bash scripts/tdd/run-second-opinion.sh plan_review my-cycle-20260515

# Read .tdd/codex/<round>.raw and the disposition matrix.
# In Claude:
# > "APPROVED PLAN"

# Claude writes the failing test in service-a/internal/.../retry_test.go.
bash scripts/tdd/run-second-opinion.sh test_review my-cycle-20260515

# Confirm red:
cd service-a && go test ./internal/.../retry... ; cd ..
# Expect: FAIL

# In Claude:
# > "APPROVED RED"

# Claude writes production code.
bash scripts/tdd/run-second-opinion.sh production_edit my-cycle-20260515

# Confirm green:
cd service-a && go test ./internal/.../retry... ; cd ..
# Expect: PASS

# In Claude:
# > "APPROVED GREEN"

# Commit. Commit gate runs final-diff second opinion.
git add service-a/internal/.../retry.go service-a/internal/.../retry_test.go
git commit -m "service-a: add retry-with-backoff for upstream 429"

# Inspect the audit log:
tail -3 .tdd/audit/audit.jsonl | jq .
```

If all of this works, the install is good. Calibrate Tier 1 for the next
service per the phased schedule.

---

## 17. Files this guide creates or expects

| Path | What |
|---|---|
| `.claude/` | Hooks, skills, agents, rules (copied from starter) |
| `.tdd/tdd-config.json` | Per Section 5 |
| `.tdd/services.json` | Per Section 6 |
| `.tdd/templates/review-completion.schema.json` | From starter |
| `.tdd/exceptions/`, `.tdd/audit/`, `.tdd/codex/` | Created by runner on first use |
| `scripts/tdd/*.sh`, `scripts/tdd/ast/validator.go` | From starter |
| `scripts/tdd/changed-services.sh` | Per Section 10.1 |
| `scripts/tdd/run-service-tests.sh` | Per Section 10.2 |
| `scripts/tdd/run-affected-tests.sh` | Per Section 10.3 |
| `CLAUDE.md` (existing) | Append Section 7 |
| `<service>/CLAUDE.md` | Per Section 8, one per service |
| `<service>/AGENTS.md` | Per Section 9, one per service |
| `go.work`, `go.work.sum` | Optional, per Section 4.6 |

---

## 18. When to revise this guide

- Pack v1.9.4 ships → revisit Section 14.1 (smoke tests). The fix should
  let you gate CI on smoke.
- A new service pattern emerges (non-Go services in the same monorepo) →
  add a section for mixed-language monorepos.
- An incident shows the single-audit-log design is insufficient → document
  the per-service routing upgrade path.

---

## Appendix A — Worked example: privybot-science-es

A real adopter scenario.

**Layout:**

```
privybot-science-es/
├── ainews-processor/
├── article-extractor/
├── deduplicator/
├── link-extractor/
├── playwright-extractor/
├── privy-tg-bot/
├── docker-compose.yml
├── migrations/
├── docs/
├── images/
├── logs/
├── CLAUDE.md
└── AGENTS.md
```

**Architecture:** Pattern A (single root install). Six services, one Claude
CLI agent at root, cycles typically inside one service.

**Tier 1 regex block:**

```
"(^|/)migrations/.*\\.sql$",
"(^|/)docker-compose\\.ya?ml$",

"(^|/)privy-tg-bot/(cmd|internal/(auth|telegram|session|storage|config))/.*\\.go$",
"(^|/)deduplicator/(cmd|internal/(storage|hash|repository|config))/.*\\.go$",
"(^|/)article-extractor/(cmd|internal/(parser|fetcher|repository|config))/.*\\.go$",
"(^|/)link-extractor/(cmd|internal/(extractor|normalizer|robots|repository|config))/.*\\.go$",
"(^|/)ainews-processor/(cmd|internal/(pipeline|llm|prompts|repository|config))/.*\\.go$",
"(^|/)playwright-extractor/(cmd|internal/.*)/.*\\.go$",
```

**Per-service Tier 1 starter calibration:**

| Service | Tier 1 candidates (in `internal/`) |
|---|---|
| `privy-tg-bot` | `auth`, `telegram`, `session`, `storage`, `config`, `commands` |
| `deduplicator` | `storage`, `hash`, `repository`, `config` |
| `article-extractor` | `parser`, `fetcher`, `repository`, `config` |
| `link-extractor` | `extractor`, `normalizer`, `robots`, `repository`, `config` |
| `ainews-processor` | `pipeline`, `llm`, `prompts`, `repository`, `config` |
| `playwright-extractor` | All `internal/` (browser automation hard to test in isolation) |

**Phased rollout:** Pilot `privy-tg-bot` first (most-edited service per file
timestamps). Expand to `deduplicator`, then the rest.

**Known service question:** confirm `playwright-extractor` is Go before
including in `go.work` and Tier 1 regex. If it is Node, swap `.go$` to
`.js$|.ts$` and adjust `services.json` commands.

---

End of guide.
