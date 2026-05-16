# Prilive Go TDD Pack v2.0 — Final Implementation Spec

**Status:** Approved, building MVP.
**Date:** 2026-05-16
**Scope:** Replaces v1.9.x ceremony-and-gates architecture with continuous silent peer review between Claude and Codex.

---

## 1. The vision in one paragraph

When Claude writes or edits code in a Go project, a background runner spawns Codex CLI in the user's real project directory with the same access Claude has — read everything, run any command, fetch the web. The one rule, enforced by Codex's system prompt: do not modify project files. Codex reviews the diff, returns findings, the runner injects them into Claude's next turn as a system reminder, Claude addresses them silently. The loop continues until Codex approves OR 4 rounds with disagreement, at which point the user sees a single A/B choice. The user never sees ceremony, approval markers, plan files, or per-edit reviews. They see the finished code or one question.

## 2. What's NOT in this design (rejected by user)

- ❌ No `tier1_path_regexes` (every change reviewed, not just Tier 1)
- ❌ No `no_discretion` config (no operator approval markers)
- ❌ No plan/red/green/commit ceremony
- ❌ No `Human approved spec: yes` markers
- ❌ No `CYCLE_ABANDONED.txt` manual escape
- ❌ No blocking PreToolUse hooks (only async PostToolUse)
- ❌ No git worktree / disposable copy (Codex runs in real project)
- ❌ No `--sandbox read-only` or `--sandbox workspace-write` (full access)

## 3. The 4 critical bug fixes vs the prior consultant draft

Documented inline. All applied below.

| # | Bug | Fix |
|---|---|---|
| 1 | Spec omitted `--sandbox` thinking that meant "no sandbox" — actually defaults to `read-only` (blocks commands) | Explicit `--sandbox danger-full-access --ask-for-approval never` on every codex invocation |
| 2 | Default `reasoning_effort = "xhigh"` undocumented in Codex CLI | Default to `"high"`; document xhigh as opt-up if user's plan supports it |
| 3 | Migration deleted v1.9 state but not v1.9 hook scripts | Migration step explicitly removes all v1.9 `.claude/hooks/*.sh` and replaces `.claude/settings.json` |
| 4 | Brittle `transcript_path` capture for Claude's response | Use `asyncRewake: true` (verified in Claude Code 2.1+ docs) — runner exits 2 with findings; Claude wakes |

## 4. Architecture

### 4.1 Event flow

```
USER PROMPT
    │
    ▼
CLAUDE EDIT / WRITE / MULTIEDIT
    │
    ├──► PostToolUse hook: post-edit-review.sh (async: true)
    │        │
    │        └──► (background, detached) review-runner.sh
    │                  │
    │                  ├──► coalesce.sh — wait 5s of quiet
    │                  ├──► git diff HEAD > .tdd/reviews/<cycle>/diff.patch
    │                  ├──► codex-round1.sh
    │                  │      codex exec --sandbox danger-full-access
    │                  │                  --ask-for-approval never
    │                  │                  --cd $PROJECT_DIR
    │                  │                  --output-schema schema.json
    │                  │                  -o round-1.json
    │                  │      ├── parse round-1.json
    │                  │      ├── write findings to state.json
    │                  │      └── if verdict=approve → finalize
    │                  ├──► (else) wait for Claude's response, then codex-round-n.sh
    │                  └──► loop until approve OR max_rounds → escalate
    │
    └──► PostToolUse hook: inject-findings.sh (sync, fast)
             │
             └──► reads state.json
                   │
                   ├── pending findings? → emit additionalContext (system reminder)
                   ├── escalation pending? → emit the A/B/V message
                   └── else → return {}
```

### 4.2 Trust model

Codex runs with the **same access as Claude** — `--sandbox danger-full-access`. There is no syscall-level boundary. The "no project writes" rule is enforced via:

