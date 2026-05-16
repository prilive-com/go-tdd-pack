# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

> **First public release.** **v1.10.2** is the first public-tagged
> release of `go-claude-forge`. Versions enumerated below were
> developed in the maintainer's private repository before public
> release; their tag history will be pushed to the public repo so
> the version numbers correspond to real commits, but no
> downloadable artifacts existed for them prior to v1.10.2.

## [Unreleased]

### Added
- _(next changes go here)_

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

[Unreleased]: https://github.com/prilive-com/go-claude-forge/compare/v1.10.2...HEAD
[1.10.2]: https://github.com/prilive-com/go-claude-forge/releases/tag/v1.10.2
[1.10.1]: https://github.com/prilive-com/go-claude-forge/releases/tag/v1.10.1
[1.10.0]: https://github.com/prilive-com/go-claude-forge/releases/tag/v1.10.0
[1.9.11]: https://github.com/prilive-com/go-claude-forge/releases/tag/v1.9.11
[1.9.10]: https://github.com/prilive-com/go-claude-forge/releases/tag/v1.9.10
[1.9.9]: https://github.com/prilive-com/go-claude-forge/releases/tag/v1.9.9
[1.9.8]: https://github.com/prilive-com/go-claude-forge/releases/tag/v1.9.8
[1.9.7]: https://github.com/prilive-com/go-claude-forge/releases/tag/v1.9.7
[1.9.6]: https://github.com/prilive-com/go-claude-forge/releases/tag/v1.9.6
[1.9.5]: https://github.com/prilive-com/go-claude-forge/releases/tag/v1.9.5
[1.9.4]: https://github.com/prilive-com/go-claude-forge/releases/tag/v1.9.4
[1.9.3]: https://github.com/prilive-com/go-claude-forge/releases/tag/v1.9.3
[1.9.2]: https://github.com/prilive-com/go-claude-forge/releases/tag/v1.9.2
[1.9.1]: https://github.com/prilive-com/go-claude-forge/releases/tag/v1.9.1
[1.9.0]: https://github.com/prilive-com/go-claude-forge/releases/tag/v1.9.0
[1.8.0]: https://github.com/prilive-com/go-claude-forge/releases/tag/v1.8.0
[1.7.0]: https://github.com/prilive-com/go-claude-forge/releases/tag/v1.7.0
