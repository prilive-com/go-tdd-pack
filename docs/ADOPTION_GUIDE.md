# Adoption guide for new projects

For a developer bringing `go-claude-starter` into a Go project from
scratch (or near-scratch). If you already have an extensive
`.claude/` directory you want to merge with, see
`docs/INTEGRATION_GUIDE.md` instead — that doc covers the merge case.

This doc is the short, action-oriented path for fresh adoption.

---

## What you get

The pack ships:

- **Hooks** that gate dangerous actions (force-push, hooks bypass,
  `--no-verify`, secrets in commits, dangerous bash) and enforce TDD
  discipline on high-stakes paths
- **Skills** (`go-tdd-feature`, `go-tdd-bugfix`, `/second-opinion`,
  `go-modernize`, etc.) that drive the model through proven
  workflows
- **Rules** (`.claude/rules/*.md`) that the model reads as standing
  guidance for Go style, testing, security, and CI discipline
- **Templates** (`.tdd/templates/*`) for the artifacts the workflows
  produce: spec plans, red proofs, green proofs, research packets,
  disposition matrices

Everything is opt-in or default-safe. Hooks deny only on documented
violations; skills run when invoked or when their auto-fire conditions
are met; rules apply when the model judges them relevant.

---

## Install (5 minutes)

### Step 1 — Copy the pack into your project

```bash
cd your-go-project
git checkout -b chore/adopt-go-claude-starter

# Clone the starter elsewhere
git clone <starter-pack-url> /tmp/starter

# Copy the relevant directories
cp -r /tmp/starter/.claude .claude
cp -r /tmp/starter/.tdd .tdd
cp -r /tmp/starter/scripts scripts
cp -r /tmp/starter/docs docs

# Optional: copy CLAUDE.md if you do not have one
[ -f CLAUDE.md ] || cp /tmp/starter/CLAUDE.md.template CLAUDE.md
```

### Step 2 — Set the project name

Edit `.tdd/tdd-config.json` and set `project_name` to your project's
short name. This appears in audit logs and hook deny messages.

### Step 3 — Calibrate Tier 1 paths

Open `.tdd/tdd-config.json` and look at `tier1_path_regexes`. The
default list covers common high-stakes patterns:
- `internal/.../auth|authorization|rbac|policy|security|crypto|secret|session|token` directories
- `internal/.../payment|billing|invoice|ledger|accounting|balance` directories
- `internal/.../migration|database|storage|repository|transaction` directories
- Migration SQL files
- Destructive `cmd/*` tools

**Tier 1 paths get the full TDD ceremony** (3 operator approval gates,
mandatory `/second-opinion` review, commit-time validation). Edit
the regex list to match YOUR project's high-stakes paths. Do not
add paths that don't actually need the ceremony — friction backfires
when applied indiscriminately.

If your project has no high-stakes paths (e.g., a CLI tool, a static
site generator), set `tier1_path_regexes: []`. The pack still works;
it just won't enforce ceremony anywhere. Tier 2 (lighter discipline)
applies to all production Go code outside Tier 1.

### Step 4 — Verify

```bash
bash scripts/tdd-test-hooks.sh
# Expect: Results: 86 passed, 0 failed
```

If you see failures, the pack is mis-installed or you have a `jq` /
`bash` version mismatch. The output names which test failed.

### Step 5 — Commit

```bash
git add .claude .tdd scripts docs
git commit -m "chore: adopt go-claude-starter"
```

You're done. Open Claude Code in the repo and the pack is active.

---

## Your first Tier 1 cycle (the full ceremony)

This is what happens when you ask Claude to change a Tier 1 path
(e.g., `internal/auth/handler.go`).

### 1. Spec phase

Claude invokes the `go-tdd-feature` (or `go-tdd-bugfix`) skill,
which writes a spec to `.tdd/current-plan.md`. It pauses and asks
you to reply.

You reply: `APPROVED SPEC` (or plain `APPROVED`). The model sets
`Human approved spec: yes` in the plan.

### 2. Red phase

The model writes failing tests, runs them to confirm they fail,
captures verbatim output to `.tdd/red-proof.md`, and sets
`Red phase confirmed: yes`. Then pauses and asks you again.

You reply: `APPROVED GREEN` (or plain `APPROVED`). The model sets
`Green phase authorized: yes`. The hook now permits production-code
edits to Tier 1 paths.

### 3. Green phase

The model writes the production code. Tests go from RED to PASS.
The model captures `.tdd/green-proof.md`, then runs `/second-opinion
diff` for a cross-model review of the staged diff. It writes an
adjudication artifact (`.tdd/second-opinion-completed.md`) and
pauses.

