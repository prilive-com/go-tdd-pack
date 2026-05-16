# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **Pre-public history.** v1.0.0 through v1.9.8 were developed in a
> private repository before public release. Detailed commit history
> for those versions is preserved in git; the entries below summarize
> what each version delivered. Tags v1.4.x and v1.5.x do not exist —
> the version numbers were not used. Tags for v1.0.0–v1.3.1 may have
> only commit-level history; v1.6.x onward have richer commit messages
> and disposition matrices in `.tdd/`.

## [Unreleased]

### Added
- _(next changes go here)_

## [1.9.8] - 2026-05-16

### Fixed
- **Schema root `required` now enumerates all 9 properties.** v1.9.3
  added `additionalProperties: false` and fixed `findings.items.required`
  but missed the root-level `required` (was 6 of 9 properties; OpenAI
  strict mode rejected with `Missing 'summary'`). Same bug class,
  half-fixed in v1.9.3, fully closed in v1.9.8.
- **Runner verifier now iterates findings elements correctly.**
  `scripts/tdd/run-second-opinion.sh:192` was using two-arg
  `all(.; ...)` form where `.` emits the array as a single value;
  inner conditions failed with `Cannot index array with string id`
  on real Codex output with non-empty findings. Lurked because empty
  `findings: []` exercises a vacuous-truth path. Fix: `all(.[]; ...)`.

### Added
- 4 new author-time invariant smoke tests (`v198_*`) that catch this
  class of bug without needing real OpenAI calls.

## [1.9.7] - 2026-05-15

### Fixed
- **Cycle abandonment now durably closes the cycle.** Pre-v1.9.7,
  writing `.tdd/CYCLE_ABANDONED.txt` only allowed the Stop hook to
  exit; pending obligations stayed `pending` forever and a stale file
  could leak across cycles. Now: matching pending entries transition
  to `status: "abandoned"`, an SHA-chained `cycle_abandoned` audit
  entry is appended, and the file rotates to
  `.tdd/abandoned/<cycle_id>-<unix_ts>.txt`.

### Added
- 3 new smoke tests for the abandonment lifecycle.

## [1.9.6] - 2026-05-15

### Fixed
- **CYCLE_ABANDONED.txt deny messages now direct the operator to a
  real shell.** Pre-v1.9.6, both the Stop hook block and the bash
  pretrigger gate worded the abandonment instruction as if the agent
  could execute it (`echo ... > .tdd/CYCLE_ABANDONED.txt`). The agent
  cannot — Edit/Write/MultiEdit are denied by `.claude/settings.json`,
  Bash is denied by the pretrigger classifier, by design. Updated
  messages now explain this explicitly so the operator sees what
  action is required of them.

## [1.9.5] - 2026-05-15

### Changed
- **The pack now self-enforces the v1.9 second-opinion ceremony on
  its own development.** Set `second_opinion.no_discretion.enabled:
  true` in `.tdd/tdd-config.json`. Combined with v1.9.4 (legacy hook
  defers when no-discretion enabled), all future Edit/Write/Bash on
  this repo from a hook-loaded operator session routes through the
  v1.9 trigger hooks → runner → typed-exception completion → audit
  log. Test setup in `scripts/tdd-test-hooks.sh` adjusted: legacy
  tests now strip `no_discretion` from the tmp config they copy so
  they continue to exercise the legacy code path.

## [1.9.4] - 2026-05-15

### Fixed
- **Legacy `require-second-opinion.sh` defers when no-discretion is
  enabled.** v1.9.0 introduced the new trigger-hook system but did
  not retire the legacy hook. Result: the legacy hook demanded
  `.tdd/second-opinion-completed.md`, which the v1.9 runner does not
  write; the skill that did write it became `disable-model-invocation:
  true` so the model could not invoke it; the agent deadlocked on
  every Edit/Write/Bash. Fix: legacy hook reads
  `second_opinion.no_discretion.enabled` and exits 0 (allow) when
  true. v1.9 trigger hooks own the gate in that mode.

## [1.9.3] - 2026-05-13

