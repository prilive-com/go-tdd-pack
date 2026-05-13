# Release Guide — go-claude-starter

**Current release:** **v1.9.0** (shipped 2026-05-13)
**Codename:** Pack No-Discretion Second Opinion Enforcement
**Prior release:** [v1.8.0](#v180--what-shipped) (AST validator + audit-log chain)

This document is for two audiences:

1. **Developers updating an existing project** from a prior starter
   version — see "Update paths" below for your version's
   migration steps.
2. **Maintainers of this starter** — see "Maintaining this guide"
   at the bottom for how to refresh it when the next release ships.

If you're adopting the starter for the FIRST TIME (no prior
version), start at [`docs/AI_DEVELOPER_GUIDE.md`](AI_DEVELOPER_GUIDE.md)
instead. This guide assumes you already have `.claude/`, `.tdd/`,
and `scripts/` installed at some prior version.

---

## v1.9.0 — what shipped

10 acceptance criteria across 7 PRs. The full design is in
[`.tdd/disposition-matrix.md`](../.tdd/disposition-matrix.md) (after
cycle ships). Closes the failure mode where the AI decides "this
change doesn't need /second-opinion" — observed in a real conversation
transcript on 2026-05-12.

### Headline changes

- **`disable-model-invocation: true`** on the `/second-opinion` skill.
  Model cannot invoke the skill via `Skill(second-opinion)`. The
  operator can still call `/second-opinion` manually.
- **Three PreToolUse trigger hooks** (`second-opinion-plan-trigger.sh`,
  `second-opinion-test-trigger.sh`,
  `second-opinion-production-trigger.sh`) — block plan writes, test
  writes, and production .go edits until a matching review-completion
  exists in the typed-exception artifact.
- **Production-edit scope is per-cycle-per-`base_git_sha`** — one
  completion covers all production edits in the cycle until the next
  commit advances HEAD. Then re-blocks.
- **File-list drift detection (`PRODUCTION_SCOPE_DRIFT`)** — closes the
  "I had review for one file; I'll edit another" path.
- **Stop hook** (`session-stop-review.sh`) blocks session end with
  pending obligations; canonical `stop_hook_active` loop-guard.