You read the diff and the adjudication. You reply: `APPROVED
IMPLEMENTATION` (or plain `APPROVED`). The model sets
`Implementation reviewed: yes`. The commit gate (`gate-tier1-commit.sh`)
now permits `git commit`.

### 4. Commit

Claude runs `git commit -m "green(<id>): <description>"`. The hook
validates all four markers + green-proof + fresh adjudication. If
all pass, commit lands.

That's the full ceremony. Roughly 30–60 minutes including thinking
time. The friction is the point; you reserve it for paths where a
silent regression would cause real damage.

For non-Tier-1 paths, none of this applies. Standard Go discipline
(linters, race detector, normal code review) covers them.

---

## v1.6.0 features — opt in when ready

Three flags in `.tdd/tdd-config.json` `second_opinion` block:

```json
"second_opinion": {
  "model_tier1": "gpt-5.5",
  "model_default": "gpt-5.5",
  "fallback_model": "gpt-5.4",
  "require_research_packet_tier1": false,
  "require_pass_a_tier1": false,
  "require_disposition_matrix_tier1": false
}
```

All three default `false`. Default behavior is solid. Flip flags as
your team is ready.

### Flag 1: `require_disposition_matrix_tier1` (recommended week 1)

Replaces free-form `/second-opinion` rebuttal text with a structured
matrix where every Codex finding gets a row with mandatory
Disposition column. Mechanical improvement, no LLM behavior change,
zero risk. Flip first.

### Flag 2: `require_research_packet_tier1` (recommended week 2)

For Tier 1 plans, requires a `.tdd/research-packet.md` with ≥3
authoritative sources cited. Anchors `/second-opinion` review against
the same evidence the implementer consulted.

Adds 5–10 minutes of writing to each Tier 1 plan. Flip if your team
values formalized spec-phase research; skip if your domain doesn't
need it.

### Flag 3: `require_pass_a_tier1` (later, after own validation)

Codex generates its own independent design BEFORE seeing Claude's
plan ("Pass A"), then compares the plan against its own design.
Anchoring-resistant review.

The mechanism is empirically motivated by 2025–2026 multi-agent
review literature, but **codebase-specific value is unproven for
your project**. Don't flip blindly.