1. **System prompt** (`prompts/codex-system.md`) — the rule is stated in caps, with examples, and with instruction to copy-to-/tmp if Codex needs to test a hypothesis that involves modifying a file.
2. **Smoke test** (`test/smoke-codex-respects-no-write-rule.sh`) — empirically verifies Codex doesn't modify project files even when reviewing a buggy file it would be tempted to fix. Run on every release.
3. **Optional belt-and-suspenders**: runner snapshots project file hashes before each Codex round; if any project file hash changes mid-round, abort the cycle with `failed: codex violated no-write rule` and log the attempt. (Recommended but defer if v2.0.0 must ship faster.)

**Honest risk framing**: prompt-only enforcement means a sufficiently crafted attacker-controlled file (a contributor's malicious comment with prompt-injection content) could attempt to subvert the rule. The system prompt is strong; the smoke test catches violations. Risk is low but non-zero. Operator accepts this trade-off explicitly.

### 4.3 Capability parity

| Capability | Claude | Codex (under this pack) |
|---|---|---|
| Read any project file | yes | yes |
| Run any shell command | yes | yes |
| Network / web search | yes | yes (`--search`) |
| Write outside project (`/tmp`, `$HOME`) | yes | yes |
| **Write/edit/delete files inside project** | yes | **NO (prompt-enforced)** |
| MCP tools | yes | no (would break `--output-schema` per openai/codex#15451) |

## 5. Configuration: `tdd-pack.toml`

```toml
# Prilive Go TDD Pack v2.0

[review]
max_rounds = 4
coalesce_ms = 5000
stop_hook_fingerprint = true
max_codex_calls_per_cycle = 8
max_cycle_minutes = 30

[codex]
# Empty model = let Codex CLI pick its current default. Pin only if needed.
model = ""

# Default "high" (documented). Opt up to "xhigh" if your Codex auth supports it
# (verify via `codex exec -c model_reasoning_effort="xhigh" --help` or
# by attempting a call; on auth-unsupported plans you may get an error).
reasoning_effort = "high"

# Live web search. Requires Codex CLI ≥ recent version with --search.
web_search = "live"

# NOTE: No sandbox setting. The runner passes
# --sandbox danger-full-access --ask-for-approval never to give Codex the same
# access Claude has. The "no project writes" rule is enforced in the system
# prompt (prompts/codex-system.md).

[tdd]
enforce_as = "criterion"   # criterion | off

[severity]
min_surface = "minor"
must_address = "major"

[gate]
git_pre_commit = false
git_pre_push = false

[audit]
debates_jsonl = ".tdd/reviews/debates.jsonl"
keep_transcripts = true

[disable]
env_var = "PRILIVE_REVIEW_DISABLE"
```

## 6. File layout (final)

```
go-claude-forge/                            # repo root (or go-tdd-pack, per naming decision)
├── .claude-plugin/
│   └── plugin.json                         # plugin manifest, version "2.0.0"
├── tdd-pack.toml                           # default config (copied on install)
├── README.md                                # public-facing (replaces v1.x README)
├── hooks/
│   ├── settings.json                       # hook registration
│   ├── post-edit-review.sh                 # async PostToolUse launcher (< 50ms)
│   ├── inject-findings.sh                  # sync hook, emits additionalContext
│   ├── stop-fingerprint.sh                 # Stop hook, fires runner if tree changed
│   └── session-start.sh                    # SessionStart, offers /continue
├── runner/
│   ├── review-runner.sh                    # main background orchestrator
│   ├── codex-round1.sh                     # round 1 (schema-enforced)
│   ├── codex-round-n.sh                    # rounds 2-N (verdict-string)
│   ├── coalesce.sh                         # 5s debounce, single-flight via flock
│   ├── extract-verdict.sh                  # parses APPROVE/REQUEST_CHANGES
│   └── escalate.sh                         # renders escalation A/B/V message
├── commands/
│   ├── show-review.md                      # /show-review
│   ├── continue.md                         # /continue
│   ├── abandon.md                          # /abandon
│   ├── status.md                           # /status
│   └── install-commit-gate.md              # /install-commit-gate (opt-in)
├── prompts/
│   ├── codex-system.md                     # SYSTEM PROMPT (contains no-write rule)
│   ├── codex-round1-user.md                # round 1 user prompt template
│   └── codex-round-n-user.md               # rounds 2-N template
├── schemas/
│   ├── findings-round1.schema.json         # Codex round 1 output
│   └── state.schema.json                   # validates .tdd/reviews/state.json
├── templates/
│   └── git-hooks/
│       ├── pre-commit.sh                   # opt-in shell git hook
│       └── pre-push.sh
├── docs/
│   ├── V2_IMPLEMENTATION_SPEC.md           # this document
│   ├── ARCHITECTURE.md
│   ├── MIGRATION-from-v1.9.md
│   ├── VERIFY.md
│   └── TROUBLESHOOTING.md
└── test/
    ├── smoke-happy-path.sh
    ├── smoke-findings-then-converge.sh
    ├── smoke-escalation.sh
    ├── smoke-codex-unavailable.sh
    └── smoke-codex-respects-no-write-rule.sh   # CRITICAL — see §4.2
```

At runtime in an adopter's project:

```
<user-repo>/
├── tdd-pack.toml                           # user's config
└── .tdd/
    └── reviews/
        ├── state.json                      # active cycle pointer
        ├── debates.jsonl                   # append-only audit log
        └── <cycle_id>/
            ├── diff.patch
            ├── round-1.json                # schema-valid Codex output
            ├── round-2.txt                 # free-form rounds 2+
            ├── claude-response-2.txt       # captured between rounds
            └── codex-session-id            # for codex exec resume
```

**No `.tdd/worktrees/`.** No copy of the repo. Codex reads/runs against the real project.

## 7. Implementation order (MVP first, extensions marked)

**MVP — happy path only (~10 files, this is what we build first):**

1. `tdd-pack.toml` — default config
2. `hooks/settings.json` — hook registration
3. `hooks/post-edit-review.sh` — async launcher
4. `runner/coalesce.sh` — debounce
5. `prompts/codex-system.md` — system prompt with no-write rule
6. `prompts/codex-round1-user.md` — round 1 user template
7. `schemas/findings-round1.schema.json` — schema
8. `runner/codex-round1.sh` — round 1 invocation
9. `runner/review-runner.sh` — orchestrator (round-1 only for MVP)
10. `hooks/inject-findings.sh` — context injection

**Phase 2 — multi-round + escalation:**

11. `prompts/codex-round-n-user.md`
12. `runner/codex-round-n.sh`
13. `runner/extract-verdict.sh`
14. `hooks/stop-fingerprint.sh`
15. `runner/escalate.sh`
16. `hooks/session-start.sh`

**Phase 3 — UX & smoke:**

17. `commands/*.md` (5 slash commands)
18. `test/*.sh` (5 smoke tests, INCLUDING the no-write rule test)

**Phase 4 — release:**

19. `templates/git-hooks/*` (opt-in)
20. `docs/MIGRATION-from-v1.9.md`
21. `docs/VERIFY.md` (record the §10 verification results)
22. README rewrite
23. v1.x cleanup (delete `.claude/hooks/*.sh`, `.tdd/templates/`, `.tdd/presets/`, old smoke tests; replace `.claude/settings.json`)

## 8. Critical code: the Codex invocation (rounds 1 & 2+)

### Round 1 (schema-enforced)

```bash
# In runner/codex-round1.sh
CODEX_FLAGS=()
[[ -n "${MODEL}" ]] && CODEX_FLAGS+=(--model "${MODEL}")
[[ "${WEB_SEARCH}" == "live" ]] && CODEX_FLAGS+=(--search)
CODEX_FLAGS+=(-c "model_reasoning_effort=\"${REASONING}\"")
CODEX_FLAGS+=(--sandbox danger-full-access)        # ★ THE FIX
CODEX_FLAGS+=(--ask-for-approval never)            # ★ THE FIX
CODEX_FLAGS+=(--output-schema "${SCHEMA}")
CODEX_FLAGS+=(-o "${CYCLE_DIR}/round-1.json")
CODEX_FLAGS+=(--skip-git-repo-check)
CODEX_FLAGS+=(--cd "${PROJECT_DIR}")

codex exec "${CODEX_FLAGS[@]}" <<EOF
$(cat "${SYSTEM_PROMPT}")

---

${USER_PROMPT}
EOF
```

### Rounds 2+ (free-form, verdict string)

```bash
# In runner/codex-round-n.sh
CODEX_FLAGS=()
[[ -n "${MODEL}" ]] && CODEX_FLAGS+=(--model "${MODEL}")
[[ "${WEB_SEARCH}" == "live" ]] && CODEX_FLAGS+=(--search)
CODEX_FLAGS+=(--sandbox danger-full-access)        # ★ THE FIX
CODEX_FLAGS+=(--ask-for-approval never)            # ★ THE FIX
CODEX_FLAGS+=(--skip-git-repo-check)
CODEX_FLAGS+=(--cd "${PROJECT_DIR}")

# NO --output-schema, NO -o (openai/codex#14343, #12538 — broken on resume).
codex exec resume "${SESSION_ID}" "${CODEX_FLAGS[@]}" "${PROMPT}" \
  > "${CYCLE_DIR}/round-${ROUND}.txt" \
  2>/dev/null
```

## 9. The system prompt (load-bearing security boundary)

This is `prompts/codex-system.md` — the file that holds the no-write rule.

```markdown
You are a senior code reviewer for a Go project.

# Your access

You are running on the user's real machine, in the real project directory,
with the same access as the user's main coding agent (Claude Code):
  - Read every file in the project
  - Run any shell command (go test, go vet, grep, curl, etc.)
  - Search the web and fetch URLs
  - Write to /tmp, $HOME, or anywhere OUTSIDE the project directory

# THE RULE — read this twice

You MUST NOT write, edit, create, or delete any file inside the project
directory, except for files under .tdd/ (the pack's own bookkeeping).

This is the only rule. It is not optional. Even if you find a bug you could
fix in two seconds — do not fix it. Your job is to report findings. The other
agent (Claude) does the fixing.

If you need to test a hypothesis that requires modifying a file:
  - copy the file to /tmp first
  - modify the copy there
  - never touch the original

If a tool call would write to a project file, abort that tool call and
instead add a finding describing what you would have changed and why.

# Your job

Review a single change Claude just made. The author cares about correctness,
test discipline, and clarity.

Reviewing rules:

1. Default to silence. Small, clearly-correct changes deserve approval, not
   nits.
2. Speak up on real issues: bugs, missing tests for production code, security
   problems, broken contracts, missing error handling, race conditions.
3. Test discipline: if a non-test .go file changes and there is no
   corresponding test change in the same package, that is a finding at
   severity "major" with category "test_quality".
4. Style is severity "nit". Don't bother unless egregious.
5. Be honest about disagreement. If Claude pushes back with sound reasoning,
   downgrade or retract. If pushback is weak, hold the finding.
6. Use the internet when it helps — current Go docs, CVE checks, library
   issues.

Severity scale:
  - blocker: cycle MUST NOT converge while this exists
  - major:   should be fixed; missing tests for production code lives here
  - minor:   worth mentioning; non-blocking
  - nit:     style preference; only mention if egregious

Category enum:
  correctness | test_quality | design | security | maintainability | docs | other

Always be terse. The user does not see your reviews directly — they go to
Claude. Findings should be one short paragraph each, max.
```

## 10. Verification checklist (run before tagging v2.0.0)

Document results in `docs/VERIFY.md`.

1. **`async: true` works** — Claude Code 2.1.0+ documented. Verify locally: PostToolUse returns in <100ms.
2. **`asyncRewake` works** — verify it actually wakes Claude with a system reminder on exit 2.
3. **`--sandbox danger-full-access` accepted by codex exec** — verified via `codex exec --help`.
4. **`additionalContext` injects on Edit/Write** — Anthropic #18427 cautions this may be unreliable. UserPromptSubmit mirror catches.
5. **`--search` enables live web** — verified via `codex exec --help`.
6. **`reasoning_effort` accepts your config value** — try a call.
7. **`codex exec resume` accepts `--sandbox`, `--cd`, `--search`** — verify.
8. **`flock` available** — macOS may need `brew install flock`.
9. **Model auto-defaulting works** — `model = ""` → CLI uses current default.
10. **THE NO-WRITE RULE HOLDS** — `test/smoke-codex-respects-no-write-rule.sh` passes empirically.

## 11. Migration from v1.9.x

```bash
# 1. Backup
cp -r .tdd .tdd.v1.9.backup
cp -r .claude .claude.v1.9.backup

# 2. Pull v2.0
git pull origin main   # or: claude plugin update prilive-tdd-pack

# 3. DELETE v1.9 hook scripts (NOT just state)
rm -f .claude/hooks/require-second-opinion.sh
rm -f .claude/hooks/require-tdd-state.sh
rm -f .claude/hooks/gate-tier1-commit.sh
rm -f .claude/hooks/second-opinion-plan-trigger.sh
rm -f .claude/hooks/second-opinion-test-trigger.sh
rm -f .claude/hooks/second-opinion-production-trigger.sh
rm -f .claude/hooks/second-opinion-bash-pretrigger.sh
rm -f .claude/hooks/second-opinion-posttool-backstop.sh
rm -f .claude/hooks/session-stop-review.sh
rm -f .claude/hooks/route-to-tdd.sh
rm -f .claude/hooks/require-tdd-state.sh

# 4. DELETE v1.9 state and obsolete artifacts
rm -rf .tdd/current-plan.md .tdd/CYCLE_ABANDONED.txt .tdd/exceptions/
rm -rf .tdd/cycles/ .tdd/active .tdd/abandoned/ .tdd/codex/
rm -rf .tdd/templates/ .tdd/presets/

# 5. Replace .claude/settings.json with v2.0's hook registration
cp hooks/settings.json .claude/settings.json

# 6. Unset killswitches
unset SECOND_OPINION_DISABLE TDD_COMMIT_GATE_DISABLE TDD_GIT_HOOK_DISABLE

# 7. Verify
ls hooks/ runner/ prompts/ schemas/ commands/   # all should exist
test -f tdd-pack.toml || cp tdd-pack.toml.default tdd-pack.toml
```

## 12. Definition of done

v2.0.0 ships when ALL of these are true:

1. All files in §6's layout exist and are non-empty.
2. All 5 smoke tests in §6 (test/) pass on macOS and Linux — including `smoke-codex-respects-no-write-rule.sh` (the critical one).
3. The 10 verification checks in §10 are documented in `docs/VERIFY.md`.
4. `docs/MIGRATION-from-v1.9.md` is complete and accurate.
5. README.md renders correctly on GitHub and replaces v1.x README content.
6. A fresh `git clone && claude plugin install .` in a sample Go project produces a working review cycle within 5 minutes of the first edit.
7. The runner survives `kill -9` of the parent Claude Code session.
8. `PRILIVE_REVIEW_DISABLE=1` disables the entire pack.

## 13. Known upstream caveats

These are open issues we work around; don't try to fix them in this pack.

- **openai/codex#14343** — `--output-schema` doesn't work on `codex exec resume`. Workaround: round 1 schema-enforced; rounds 2+ verdict-string.
- **openai/codex#12538** — `-o` doesn't work on `codex exec resume`. Workaround: capture stdout for rounds 2+.
- **openai/codex#19816** — `--output-schema` constrains intermediate messages. Workaround: read only the file written by `-o` on round 1.
- **openai/codex#15451** — `--output-schema` dropped when MCP servers active. Workaround: this pack never enables MCP.
- **anthropics/claude-code#18427** — `additionalContext` may not inject on Edit/Write in some builds. Workaround: `UserPromptSubmit` mirror.

## 14. References to keep alongside this doc

- `docs/opensource/open-source-launch-guide-universal.md` — generic OSS launch checklist
- `docs/opensource/open-source-launch-guide-starter-pack.md` — pack-specific OSS plan
- `docs/UPDATE_NOTES_v1.9-to-v1.10.md` — what v1.9.x adopters need before v2.0 migration

---

End of spec. Build order: §7 phases 1-4 in order. MVP first (files 1-10).