- **Runner script** (`scripts/tdd/run-second-opinion.sh`) is the only
  legitimate Codex caller. Validates output via jq (not flag-trust)
  to defend against `--output-schema` silent-ignore caveats
  (openai/codex#4181, #15451).
- **Single extended artifact** — no parallel "obligation engine."
  v1.7.0's `post-red-test-edits.json` gains three new `type` values:
  `plan_review_completion`, `test_review_completion`,
  `production_edit_review_completion`. Same v1.8.0 SHA-chained audit
  log.

### Stable error codes added

`PLAN_REVIEW_REQUIRED`, `TEST_REVIEW_REQUIRED`,
`PRODUCTION_EDIT_REVIEW_REQUIRED`, `PRODUCTION_SCOPE_DRIFT`,
`REVIEW_SCOPE_MISMATCH`, `REVIEW_TYPE_MISMATCH`,
`REVIEW_COMPLETION_EXPIRED`, `CODEX_OUTPUT_NON_CONFORMANT`,
`MODEL_NOT_SCHEMA_COMPATIBLE`. See
[`docs/AI_DEVELOPER_GUIDE.md`](AI_DEVELOPER_GUIDE.md) "Stable error
codes" for action recipes.

### Opt-in

Triggers default to OFF. Enable per project in `.tdd/tdd-config.json`:

```jsonc
"second_opinion": {
  "no_discretion": {
    "enabled": true,
    "required_for": {
      "plan_writes": true,
      "test_writes": true,
      "production_edits": true
    }
  }
}
```

### What's NOT in v1.9.0

- No regulatory mapping doc (EU/ISO/NIST). Operator instruction.
- No forbidden-phrases list. `disable-model-invocation: true` is the real fix.
- No Mode B (PreToolUse auto-invokes Codex synchronously). Deferred to v1.10 if operator fatigue measurable.
- No parallel "obligation engine" runtime. Single extended typed-exception artifact.

### From v1.8.0 → v1.9.0

```bash
# 1. Pull the new files.
git fetch starter
git checkout starter/main -- \
  scripts/tdd/run-second-opinion.sh \
  scripts/tdd/runner-context-pack.sh \
  scripts/tdd/hash-review-scope.sh \
  scripts/tdd/validate-review-completion.sh \
  scripts/tdd/_lib_redact_patterns.sh \
  .claude/hooks/second-opinion-plan-trigger.sh \
  .claude/hooks/second-opinion-test-trigger.sh \
  .claude/hooks/second-opinion-production-trigger.sh \
  .claude/hooks/session-stop-review.sh \
  .claude/skills/second-opinion/SKILL.md \
  .claude/rules/go-tdd.md \
  .tdd/templates/review-completion.schema.json \
  scripts/tdd/ast/validator.go \
  CLAUDE.md docs/AI_DEVELOPER_GUIDE.md docs/RELEASE_GUIDE.md

# 2. Make new scripts executable.
chmod +x scripts/tdd/run-second-opinion.sh \
         scripts/tdd/runner-context-pack.sh \
         scripts/tdd/hash-review-scope.sh \
         scripts/tdd/validate-review-completion.sh \
         .claude/hooks/second-opinion-plan-trigger.sh \
         .claude/hooks/second-opinion-test-trigger.sh \
         .claude/hooks/second-opinion-production-trigger.sh \
         .claude/hooks/session-stop-review.sh

# 3. Register hooks in .claude/settings.json (the three PreToolUse
# triggers + the Stop hook). See settings.json in the starter for
# the exact entries.

# 4. (Optional) Enable in your project's .tdd/tdd-config.json:
#   second_opinion.no_discretion.enabled = true
# Defaults to false (backward compatible).

# 5. Verify install.
bash scripts/tdd-test-hooks.sh 2>&1 | tail -3
# Expect: Results: 554 passed, 0 failed
```

### Behavioral changes (when opted in)

- Every plan write blocks until a fresh `plan_review_completion` exists.
- Every test write blocks unless v1.7.0 typed exception covers it OR a fresh `test_review_completion` exists.
- Every production .go edit blocks first edit per `base_git_sha` until a `production_edit_review_completion` exists; subsequent edits in the cycle unblock until the next commit boundary.
- `Skill(second-opinion)` model invocation is rejected at the Claude Code runtime level.

---

## v1.8.0 — what shipped

8 acceptance criteria across 9 changed files. The full design is in
[`docs/specs/ast-validator-and-audit-integrity-v1.8.0-spec.md`](specs/ast-validator-and-audit-integrity-v1.8.0-spec.md).
Per-finding adjudication for the 7 `/second-opinion` rounds is in
the cycle's `.tdd/disposition-matrix.md` (committed for traceability).

### Headline changes

- **Go AST helper** at `scripts/tdd/ast/validator.go` — invoked from
  the bash validator library when `go` is on PATH. Four subcommands:
  `import-block-check`, `mech-sig-prop-check`,
  `compile-fix-scope-check`, `schema-predicate-check`. Each reads a
  unified diff on stdin, emits a JSON report on stderr, exits 0/1/2.
- **Validator AND-gates regex + AST** — both must pass. AST is
  STRICTER (catches more); regex stays as defense-in-depth and as
  the no-Go fallback. This means a successful AST install can
  ONLY tighten governance, never loosen it.
- **NEW exception type** `schema_predicate_correction` —
  AST-validated pure rename of `--old-name` → `--new-name` across
  test predicates. Any other identifier change rejects. Operators
  opt-in by adding the type to `exception_types` in
  `.tdd/tdd-config.json`.
- **Per-cycle exception count cap** — `max_per_cycle` (default 5;
  0 = no cap). Exceeding the cap disables typed exceptions for the
  cycle until either reverting to red phase or raising the cap with
  documented reason.
- **Audit-log sha-chain integrity** — every line in
  `.tdd/audit/<cycle>.jsonl` carries `prev_sha = sha256(previous
  line)`. New helper `scripts/tdd/verify-audit-chain.sh <cycle-id>`
  walks the file and detects tampering. Hook fails closed for typed
  exceptions on chain mismatch OR on missing audit log when approved
  exceptions exist OR on mismatched grant-event ID set.
- **Graceful degradation** — when `go` is absent OR
  `TDD_AST_VALIDATOR_DISABLE=1`, validator falls back to v1.7.0
  regex behavior with a stderr warning. The `schema_predicate_correction`
  type is the only exception: it has NO regex fallback and fails
  closed when AST is unavailable.

### What this closes

Five deferred items from the v1.7.0 disposition matrix:

| v1.7.0 deferred item | Closed in v1.8.0 by |
|---|---|
| AST-based validation (regex limitations) | AC1 + AC2 — Go AST helper + validator dispatch |
| `schema_predicate_correction` exception type | AC3 |
| `compile_fix_only` AST scope (regex word-boundary) | AC2 — `compile-fix-scope-check` subcommand uses AST identifier matching |
| Per-cycle exception count caps | AC4 |
| Audit-log integrity (was trust-only) | AC5 |

### What's still deferred (v1.9 backlog)

| Item | Why deferred |
|---|---|
| Pre-built AST binary detection | `go run` cold-start ~300ms acceptable for v1.8.0; v1.9 will detect a binary at `scripts/tdd/ast/validator` |
| Multi-line schema renames | Current `schema-predicate-check` is line-by-line; multi-line refactors must be split |
| External audit head pin | Sha-chain + grant-ID-set check covers most truncation; an external head hash would close the last-line edit edge case |
| Audit log archival/rotation | Log grows unbounded per cycle; v1.9 candidate: `cycle_close` event + auto-archive on green commit |
| Encrypted/signed audit log | Sha-chain detects unsophisticated tamper; doesn't defend against a compromised host. v2.0+. |
| AST helper sandboxing | `CLAUDE_PLUGIN_ROOT`-based path resolution for `go run` script discovery |

---

## Compatibility

- **All v1.7.0 artifacts continue to work.** v1.8.0 is additive:
  new fields default safely when absent. Approved exception entries
  written by v1.7.0 grant helper still validate; their audit lines
  lack `prev_sha` and are treated as pre-v1.8 history (one-shot
  warning, chain check resumes from the next prev_sha-bearing line).
- **The legacy `allow_after_red_confirmed` boolean** still works
  with the v1.7.0 deprecation warning. Removal still planned for
  v2.0.0.
- **CI artifacts** (`.gitlab-ci.yml`, `.github/workflows/ci.yml`)
  unchanged. v1.8.0 changes only `.tdd/tdd-config.json` (additive),
  the hook script, the validator library, the grant helper, and adds
  two new files (`scripts/tdd/ast/validator.go`,
  `scripts/tdd/verify-audit-chain.sh`).

---

## Pre-update checklist

Before merging the v1.8.0 update into your project:

```bash
# 1. Note your current version. Should be in commit log or
# .claude/VERSION if you tracked it.
git log --oneline | grep -E 'v1\.[0-9]+\.[0-9]+|chore: adopt'

# 2. Confirm baseline smoke is clean BEFORE the update.
bash scripts/tdd-test-hooks.sh 2>&1 | tail -3
# Expect a "Results: N passed, 0 failed" matching your prior version
# (~426 for v1.6.2, ~469 for v1.7.0).

# 3. Ensure no in-flight Tier 1 cycle is mid-flow. Check:
grep -E '^(Human approved spec|Red phase confirmed|Green phase authorized|Implementation reviewed):' .tdd/current-plan.md 2>/dev/null
# If any marker is "yes" without "Implementation reviewed: yes",
# finish or abandon the cycle BEFORE updating. Hook semantics may
# shift mid-cycle if you don't.

# 4. Ensure `go` is installed and ≥ 1.26.2 (NEW v1.8.0 hard dep
# for the AST helper).
go version
# v1.8.0 also works without Go installed — validator falls back to
# regex-only with a stderr warning. But AST gives you the real
# v1.8.0 governance benefits.

# 5. Back up your tdd-config.json (you'll re-merge customizations).
cp .tdd/tdd-config.json .tdd/tdd-config.json.bak
```

---

## Update paths

Pick the section matching your CURRENT version. Each section is
self-contained — apply only your version's steps; the result is
v1.8.0 across the board.

### From v1.7.0 → v1.8.0

Smallest jump. v1.7.0 already has the typed-exception system; v1.8.0
adds AST validation + audit chain on top.

```bash
# 1. Pull the new files.
git fetch starter
git checkout starter/main -- \
  scripts/tdd/ast/validator.go \
  scripts/tdd/verify-audit-chain.sh \
  scripts/tdd/_lib_test_edit_exception.sh \
  scripts/tdd/grant-test-edit-exception.sh \
  .claude/hooks/require-tdd-state.sh \
  .claude/rules/go-tdd.md \
  docs/specs/ast-validator-and-audit-integrity-v1.8.0-spec.md \
  docs/AI_DEVELOPER_GUIDE.md \
  docs/RELEASE_GUIDE.md

# 2. Mark verify-audit-chain.sh executable.
chmod +x scripts/tdd/verify-audit-chain.sh

# 3. Merge tdd-config.json. Two new fields under
# `test_file_policy.post_red_mechanical_update`:
#   - max_per_cycle: 5      (NEW; 0 = no cap)
#   - exception_types       (extend with "schema_predicate_correction"
#                            if you want the new type)
# See docs/AI_DEVELOPER_GUIDE.md "Setup" §4 for the full block.

# 4. Verify install.
make doctor
go run scripts/tdd/ast/validator.go --version   # tdd-ast-validator v1.8.0
bash scripts/tdd-test-hooks.sh 2>&1 | tail -3   # Results: 520 passed, 0 failed

# 5. Commit.
git add .
git commit -m "chore: update go-claude-starter to v1.8.0"
```

**Behavioral changes:**

- Test edits under approved exceptions are now AST-validated when
  Go is on PATH. Some edits that passed v1.7.0's regex check may
  reject under AST (which is intentionally stricter). Read the
  stderr `AST REPORT` to see the specific reason.
- `max_per_cycle: 5` (default) caps approved exceptions per cycle.
  If your team typically grants 6+ per cycle, set
  `max_per_cycle: 0` (no cap) OR the higher number with documented
  reason in the same commit.
- The hook now requires an audit log file when approved exceptions
  exist. If you migrated v1.7.0 artifacts, run
  `scripts/tdd/grant-test-edit-exception.sh --approve` again to
  regenerate the audit log with `prev_sha` chained correctly.

### From v1.6.x → v1.8.0

Two-step jump. Apply v1.7.0 changes first, then v1.8.0.

```bash
# Step A: bring in v1.7.0 (typed test-edit exceptions).
git fetch starter
git checkout starter/main -- \
  scripts/tdd/_lib_test_edit_exception.sh \
  scripts/tdd/grant-test-edit-exception.sh \
  .claude/hooks/require-tdd-state.sh \
  .claude/rules/go-tdd.md \
  docs/specs/typed-test-edit-exceptions-v1.7.0-spec.md
chmod +x scripts/tdd/grant-test-edit-exception.sh

# Step B: gitignore per-cycle artifacts.
cat >> .gitignore <<'EOF'

# v1.7.0 typed test-edit exceptions (per-cycle, local)
.tdd/exceptions/
.tdd/audit/
EOF

# Step C: merge tdd-config.json. Add the post_red_mechanical_update
# block under test_file_policy. Default `enabled: false` is safe.
# See docs/AI_DEVELOPER_GUIDE.md "Setup" §4.

# Step D: now apply v1.7.0 → v1.8.0 from the section above.
```

**Behavioral changes (v1.6.x → v1.7.0 layer):**

- New typed-exception system available but `enabled: false` by default.
  Existing `allow_after_red_confirmed` boolean still works.
- When you flip `enabled: true`, the boolean still works alongside
  but emits a stderr deprecation warning each time it's consulted
  (rate-limited to once per hook invocation).
- Test-file edits after `Red phase confirmed: yes` now go through
  the typed-exception system (when enabled) OR fall back to the
  legacy boolean.

### From v1.3.x – v1.5.x → v1.8.0

Three-step jump (v1.3 → v1.6 → v1.7 → v1.8). The v1.3 → v1.6
migration is documented in the legacy
[`docs/DEVELOPER_UPDATE_NOTES.md`](DEVELOPER_UPDATE_NOTES.md) (now
historical; covers the marker rename, integration guards,
`/second-opinion` v1.6.0 introduction).

Walk through:

1. Apply v1.3 → v1.6 changes per legacy `DEVELOPER_UPDATE_NOTES.md`.
   Specifically: run `bash scripts/migrate-tdd-markers.sh` once to
   rename M3 + add M4 in any in-flight plan.
2. Verify smoke clean at v1.6.x level.
3. Apply v1.6.x → v1.8.0 from the section above.

If you've been on v1.3.x for a while, consider re-adopting clean
from `docs/AI_DEVELOPER_GUIDE.md` "Path A — New project from this
starter" — copy the new `.claude/`, `.tdd/`, `scripts/`, `docs/`
fresh, then re-merge your project's customizations
(`tier1_path_regexes`, `integration_guards`, `allowed-modules.txt`,
`project_name`).

---

## Post-update verification

Run the diagnostic runbook from
[`docs/AI_DEVELOPER_GUIDE.md`](AI_DEVELOPER_GUIDE.md) "Verify
install (diagnostic runbook)" — all 8 steps. Critical ones:

```bash
# AST helper compiles + runs (NEW in v1.8.0).
go run scripts/tdd/ast/validator.go --version
# Expect: tdd-ast-validator v1.8.0

# Smoke suite at full count.
bash scripts/tdd-test-hooks.sh 2>&1 | tail -3
# Expect: Results: 520 passed, 0 failed

# Audit chain helper.
bash scripts/tdd/verify-audit-chain.sh nonexistent-cycle
echo $?
# Expect: 0 (vacuously OK on missing log)
```

If smoke passes < 520, your update is incomplete. Re-check that all
files from the "v1.7.0 → v1.8.0" section above are present at the
expected versions.

---

## What to read next

After updating, **read these in order**:

1. [`docs/AI_DEVELOPER_GUIDE.md`](AI_DEVELOPER_GUIDE.md) — the
   onboarding guide. Even if you've used the pack for months, the
   v1.8.0 sections (typed exceptions, AST validator, audit chain,
   killswitch table, stable-error-codes table) are new.
2. [`docs/specs/ast-validator-and-audit-integrity-v1.8.0-spec.md`](specs/ast-validator-and-audit-integrity-v1.8.0-spec.md)
   — design rationale for v1.8.0. Read this if you want to extend
   the AST helper or add a new exception type.
3. [`.claude/rules/go-tdd.md`](../.claude/rules/go-tdd.md) — refreshed
   for v1.8.0 with the killswitch decision table, `max_per_cycle`
   cap, audit-chain note, and `schema_predicate_correction`
   workflow.
4. The cycle's disposition matrix at `.tdd/disposition-matrix.md`
   — committed for traceability. 7 review rounds, 25 ACCEPT + 2
   PUSHBACK, with per-finding rationale.

If you're going to grant `schema_predicate_correction` exceptions
to your AI assistant, read the AST subcommand contract in the spec
doc — particularly the "Strict" / "Lenient when" notes for each
subcommand. The validator is intentionally conservative; some
edits that "look like a rename" will reject because they include
literal-value or operator changes.

---

## Killswitches added in v1.8.0

For the full reference, see
[`docs/AI_DEVELOPER_GUIDE.md`](AI_DEVELOPER_GUIDE.md)
"Killswitches reference". The v1.8.0-new ones:

| Env var | Effect | Use when |
|---|---|---|
| `TDD_AST_VALIDATOR_DISABLE=1` | Fall back to regex-only validator | AST has a known false-positive on a legitimate edit; document in commit |

All v1.7.0 killswitches (`TEST_EDIT_EXCEPTION_DISABLE`, etc.) are
unchanged.

---

## Rollback

If v1.8.0 misbehaves on your project:

```bash
# Revert the update commit:
git revert HEAD
# OR for a single-file rollback:
git checkout <prev-version-sha> -- \
  .claude/hooks/require-tdd-state.sh \
  scripts/tdd/_lib_test_edit_exception.sh \
  scripts/tdd/grant-test-edit-exception.sh
```

The v1.8.0 additions (`scripts/tdd/ast/validator.go`,
`scripts/tdd/verify-audit-chain.sh`) are inert without the
hook + library wiring — you can leave them on disk after rollback;
they have no effect.

When you rollback, your v1.7.0 artifacts (approved exceptions,
audit log) keep working. v1.7.0 ignores the v1.8.0-only fields
(`prev_sha`, `head_at_approval` if those were set) — additive
schema design.

If rollback is necessary, please file an issue describing what
broke. v1.8.0 was reviewed across 7 `/second-opinion` rounds with
25 P0/P1 findings ACCEPTED + FIXED — concrete bypasses are
unlikely, but environment-specific issues (Go toolchain quirks, BSD
vs GNU coreutils edge cases) can still happen.

---

## Maintaining this guide

For the maintainer of this starter — when the NEXT release ships
(v1.9.0 or beyond), update this file as follows:

### Update steps

1. **Bump the header.** Change `Current release: v1.8.0` →
   `v1.9.0`, update the codename and date.
2. **Add a new "v1.9.0 — what shipped" section** at the top of
   "what shipped" (push v1.8.0 down). Use the v1.8.0 section as a
   template:
   - Headline changes (4-6 bullets).
   - "What this closes" table — items from the v1.8.0 deferred list.
   - "What's still deferred" table — fresh v2.0 backlog.
3. **Update the "Compatibility" section** if v1.9.0 changes any
   schema (otherwise, append a sentence: "All v1.8.0 artifacts
   continue to work").
4. **Add a new update path** at the top of "Update paths":
   `### From v1.8.0 → v1.9.0` with the cherry-pick commands and
   the behavioral-changes list.
5. **Push down the older paths.** Keep `From v1.7.0 → v1.8.0` and
   `From v1.6.x → v1.8.0` as historical references; rename them
   "via v1.8.0" if necessary so they chain through the new release.
6. **Update post-update verification** if the smoke test count
   changed (520 → new number).
7. **Add new killswitches** to the "Killswitches added in v1.X.X"
   section. Keep prior-release killswitches in the
   `AI_DEVELOPER_GUIDE.md` reference table; this section only
   lists what's NEW per release.
8. **Refresh "What to read next"** if a new spec doc was added or
   `go-tdd.md` was rewritten.
9. **Verify the doc.** Run the diagnostic runbook commands from
   `AI_DEVELOPER_GUIDE.md` against the new release. Ensure every
   command in this guide still works (`go run` paths, `bash
   scripts/...` invocations, expected output strings).
10. **Commit.** Use `chore: refresh release guide for v1.X.0`.

### What to NOT change

- Do NOT delete prior-release "what shipped" sections. They're
  historical record. After ~3 releases, archive the oldest into
  `docs/archive/release-history.md` rather than deleting in place.
- Do NOT remove the legacy `DEVELOPER_UPDATE_NOTES.md` reference.
  Projects on v1.3-v1.5 still need that path.
- Do NOT change the "What this is NOT" or "What this starter gives
  you" sections in `AI_DEVELOPER_GUIDE.md` from this guide.
  Cross-doc updates should be intentional, not incidental.

### When to fork a new release-notes file

If a release introduces breaking changes (e.g., v2.0.0 removes the
`allow_after_red_confirmed` boolean), spin up
`docs/UPGRADE_TO_V2.md` instead of cramming it into this file.
This guide is for INCREMENTAL minor-version updates; major-version
upgrades deserve their own doc.

---

## TL;DR

You're on the v1.8.0 release. The pack now AND-gates regex with
Go AST validation, caps per-cycle exceptions at 5, and chains the
audit log with sha256. Update from v1.7.0 by cherry-picking 5
files + verifying with `go run scripts/tdd/ast/validator.go
--version` and the 520-test smoke. Read `docs/AI_DEVELOPER_GUIDE.md`
after updating; the v1.8.0 sections (stable-error-codes table,
killswitch reference, diagnostic runbook) are new even for
existing users. Rollback is single-commit-revert; v1.8.0 additions
are inert without the hook wiring.