**Validation path:**
1. Keep the flag off.
2. On a real Tier 1 cycle, set `SECOND_OPINION_PASS_A_DISABLE=0`
   explicitly (it's already 0 by default; this is just to be sure)
   and trigger Pass A by ensuring a research packet exists at
   `.tdd/research-packet.md` before invoking `/second-opinion plan`.
3. Read the generated `.tdd/codex/independent-design.md`. Does it
   propose anything Claude's plan missed?
4. If yes, flip the flag on your project. If no, leave it off and
   try again on a future cycle.

**Killswitch:** `export SECOND_OPINION_PASS_A_DISABLE=1` turns Pass A
off entirely (skill skips, hook skips its check). Useful when Pass A
produces noise on a particular cycle (e.g., pure refactors).

---

## What's safe vs what's unproven

| Component | Status |
|---|---|
| Force-push / no-verify / dangerous-bash hooks | Proven across many projects; safe |
| Secret-scanner | Proven; safe |
| Pipefail guard (catches `go build \| head` masking exit code) | Proven on real bugs; safe |
| TDD ceremony (4 markers, 3 operator gates) | Proven; safe |
| Phase-aware test policy (no test edits after red confirmed) | Proven; safe |
| Integration guards (commit-time regex) | Mechanism proven; project-specific guard quality is your responsibility |
| `/second-opinion` cross-model review | Proven; safe |
| Disposition matrix (structural improvement on rebuttal) | Mechanical; safe |
| Research packet (spec-phase discipline) | Mechanical; safe |
| Closure check (verifies findings → implementation) | Mechanical; safe |
| Codebase-grep invitation in Codex prompt | Mechanism in place; effectiveness depends on Codex's tool use in your repo |
| **Pass A blind independent design** | **Mechanism validated; codebase-specific value unproven. Validate on your first cycle before flipping the flag.** |

---

## Integration guards — adding your project's invariants

`.tdd/tdd-config.json` `integration_guards` array is a project-level
list of "no API X outside file Y" invariants. The commit gate greps
the repo against each guard on Tier 1 commits and denies on violations
outside `allowed_globs`.

Default array is empty. Add guards as you find bugs that grep could
have caught. Each guard should link to the bug it would have caught.

Example shape:

```json
"integration_guards": [
  {
    "name": "no_direct_db_access_outside_repo_layer",
    "pattern": "(?:Conn|DB)\\.(?:Exec|Query|QueryRow)",
    "severity": "deny",
    "allowed_globs": [
      "internal/repository/**/*.go",
      "internal/migrations/**/*.go",
      "**/*_test.go"
    ],
    "rationale": "All DB calls must route through the repository layer (project ADR #007)"
  }
]
```

See `.claude/rules/go-integration-guards.md` for the decision tree
(test first, type safety second, guard third) and the full schema.

**Important:** guards are FALLBACK protection. If you can write an
integration test or refactor toward type safety to catch the same
class of bug, do that instead. Use guards only when neither option
fits.

---

## Common gotchas

### "Hook denied my edit, what now?"

The deny message tells you which marker is missing or which artifact
is stale. Read the `<claude-directive>` block — it lists the specific
fix.

Most common causes:
- Missing M1 (spec not approved): operator hasn't said `APPROVED SPEC`
- Missing M2 (red proof not done): write tests, capture red-proof.md,
  set marker
- Missing M3 (green not authorized): operator hasn't said
  `APPROVED GREEN`
- Missing M4 (impl not reviewed): operator hasn't said
  `APPROVED IMPLEMENTATION` after seeing the diff
- Stale `/second-opinion` adjudication (>60min): re-run

### "I want to edit a test mid-green"

Phase-aware test policy denies this by default (the documented
"don't edit tests in green phase" rule). Workflow to return to red:
1. Operator authorizes return-to-red explicitly
2. Set `Red phase confirmed: no` in plan
3. Edit the test
4. Re-run, capture new red-proof
5. Set `Red phase confirmed: yes`
6. Operator says `APPROVED GREEN` again
7. Continue

Emergency override: `test_file_policy.allow_after_red_confirmed: true`
in tdd-config.json. Document reason in commit. Not for routine use.

### "The Codex review (`/second-opinion`) returned no output"

Check `.tdd/second-opinion-debug.log` for the actual error. Common
causes:
- Codex CLI not installed (run `make doctor`)
- Codex not authenticated (run `codex login` for ChatGPT auth, or set
  `CODEX_API_KEY` for API-key auth)
- Network timeout (skill exits 0 silently, audit log records the skip)
- Default model `gpt-5.5` requires ChatGPT auth; with API-key auth
  the skill auto-falls-back to `gpt-5.4` (and doctor.sh warns about
  this once)

### "Hook deadlock — I cannot proceed and the documented flow doesn't help"

STOP. Surface to the operator. Do NOT modify the hook script.
Hook scripts are governance infrastructure; patching them mid-cycle
is unauthorized modification.

The escape hatches are:
- Operator flips a config flag in tdd-config.json with reason in
  commit
- Operator sets a killswitch env var
  (`SECOND_OPINION_DISABLE=1`, `TDD_COMMIT_GATE_DISABLE=1`,
  `SECOND_OPINION_PASS_A_DISABLE=1`)
- Real bug → upstream fix

If a deadlock happens, the hook design is wrong, not your workflow.
Report it.

---

## Where to read more

| Topic | File |
|---|---|
| TDD discipline rules | `.claude/rules/go-tdd.md` |
| Full TDD workflow (the 21-step cycle) | `docs/process/tdd_workflow.md` |
| `/second-opinion` v1.6.0 design rationale | `docs/specs/second-opinion-v1.6.0-spec.md` |
| TDD gate redesign rationale | `docs/specs/tdd-gate-conflict-resolution-spec.md` |
| Integration guards | `.claude/rules/go-integration-guards.md` |
| Hook smoke tests | `scripts/tdd-test-hooks.sh` |
| Pack maintenance + design choices | `MAINTAINING.md` |

---

## Summary in one paragraph

Copy `.claude/`, `.tdd/`, `scripts/`, `docs/` into your repo. Set
`project_name` and adjust `tier1_path_regexes` in
`.tdd/tdd-config.json` to match your project's high-stakes paths.
Run `bash scripts/tdd-test-hooks.sh` (expect 86 passing). Use
Claude Code normally — non-Tier-1 work is unaffected; Tier 1 work
follows the documented 3-gate ceremony. Keep v1.6.0 flags off
initially. Flip the disposition-matrix flag in week 1 (zero risk).
Flip the research-packet flag in week 2 if your team is willing.
Validate Pass A on your first real Tier 1 cycle before flipping its
flag. If a hook denies unexpectedly, read the stderr message — every
deny includes the specific fix. Never modify hook scripts to make a
deny go away; STOP and surface to the operator instead.
