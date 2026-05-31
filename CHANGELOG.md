# Changelog

All notable changes to the Prilive Go TDD Pack are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

> **First public release line:** v2.0.x. Earlier versions (v1.x ceremony
> architecture) were developed in the maintainer's private repository
> and are documented below for completeness, but were not publicly
> distributed. The v1.x line is no longer maintained — new adoption
> should use v2.0.x.

## [Unreleased]

_No unreleased changes._

## [2.0.1] - 2026-05-31

Patch release. Five focused improvements driven by external consultant
review (2026-05-22), production adopter feedback (2026-05-31), and
internal-tracked bugs. Backwards-compatible with v2.0.0 — no config
schema changes, no behavior changes for the happy path. All work
landed via individual PRs against the protected `main` branch with
the new `test` / `lint` / `CodeQL` / `DCO` CI gates passing.

### Fixed

- **Escalation cycles no longer overwriteable** (#5).
  `runner/review-runner.sh` previously only treated `request_changes`
  as an in-progress state. On any dirty tree with
  `state.status={escalated|reviewing}`, the runner minted a new cycle
  and overwrote `state.json` — silently destroying pending A/B/V
  escalations and racing in-flight reviews. State-machine guard now
  blocks fresh cycles on these active states. Adopter-reported with a
  fake-codex reproducer. Added `test/smoke-escalation-blocks-new-cycle.sh`
  (5 fixture cases) to regression-protect.
- **Hooks no longer fail silently** (#6).
  `hooks/post-edit-review.sh` previously redirected runner output to
  `/dev/null`. An adopter's ChatGPT auth token expired mid-session and
  the runner failed silently for an hour before they noticed. Output
  now appends to `.tdd/runner.log` with timestamped invocation sections.
  Missing runner is logged to `.tdd/install-error.log` instead of being
  silently swallowed. `hooks/inject-findings.sh` surfaces `failed`
  cycles ONCE per cycle (via `.failure-surfaced` marker) with a hint
  based on the specific failure mode (`codex_exec_nonzero` → "likely
  expired ChatGPT auth, run `codex login`"; `invalid_json` → schema
  failure; etc.).
- **No-git workdir now exits cleanly** (#6). `runner/review-runner.sh`
  previously errored opaquely inside `tool-grounding.sh` or
  `codex-round1.sh` when run in a non-git directory. Now exits with a
  clear message: either `git init` or `PRILIVE_REVIEW_DISABLE=1`.

### Added

- **Four operator slash commands** (#5):
  - `/show-review` — read latest cycle artifacts, summarize
  - `/abandon-review` — neutral exit, sets `abandoned`
  - `/accept-claude` — ship as-is, sets `resolved_by_user_claude`
  - `/accept-codex` — apply Codex findings, sets `resolved_by_user_codex`

  These give operators a clear path out of escalation. `runner/escalate.sh`
  A/B/V message updated to reference them by name. Three new terminal
  states added: `abandoned`, `resolved_by_user_claude`,
  `resolved_by_user_codex` — runner allows fresh cycles after them.
- **Coverage-boundaries docs section** (#6) in `docs/INTEGRATION_GUIDE.md`.
  Explicit table of what is/isn't reviewed: Claude Code's
  `Edit`/`Write`/`MultiEdit`/`Bash` are covered; external `sed`/`vim`/editor
  saves are NOT. Documented failure modes (no-git, auth expiry, runner.log).
- **Shared TOML config parser** (#8) at `runner/lib/config.sh`. Single
  source of truth for parsing `tdd-pack.toml`. Replaces brittle inline
  `awk` parsers across multiple scripts. Per-shell cache.
- **`runner/lib/config.sh` cfg_get function** with per-(path,key) cache.
  Subset-TOML parser: `[section]` headers, `key = scalar`, `# comments`.
- **State.json schema additions** (#8, additive — old fixtures still work):
  - `started_at_epoch` — unix epoch when cycle minted; used by
    `max_cycle_minutes` budget gate
  - `codex_calls` — counter incremented after each Codex invocation;
    used by `max_codex_calls_per_cycle` budget gate
- **`test/smoke-escalation-blocks-new-cycle.sh`** (#5, 5 checks)
- **`test/smoke-config-enforcement.sh`** (#8, 15 checks)
- **`.shellcheckrc`** (#7) documenting the blocking-at-warning policy
  and the one inline-disabled exception (SC2038 in `runner/codex-round1.sh`,
  scheduled for removal in v2.1.0).
- **`commands/`** directory containing 4 markdown command files,
  registered in `.claude-plugin/plugin.json` `commands` array.

### Changed

- **ShellCheck is now BLOCKING in CI** (#7). Was `continue-on-error: true`
  (advisory). Fixed all 22 baseline warnings across 5 SC codes
  (SC2164×11, SC2064×9, SC2046×1, SC2038×1, SC1090×1). Bonus: the
  SC2064 fix in `test/smoke-escalation-blocks-new-cycle.sh` also closed
  a real sandbox-leak bug — each `trap "rm -rf ${SANDBOX}" EXIT` was
  REPLACING the previous trap, so cases 1..N-1's mktemp dirs were
  leaking to `/tmp`. Rewrote with a `CLEANUP_PATHS` array + single
  cleanup function.
- **Stop hook timeout bumped 5→10s** (#6) in both `.claude/settings.json`
  and `.claude-plugin/plugin.json`. Typical hook completes in <1s but
  very long transcripts can push jq parsing time up.
- **Five `tdd-pack.toml` config fields now enforced** (#8). Previously
  declared in config but never read by any script:
  - `review.max_cycle_minutes` (default 30) — wall-clock budget gate
  - `review.max_codex_calls_per_cycle` (default 8) — call counter gate
  - `severity.must_address` (default "major") — contract check in
    `runner/codex-round1.sh`. If Codex returns `verdict=approve` with
    ANY finding at severity ≥ must_address, treat as contract violation
    and fail the cycle with `failed:contract_violation_approve_with_must_address_findings`.
  - `severity.min_surface` (default "nit") — filter in
    `hooks/inject-findings.sh`. Findings below this severity are
    dropped from injected context. Was previously hardcoded to show all.
  - `review.coalesce_ms` — now read via the shared parser (was inline awk).
- **`runner/escalate.sh` additionalContext cap raised** 9800→49500 chars
  (#5) to match `hooks/inject-findings.sh` (which was raised earlier in
  v2.0.0 but escalate.sh was missed).

### Removed

- Inline `awk -F' = '` config parsers (#8) — replaced by `cfg_get`.

### Internal

- **GitHub repo configuration**: `prilive-com/go-tdd-pack` now has 8 numbered
  setup scripts under `scripts/github-setup/` plus orchestrator, audit,
  and 99-make-public scripts — curl-based, idempotent, no `gh` dependency
  (already in v2.0.0 but worth re-mentioning since the audit step gained
  a new check this release: ruleset rules.required_status_checks).
- **Dependabot bumped actions/checkout** v4 → v6 (#3) before v2.0.0 was
  tagged but after the original v2.0.0 RC; included in this release.

## [2.0.0] - 2026-05-18

The v1.x → v2.0 architectural pivot. Replaces the manual TDD ceremony
model (Tier 1/2/3, SPEC.md, second-opinion skill, blocking PreToolUse
hooks) with **continuous silent peer review**: Codex reviews every
meaningful Go change in the background, findings are silently injected
into Claude's next turn, and the user is only pulled in on escalation.

### Added

- **Continuous peer review architecture.** A background runner fires on
  every PostToolUse (Edit/Write/MultiEdit/Bash), debounces 5s, runs
  Codex against the diff, and silently injects findings into Claude's
  next turn. See [`docs/V2_IMPLEMENTATION_SPEC.md`](docs/V2_IMPLEMENTATION_SPEC.md)
  for the full design.
- **Multi-round Codex resume.** Round 1 uses `codex exec --output-schema`
  for strict JSON findings. Rounds 2+ use `codex exec resume <session-id>`
  so the reviewer remembers its prior analysis without re-reading the
  diff. Defaults to 5 rounds before escalation.
- **A/B/V escalation message** when Claude and Codex don't converge.
  The user sees one short message with both views and three choices
  ([A] ship Claude's version, [B] apply Codex's, [V] view transcripts).
- **Universal monorepo-aware tool grounding.** `runner/tool-grounding.sh`
  walks each changed file up to its nearest non-empty `go.mod`, dedupes,
  and runs tools per affected module. Works for single-module repos,
  monorepos with multiple `go.mod` files at any depth, nested modules,
  polyglot repos, and Go files with no enclosing `go.mod`. Never silently
  no-ops — always emits a status section so Codex knows what was (and
  wasn't) analyzed.
- **Tool grounding for five Go tools** included verbatim in Codex's
  prompt: `gofmt -l`, `go vet`, `staticcheck`, `golangci-lint run`,
  `govulncheck`. Each tool times out at 60s, output capped at 4KB per
  tool, total cap 30KB. Tools skipped silently if not installed but
  marked `NOT INSTALLED` in Codex's prompt so absence is visible.
- **Confidence scores on every finding.** Schema-required integer 1-5:
  5 = verified (tool/test cited), 4 = high (read surrounding code),
  3 = likely, 2 = plausible, 1 = guess. Displayed as `c=N` alongside
  severity so Claude can triage by certainty.
- **Codex runs with full machine access** (`--dangerously-bypass-approvals-and-sandbox`),
  matching Claude's environment. The "no project writes" rule lives in
  `prompts/codex-system.md` and is empirically verified by smoke tests.
  No git worktree, no copy, no sandbox.
- **Five new hooks** registered via `.claude/settings.json`:
  `post-edit-review.sh` (async PostToolUse), `inject-findings.sh`
  (sync PostToolUse + UserPromptSubmit), `stop-fingerprint.sh` (Stop),
  `session-start.sh` (SessionStart). All deterministic shell, all
  bounded.
- **Five new runner scripts** under `runner/`: `review-runner.sh`
  (orchestrator), `coalesce.sh`, `codex-round1.sh`, `codex-round-n.sh`,
  `extract-verdict.sh`, `escalate.sh`, `tool-grounding.sh`.
- **Smoke test suite.** `test/smoke-v2-phase2.sh` (25 unit-style
  orchestration checks, no Codex calls), `test/smoke-tool-grounding.sh`
  (12 fixture checks across 6 repo layouts), `test/smoke-v2-mvp.sh` and
  `test/smoke-v2-phase2-live.sh` (live Codex end-to-end smokes).
- **Quality-tuned defaults** in `tdd-pack.toml`: `reasoning_effort = "xhigh"`,
  `web_search = "live"`, `model = ""` (track Codex CLI's current default),
  `max_rounds = 5`, `min_surface = "nit"` (surface all findings to
  Claude), additionalContext cap raised to 49500 chars.
- **`docs/V2_IMPLEMENTATION_SPEC.md`** — full design document.
- **`docs/V2_ROLLOUT_GUIDE.md`** — install instructions for adopters'
  AI assistants.
- **`docs/UPDATE_2026-05-17.md`** and **`docs/UPDATE_2026-05-17_monorepo-fix.md`** —
  patch instructions for projects on earlier v2.0 commits.
- **PRILIVE_REVIEW_DISABLE=1** as the single emergency kill switch.

### Changed

- **Breaking:** removed the v1.x TDD ceremony model entirely. Tier 1/2/3
  classification, `SPEC.md`, `CYCLE_ABANDONED.txt`, `current-plan.md`,
  the `second-opinion` skill, and all blocking PreToolUse ceremony hooks
  are gone. Adopters should use the continuous review model instead.
- **Breaking:** v1.x state files (`.tdd/current-plan.md`, `.tdd/cycles/`,
  `.tdd/exceptions/*.json`) are no longer used. New state lives under
  `.tdd/reviews/` (one directory per review cycle).
- Codex orientation prompt now sends `git diff --name-only HEAD` for
  the changed-files list, not the full repo tree. Codex still has
  `git ls-files`, `Read`, and other tools to fetch broader layout when
  needed. Tighter prompt, less attention dilution.

### Removed

- v1.x ceremony files (see Changed). Adopters migrating from v1.x can
  delete `.tdd/current-plan.md`, `.tdd/cycles/`, `.tdd/exceptions/`,
  `.claude/hooks/require-second-opinion.sh`, and any `SPEC.md` /
  `CYCLE_ABANDONED.txt` artifacts safely.
- The `--sandbox read-only` invocation of Codex from v1.10.0 (still
  documented below). Replaced with `--dangerously-bypass-approvals-and-sandbox`
  for capability parity with Claude.
- The `git ls-files | head -50` repo tree injection (was a quality cap).
- The 9800-char additionalContext cap (was over-conservative; raised
  to 49500).
- The `minor`-floor filter on injected findings (was over-conservative;
  Claude now sees nits too).

### Fixed

- **Monorepo tool-grounding silent no-op.** The original
  `runner/tool-grounding.sh` checked for `go.mod` at `PROJECT_DIR` root
  and silently skipped any monorepo without one. Fixed by diff-driven
  discovery (walk up from each changed file). Tool grounding now works
  for any Go repo layout. See [`docs/UPDATE_2026-05-17_monorepo-fix.md`](docs/UPDATE_2026-05-17_monorepo-fix.md).
- **Runner did not resume in-progress cycles.** After round 1 emitted
  request_changes and the working tree was reverted (Claude's fix), the
  runner's `git diff --quiet HEAD` skip-if-clean check exited without
  ever running round 2. Fixed by detecting `state.json` for an
  in-progress cycle before the coalesce/diff/round-1 path.
- `mv` from `mktemp` was downgrading executable bits on hook scripts
  during fixture insertion (live smoke caught this). Tests now capture
  and restore mode.
- Codex `--output-schema` unsupported on `codex exec resume` (upstream
  bug openai/codex#14343). Round 1 uses fresh `codex exec` with schema;
  rounds 2+ use resume with `VERDICT:` line parsing via
  `runner/extract-verdict.sh`.
- ARG_MAX overflow on `awk -v` templating with large diffs. Switched to
  `jq --rawfile` which reads from disk and has no command-line size limit.
- `--ask-for-approval` and `--search` are top-level codex flags, not
  `codex exec` flags. Replaced with `--dangerously-bypass-approvals-and-sandbox`
  (subcommand-supported single flag) and `-c web_search="live"` (config
  override that works on subcommands).

### Security

- Codex's "no project writes" rule is enforced by system prompt and
  verified by `test/smoke-v2-mvp.sh` and `test/smoke-v2-phase2-live.sh`,
  which both check file hashes before and after each cycle. Any
  violation fails the smoke explicitly.
- `.tdd/reviews/**` is added to `permissions.deny` in
  `.claude/settings.json` so Claude cannot directly modify review state.

---

## [1.10.2] - 2026-05-16

## [1.10.2] - 2026-05-16

### Added
- **Smooth-UX session resumption.** Stop hook now writes per-cycle
  `.tdd/cycles/<cycle-id>/state.json` (cycle_id, status, next_actor,
  approved_rounds, updated_at, context_hint) and updates a
  `.tdd/active` pointer at every clean session exit. SessionStart
  hook reads the active pointer and injects the cycle state as
  continuation context for the next `claude` invocation.
- **`/continue` and `/resume <cycle-id>` slash commands** as
  explicit fallback when SessionStart context injection silently
  drops (anthropics/claude-code#10373 — known to affect brand-new
  conversations).
- **`scripts/tdd/validate-codex-output.sh` external validator.**
  Defense-in-depth against `--output-schema` being silently ignored
  when shell tools are active (openai/codex#15451). Validates
  top-level required fields, verdict enum, type checks, scope_hash
  format, per-finding shape. Exit 0 valid / 1 invalid / 2 usage.

## [1.10.1] - 2026-05-16

### Fixed
- **Production-edit trigger now honors `tier1_path_regexes`.**
  v1.9.0 silently broke the Mode A / Mode B distinction by gating
  every production `.go` edit regardless of the project's Tier 1
  config. Result for adopters: low-stakes refactors required full
  ceremony + cycle abandonment friction on `/exit`. Fix: Tier 2
  production edits are silent (no obligation, no ceremony). Override
  flag for "force ceremony on Tier 2 too" is
  `second_opinion.no_discretion.production_edits_all_tiers: true`.

## [1.10.0] - 2026-05-16

### Changed
- **Codex now invoked with full real-environment access.** Pre-v1.10
  used `--sandbox read-only`; per OpenAI's documented semantics this
  blocked spawned shell commands entirely ("Codex can inspect files,
  but it cannot edit files or run commands without approval"), so
  Codex could not `cat`, `ls`, `grep`, `go test`, etc. Net effect:
  every supporting file became a context-request round.
- New invocation: `--sandbox danger-full-access --ask-for-approval
  never --cd <project_root>`. Codex has the same environment Claude
  Code itself runs in: real files, real OS, real commands, real
  network. ONE inviolable rule enforced by prompt + Codex
  cooperation: do not write or modify any files. Trust model
  identical to how the user trusts Claude CLI.

## [1.9.11] - 2026-05-16

### Fixed
- **Prompt template clarified that Codex has read-only sandbox file
  access** (and should use it rather than emit MC findings). This
  fix was based on a wrong assumption about read-only mode — see
  v1.10.0 for the real fix.

## [1.9.10] - 2026-05-16

### Fixed
- **MC detection loosened to match on `failure_mode` prefix only.**
  v1.9.9 required BOTH `id` startswith "MC-" AND `failure_mode`
  startswith "missing context:". Real Codex output complied with
  failure_mode but kept F1/F2 ids. Adopter session unrecognized.
  Drop the id check; failure_mode prefix is the semantic signal.

## [1.9.9] - 2026-05-16

### Added
- **"Missing context" pattern.** Prompt + runner support for Codex
  to request unchanged supporting files (test fixtures, imports,
  configs) without burning the round cap. Round-cap counter not
  affected by context-request rounds.

## [1.9.8] - 2026-05-16

### Fixed
- **Schema root `required` now enumerates all 9 properties.** v1.9.3
  added `additionalProperties: false` and fixed `findings.items.required`
  but missed the root-level `required` (was 6 of 9; OpenAI strict
  mode rejected with `Missing 'summary'`). Same bug class,
  half-fixed in v1.9.3, fully closed in v1.9.8.
- **Runner verifier now iterates findings elements correctly.**
  `scripts/tdd/run-second-opinion.sh:192` used two-arg `all(.; ...)`
  form where `.` emits the array as a single value; inner conditions
  failed with `Cannot index array with string id` on real Codex
  output with non-empty findings. Fix: `all(.[]; ...)`.

### Added
- 4 new author-time invariant smoke tests (`v198_*`).

## [1.9.7] - 2026-05-15

### Fixed
- **Cycle abandonment now durably closes the cycle.** Pre-v1.9.7,
  writing `.tdd/CYCLE_ABANDONED.txt` only allowed the Stop hook to
  exit; pending obligations stayed `pending` forever and a stale
  file could leak across cycles. Now: matching pending entries
  transition to `status: "abandoned"`, an SHA-chained
  `cycle_abandoned` audit entry is appended, and the file rotates
  to `.tdd/abandoned/<cycle_id>-<unix_ts>.txt`.

## [1.9.6] - 2026-05-15

### Fixed
- **CYCLE_ABANDONED.txt deny messages now direct the operator to a
  real shell.** Pre-v1.9.6 the messages worded the abandonment
  instruction as if the agent could execute it. The agent cannot —
  Edit/Write/MultiEdit are denied by `.claude/settings.json`, Bash
  is denied by the pretrigger classifier, by design.

## [1.9.5] - 2026-05-15

### Changed
- **The pack now self-enforces the v1.9 second-opinion ceremony on
  its own development.** Set `second_opinion.no_discretion.enabled:
  true` in `.tdd/tdd-config.json`.

## [1.9.4] - 2026-05-15

### Fixed
- **Legacy `require-second-opinion.sh` defers when no-discretion is
  enabled.** v1.9.0 introduced the new trigger-hook system but did
  not retire the legacy hook. Result: the legacy hook demanded an
  artifact the v1.9 runner does not write; the skill that wrote it
  became `disable-model-invocation: true`; the agent deadlocked.
  Fix: legacy hook reads `second_opinion.no_discretion.enabled` and
  exits 0 (allow) when true.

## [1.9.3] - 2026-05-13

### Fixed
- **Schema `findings.items.required` now enumerates all 9 properties.**
  Added `category`, `affected_invariant`, `location`. Root `required`
  was missed in this round; closed in v1.9.8.

## [1.9.2] - 2026-05-13

### Fixed
- **Schema now declares `additionalProperties: false` at every
  object level.** OpenAI's response_format API rejects schemas
  missing this field with `invalid_json_schema`.

## [1.9.1] - 2026-05-13

### Added
- **Round cap: `/second-opinion` is hard-limited to 4 review rounds
  per cycle per review_type** via
  `second_opinion.no_discretion.max_review_rounds_per_cycle`.
  Empirical: v1.9.0's own cycle ran 10 rounds and round 10
  introduced a regression from round 9.

### Fixed
- Runner now resolves project root from `CLAUDE_PROJECT_DIR` or
  `pwd` before falling back to script-relative.

## [1.9.0] - 2026-05-13

### Added
- **Pack no-discretion `/second-opinion` enforcement.** Six new hooks
  for plan/test/production write triggers + Bash pretrigger +
  PostToolUse backstop + session-stop-review. Runner script
  (`scripts/tdd/run-second-opinion.sh`) becomes the single
  legitimate Codex caller. Skill is invoke-only
  (`disable-model-invocation: true`).
- Schema-extended typed exception for review completions.
- AST validator subcommand for review-completion schema check.

## [1.8.0] - 2026-05-09

### Added
- **AST validator + audit-log chain integrity.** Go-based AST
  validator (`scripts/tdd/ast/validator.go`) with four subcommands
  (`mech-sig-prop-check`, `compile-fix-scope-check`,
  `import-block-check`, `schema-predicate-check`). SHA-chained
  audit log records each typed-exception grant tamper-evidently.

## [1.7.0]

### Added
- **Typed test-edit exceptions** replace the all-or-nothing bypass
  boolean. Three exception types
  (`mechanical_signature_propagation`, `compile_fix_only`,
  `import_only`) with operator approval, scope binding, and
  per-cycle cap.

## Pre-public history (versions earlier than v1.7.0)

Versions 1.0.0 through 1.6.2 existed only in the maintainer's
private working tree before this project's public release at
v1.10.2. They were never distributed to any third party. Per Keep a
Changelog 1.1.0's guidance that "changelogs are for humans," and
following the convention used by graduated CNCF projects
(containerd, BuildKit) and Apache TLPs (Kafka, Cassandra), they are
collapsed into this single block rather than enumerated with
fabricated dates.

Conceptually, the pre-public v1.0–v1.6 work delivered:

- v1.0–v1.2: initial Go starter scaffolding, the foundational
  enforcement hooks (`require-tdd-state.sh`, `gate-tier1-commit.sh`,
  `guard-dangerous-bash.sh`, `scan-for-secrets.sh`), the Mode A
  vs Mode B distinction via `tier1_path_regexes`, MultiEdit support,
  baseline test infrastructure.
- v1.3: documentation maturation, developer update notes.
- v1.6: `/second-opinion` skill via OpenAI Codex CLI for cross-model
  review (two-pass design); graduated enforcement modes
  (`enforcement_mode: strict | warn | off`); shared commit-mode
  library closing 21 release-blocker bypasses; per-cycle review
  friction reductions.

Tags v1.4.x and v1.5.x do not exist — those version numbers were
never used (the series jumped from v1.3.1 directly to v1.6.0 when
the `/second-opinion` skill landed).

The enumerated changelog above begins at v1.7.0 because that is the
first version with a substantively documented commit graph beyond
"initial scaffolding."

[Unreleased]: https://github.com/prilive-com/go-tdd-pack/compare/v1.10.2...HEAD
[1.10.2]: https://github.com/prilive-com/go-tdd-pack/releases/tag/v1.10.2
[1.10.1]: https://github.com/prilive-com/go-tdd-pack/releases/tag/v1.10.1
[1.10.0]: https://github.com/prilive-com/go-tdd-pack/releases/tag/v1.10.0
[1.9.11]: https://github.com/prilive-com/go-tdd-pack/releases/tag/v1.9.11
[1.9.10]: https://github.com/prilive-com/go-tdd-pack/releases/tag/v1.9.10
[1.9.9]: https://github.com/prilive-com/go-tdd-pack/releases/tag/v1.9.9
[1.9.8]: https://github.com/prilive-com/go-tdd-pack/releases/tag/v1.9.8
[1.9.7]: https://github.com/prilive-com/go-tdd-pack/releases/tag/v1.9.7
[1.9.6]: https://github.com/prilive-com/go-tdd-pack/releases/tag/v1.9.6
[1.9.5]: https://github.com/prilive-com/go-tdd-pack/releases/tag/v1.9.5
[1.9.4]: https://github.com/prilive-com/go-tdd-pack/releases/tag/v1.9.4
[1.9.3]: https://github.com/prilive-com/go-tdd-pack/releases/tag/v1.9.3
[1.9.2]: https://github.com/prilive-com/go-tdd-pack/releases/tag/v1.9.2
[1.9.1]: https://github.com/prilive-com/go-tdd-pack/releases/tag/v1.9.1
[1.9.0]: https://github.com/prilive-com/go-tdd-pack/releases/tag/v1.9.0
[1.8.0]: https://github.com/prilive-com/go-tdd-pack/releases/tag/v1.8.0
[1.7.0]: https://github.com/prilive-com/go-tdd-pack/releases/tag/v1.7.0