### Fixed
- **Schema `findings.items.required` now enumerates all 9 properties.**
  OpenAI strict response_format requires `required` to enumerate every
  key in `properties`; v1.9.2 added `additionalProperties: false` but
  not the required-completeness. Added `category`, `affected_invariant`,
  `location`. (Root `required` was missed in this round; closed in v1.9.8.)

## [1.9.2] - 2026-05-13

### Fixed
- **Schema now declares `additionalProperties: false` at every object
  level.** OpenAI's response_format API rejects schemas missing this
  field with `invalid_json_schema`. Discovered by an adopter; the
  unit-level smoke never invoked Codex end-to-end so the bug was
  invisible until a real call.

## [1.9.1] - 2026-05-13

### Added
- **Round cap: `/second-opinion` is hard-limited to 4 review rounds
  per cycle per review_type** via
  `second_opinion.no_discretion.max_review_rounds_per_cycle` (default
  4). Empirical: v1.9.0's own cycle ran 10 rounds and round 10
  introduced a regression from round 9. The cap forces "ship + queue
  remaining findings" instead of indefinite churn.

### Fixed
- Runner now resolves project root from `CLAUDE_PROJECT_DIR` or `pwd`
  before falling back to script-relative.

## [1.9.0] - 2026-05-13

### Added
- **Pack no-discretion `/second-opinion` enforcement.** Six new hooks
  for plan/test/production write triggers + Bash pretrigger +
  PostToolUse backstop + session-stop-review. Runner script
  (`scripts/tdd/run-second-opinion.sh`) becomes the single legitimate
  Codex caller. Skill is invoke-only (`disable-model-invocation:
  true`) — the model cannot call its own review.
- Schema-extended typed exception for review completions.
- AST validator subcommand for review-completion schema check.

## [1.8.0] - 2026-05-09

### Added
- **AST validator + audit-log chain integrity.** Go-based AST
  validator (`scripts/tdd/ast/validator.go`) for typed exceptions —
  catches "AI silently weakened a test to make it pass" via four
  subcommands (`mech-sig-prop-check`, `compile-fix-scope-check`,
  `import-block-check`, `schema-predicate-check`). SHA-chained audit
  log records each typed-exception grant tamper-evidently.

## [1.7.0] - (early May 2026)

### Added
- **Typed test-edit exceptions replace the all-or-nothing bypass
  boolean.** Three exception types
  (`mechanical_signature_propagation`, `compile_fix_only`,
  `import_only`) with operator approval, scope binding, and
  per-cycle cap.

## [1.6.2] - (early May 2026)

### Fixed
- Per-cycle review friction reductions — marker drift handling, Pass
  A documentation alignment.

## [1.6.1] - (early May 2026)

### Fixed
- Closed 21 release-blocker bypasses via shared commit-mode library
  (`_lib_commit_mode.sh`) to make `git commit -a`, `--include`,
  pathspec modes all hash-bind correctly.

## [1.6.0] - (early May 2026)

### Added
- `/second-opinion` skill via OpenAI Codex CLI for cross-model
  review. Two-pass design (independent design + comparison review).
  Schema-conforming output verified via `jq`.
- Graduated enforcement modes (`enforcement_mode: strict | warn |
  off`) for the four process-discipline gates.

## [1.3.1] - (April 2026)

### Added
- Developer update notes for the second-opinion feature branch.

## [1.3.0] - (April 2026)

### Added
- Various pack maturation work; see commit history.

## [1.2.0] - (April 2026)

### Added
- MultiEdit support across hooks; defensive multi-path extraction.

## [1.1.1] - (April 2026)

### Fixed
- Patch release.

## [1.1.0] - (April 2026)

### Added
- Continuous-integration scripts and test infrastructure.

## [1.0.0] - (April 2026)

### Added
- Initial private release: hooks, skills, agents, rules, templates,
  presets — the v1.x foundation.

## Unreleased version numbers

`v1.4.x` and `v1.5.x` were skipped — those version numbers were never
used. The series jumped from v1.3.1 directly to v1.6.0 when the
`/second-opinion` skill landed.
