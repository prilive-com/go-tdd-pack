# Bugfix Plan: v1.6.1-release-blockers — close 5 P1 + 1 P0 enforcement gaps from combined review

Status: active
Cycle ID: v1.6.1-release-blockers
Change type: bugfix (release-blocking; combined v1.6.1 review identified
                    5 P1 + 1 P0 + 1 cross-cycle gap)
Tier: 1 (touches gate-tier1-commit.sh, require-second-opinion.sh,
         scripts/git-hooks/pre-commit, .tdd/tdd-config.json)

<!-- TDD ceremony markers. Set each ONLY after the matching operator APPROVED reply. -->
Bug reproduced: yes
Human approved spec: yes
Red phase confirmed: yes
Green phase authorized: yes
Implementation reviewed: yes
Fix applied: yes
Regression tests added: yes
Bug-elsewhere check complete: yes

## Bug

Combined v1.6.1 review (Claude self-review + 2 external consultants)
identified 5 P1s + 1 P0 + 1 cross-cycle invariant gap that block
tagging v1.6.1 as a reliable Tier 1 governance release. Each
verified by direct code reproduction.

The 5 release-blocker findings (C1-C5 from the review) and the
new C9-revised + C14:

### C1 (P1) — `require-second-opinion.sh` fails open when codex missing

`require-second-opinion.sh` lines 195-198: if `codex` binary is
missing, hook unconditionally calls `allow`. Bypasses all
enforcement_mode plumbing. In strict mode, removing codex from PATH
silently disables every Tier 1 check.

### C2 (P0) — git-side pre-commit enforces strictly weaker policy than gate-tier1-commit.sh

`scripts/git-hooks/pre-commit` line 220 reads
`required_markers_edit_time` (M1+M2+M3) instead of
`required_markers_commit_time` (M1+M2+M3+**M4**). Hook never
references `green-proof.md` anywhere. So:

- gate-tier1-commit.sh enforces M1+M2+M3+M4 + green-proof + adjudication
- pre-commit enforces M1+M2+M3 + adjudication

The git-side hook is supposed to be the deterministic floor that
catches what the leaky PreToolUse layer misses. Instead it enforces
LESS. The architecture is inverted. Reproducible: M1+M2+M3 set, no
M4, no green-proof → pre-commit exits 0 silently.

P0 because it's a category error (architecture inversion), not just
a missed check.

### C3 (P1) — Layer 0 mode classifier doesn't drive Tier 1 detection

`gate-tier1-commit.sh` line 364 sets `CHANGED_FILES` from
`git diff --cached --name-only` (staged-only). Lines 580-690 compute
`COMMIT_MODE_ALL/PATHSPEC/UNCERTAIN` correctly, but feed it ONLY to
the size-threshold (CHURN) computation. Tier 1 detection still uses
staged-only.

Reproduction: stage non-Tier-1 + leave Tier 1 unstaged-tracked +
`git commit -am test` → COMMIT_MODE_ALL=true → CHURN counts both
files → but TIER1_PROD=[] (only checks staged) → exit 0 silently.

The Layer 0 cycle's stated goal (close `git commit -am` bypasses)
was achieved for the size threshold but NOT for Tier 1 detection.

### C4 + A2 (P1) — Trivial filter exempts Tier 1 governance files

`gate-tier1-commit.sh` line 376, `scripts/git-hooks/pre-commit`
line 191, AND `require-second-opinion.sh` `is_always_allowed_path()`
all run a trivial-path filter BEFORE the Tier 1 regex check. Files
matching `*.md` (the broadest pattern) are exempted before they get
evaluated against `tier1_path_regexes`.

Verified scope (tested empirically with the actual case patterns):

- `.claude/skills/second-opinion/SKILL.md` (declared Tier 1) →
  EXEMPTED via `*.md`
- ANY downstream-consumer `subdir/.claude/*` or `subdir/.tdd/*`
  paths declared Tier 1 → EXEMPTED via `*/.claude/*` / `*/.tdd/*`
- Top-level `.claude/hooks/*.sh` and `.tdd/tdd-config.json` →
  correctly go through Tier 1 (no leading `/` in path means they
  don't match the `*/.claude/*` pattern; this part of my prior
  C4 framing was wrong)

A2 is the same bug class in the third hook (`require-second-opinion.sh`).
This is the F4 fix propagated to two more places.

### C5 (P1) — `check-tdd-state-clean.sh` hardcodes pre-migration M3 marker

Lines 39-43 hardcode `Human approved implementation: yes`. Migration
script renames this to `Green phase authorized: yes`. Post-migration
plans use the new name. CI's `tdd-state-clean` job grep's for the
old name → reports MISSING → fails on every legitimate cycle. Latent
because the job runs only on PRs and we pushed direct to main.

### C9-revised (P1, was P3) — Hash binding default-off in strict mode is internally inconsistent

`tdd-config.json` line 145: `require_hash_binding_tier1: false`.
Mechanism is fully implemented (F5 cycle), but default-off means a
team in `enforcement_mode: strict` still has the stale-review
bypass open: run /second-opinion on diff A → modify Tier 1 to diff
B → gate accepts fresh artifact for unrelated work.

If "strict" means strict, then strict + hash_binding=off creates a
documented bypass within the supposedly-strict configuration. Either
the default must depend on mode (strict → ON), or strict + off must
be a config error refused at startup.

### C14 (cross-cycle invariant gap) — Diff-driven /second-opinion missed C1-C5

The /second-opinion cycles caught ~50 within-cycle findings but
missed C1-C5 because Codex reviews diffs in isolation, not
cross-hook contracts or cross-cycle invariants. The gaps are real;
fixing them as one-offs leaves the same class of bug latent for
the next cycle.

Concrete invariants that, if asserted as smoke tests, would have
caught C1-C5 mechanically:
- "every commit-time gate reads `required_markers_commit_time`"
- "every Tier 1 gate honors files declared Tier 1 in config"
- "every commit-time gate references `green-proof.md`"
- "no script hardcodes a marker name outside fallback blocks"

## Reproduction (for each finding)

See `.tdd/codex/disposition-matrix.md` from the prior review (and
the verification record in this conversation). Each of C1-C5 was
reproduced by direct invocation.

## Acceptance criteria

### Fix 1 — C1 + C8 grouped (codex-missing fail-closed + smoke stub)

1.1 `require-second-opinion.sh`: when `codex` is missing AND
    `enforcement_mode=strict` AND target is Tier 1 (or non-Tier-1
    path that requires adjudication) AND adjudication is missing,
    DENY (not allow). Same for `jq` missing.
1.2 When codex is missing AND adjudication EXISTS AND is fresh,
    ALLOW (operator can complete adjudication via Edit/Write
    without needing codex installed).
1.3 `enforcement_mode=warn` with codex missing + missing adjudication
    → stderr WARNING + allow.
1.4 `enforcement_mode=off` → silent allow (current behavior).
1.5 Existing `SECOND_OPINION_DISABLE=1` killswitch overrides any
    codex-missing path (preserved).
1.6 Smoke tests add a fake `codex` shim in CI (cross-shell PATH
    prepend) so smoke tests don't depend on real codex binary.
    Same commit as the C1 fix to avoid broken-CI window.
1.7 Smoke tests: codex-missing matrix (strict+missing-adj=deny;
    strict+fresh-adj=allow; warn=allow-with-stderr; off=silent).

### Fix 2 — C2 (pre-commit M4 + green-proof)

2.1 `scripts/git-hooks/pre-commit` reads
    `.required_markers_commit_time` (default M1+M2+M3+M4 if
    config field absent), with `marker_aliases` support.
2.2 New check after marker loop: if `.tdd/green-proof.md` doesn't
    exist, DENY with "Tier 1 commit requires green-proof.md".
2.3 Adjudication-existence check fires regardless of
    `require_hash_binding_tier1` flag (adjudication file MUST
    exist; hash binding is opt-in additional check on top).
2.4 Smoke fixtures:
    - M1+M2+M3 only, no M4 → BLOCK (currently allows)
    - M1+M2+M3+M4 + adjudication, no green-proof.md → BLOCK
    - M1+M2+M3+M4 + adjudication + green-proof.md → ALLOW
2.5 prepare-commit-msg wrapper inherits the new behavior via
    its `exec` to pre-commit (no separate change needed).

### Fix 3 — C5 (check-tdd-state-clean.sh config-driven markers)

3.1 Script reads `.required_markers_commit_time` from
    `tdd-config.json` (with fallback to `required_markers` then
    to hardcoded M1+M2+M3+M4 defaults).
3.2 `marker_aliases` support: if a plan has the OLD marker name
    only, treat as present + emit deprecation warning to stderr.
3.3 Smoke fixtures:
    - active plan + M1+M2+M3+M4 (new names) → PASS
    - active plan + old M3 name + M1+M2+M4 (new) → PASS with deprecation warning
    - active plan + M1+M2+M3 only (missing M4) → FAIL
    - idle plan → PASS (existing)
    - missing plan → PASS (existing)

### Fix 4 — C4 + A2 (Tier 1 regex check before trivial filter, in 3 hooks)

4.1 `gate-tier1-commit.sh`: in TIER1_PROD construction loop,
    Tier 1 regex match runs FIRST. Trivial filter only applies
    to files that did NOT match Tier 1.
4.2 `scripts/git-hooks/pre-commit`: same change.
4.3 `require-second-opinion.sh`: in `is_always_allowed_path()`
    OR in the path-evaluation block that calls it, ensure Tier 1
    paths are NEVER short-circuited by the trivial filter. Match
    the same evaluation order as the commit-time gates.
4.4 Smoke fixtures:
    - `.claude/skills/second-opinion/SKILL.md` staged + no plan → BLOCK in all 3 hooks (currently allows)
    - `subdir/.claude/skills/SKILL.md` declared Tier 1 → BLOCK (downstream-consumer fixture)
    - `docs/random.md` (NOT Tier 1) → PASS (regression)
    - `README.md` (NOT Tier 1) → PASS (regression)
    - `internal/auth/x.go` (Tier 1) → BLOCK (regression)

### Fix 5 — C3 (Layer 0 COMMIT_MODE drives Tier 1 detection)

5.1 `gate-tier1-commit.sh`: refactor so the COMMIT_MODE
    classification runs BEFORE the TIER1_PROD construction. Then
    use the classifier to choose the candidate file set:
    - `PLAIN` → `git diff --cached --name-only` (current; preserve narrow scope)
    - `ALL`/`PATHSPEC`/`UNCERTAIN` → `git diff HEAD --name-only` plus untracked
5.2 The size-threshold (CHURN) computation continues to use the
    same wider set in the matching modes (existing behavior).
5.3 Smoke fixtures:
    - PLAIN + only non-Tier-1 staged + Tier-1 WIP unstaged → ALLOW (preserve PLAIN narrow scope)
    - ALL (`-am`) + non-Tier-1 staged + Tier-1 WIP unstaged → BLOCK (currently allows)
    - PATHSPEC (`commit foo.go`) + Tier-1 in pathspec → BLOCK
    - UNCERTAIN (unknown long opt) + Tier-1 unstaged → BLOCK (conservative)
    - PLAIN + Tier-1 staged + non-Tier-1 WIP unstaged → BLOCK (existing)

### Fix 6 — C9-revised (hash binding mode-based default)

6.1 In `require-second-opinion.sh` AND `scripts/git-hooks/pre-commit`:
    when `enforcement_mode=strict` (per-hook resolved) AND
    `require_hash_binding_tier1=false`, EITHER:
    - (Option A) Auto-promote: treat the flag as `true` for strict
      mode (with stderr note that strict implies hash binding)
    - (Option B) Refuse to start: deny with "strict mode requires
      require_hash_binding_tier1: true; either flip the flag or
      use enforcement_mode: warn"
6.2 Default behavior in `warn`/`off` modes preserved (flag is
    optional; respects whatever's in config).
6.3 Smoke fixtures:
    - strict + flag=false → behavior matches strict + flag=true (Option A) OR refuse with clear message (Option B)
    - warn + flag=false → no change (current behavior)
    - off + flag=false → no change

### Fix 7 — C14 (cross-contract smoke tests)

7.1 New smoke section "Contract invariant tests" with assertions
    that span hooks (not within a single hook):

    - **Path coverage invariant**: every Tier 1 regex in
      `tier1_path_regexes` must produce a deny path through both
      gate-tier1-commit.sh AND scripts/git-hooks/pre-commit
      when matched against a synthetic staged file. Generates
      one fixture per regex.
    - **Marker source invariant**: grep all production hooks for
      hardcoded marker strings. Any hook that contains
      `Human approved spec`, `Red phase confirmed`,
      `Green phase authorized`, or `Implementation reviewed`
      OUTSIDE of fallback-defaults blocks must read from config.
      Smoke asserts grep finds zero unapproved hardcoded uses.
    - **Commit-time policy invariant**: every commit-time gate
      script (gate-tier1-commit.sh, scripts/git-hooks/pre-commit)
      must contain references to BOTH `green-proof` AND
      `Implementation reviewed: yes` (or read them from config).
      Smoke asserts via grep.
    - **Trivial-filter ordering invariant**: in any hook with
      both Tier 1 regex match AND trivial-path filter, the Tier 1
      block appears BEFORE the trivial filter. Asserted via
      line-number comparison in the source.

7.2 Each assertion failure prints: which invariant, which hook,
    what's missing/wrong. Operator clear-message for diagnosis.
7.3 These tests run in the same smoke suite (`scripts/tdd-test-hooks.sh`)
    so CI catches future regressions.

## Non-goals (this cycle)

These are deferred to a SEPARATE cycle (gate-level-v1.6.1-followup-phase2):

- **Phase 2 (Codex context expansion):** invariant-registry.md
  generator, hook-contract-matrix.md generator, contract-pack.md
  generator, SKILL.md Step 4 prompt updates. ~3 hours.
- **Phase 3 (Quality):** C6 (skill review scope alignment), C7
  (per-row matrix content discipline), C10 partial (SKILL.md
  frontmatter version + remove "advisory only" text). ~1.5 hours.

These are deferred to v1.7:

- **C10 (full):** SKILL.md size split into smaller files.
- **C11:** shared library extraction (`scripts/tdd/_lib_commit_gate.sh`).
- **C12:** pre-commit/gate-tier1-commit consolidation (subset of C11).
- **Layer B Codex context:** call-sites grep for changed Go files.
- **Full Context Pack architecture:** deep-second-opinion Codex skill,
  code_review.md, three-pass workflow.

## Affected code

- `.claude/hooks/require-second-opinion.sh` — C1, C4+A2
- `.claude/hooks/gate-tier1-commit.sh` — C2 (already correct), C3, C4
- `scripts/git-hooks/pre-commit` — C2, C4
- `scripts/check-tdd-state-clean.sh` — C5
- `.tdd/tdd-config.json` — C9-revised (mode-based default semantics)
- `scripts/tdd-test-hooks.sh` — fixtures + C14 contract invariant tests
- `.github/workflows/ci.yml` + `.gitlab-ci.yml` — C8 codex stub

## Test plan

| Test name | Pins criterion # |
|---|---|
| v161_c1_codex_missing_strict_no_adj_denies | 1.1 |
| v161_c1_codex_missing_strict_fresh_adj_allows | 1.2 |
| v161_c1_codex_missing_warn_emits_stderr_allows | 1.3 |
| v161_c1_codex_missing_off_silent | 1.4 |
| v161_c1_killswitch_overrides_codex_missing | 1.5 |
| v161_c8_smoke_uses_fake_codex_shim | 1.6 |
| v161_c2_pre_commit_m1m2m3_only_denies | 2.1, 2.4 |
| v161_c2_pre_commit_no_green_proof_denies | 2.2, 2.4 |
| v161_c2_pre_commit_full_state_allows | 2.4 |
| v161_c2_prepare_commit_msg_inherits | 2.5 |
| v161_c5_check_state_clean_full_markers_passes | 3.3 |
| v161_c5_check_state_clean_old_marker_warns_passes | 3.2, 3.3 |
| v161_c5_check_state_clean_missing_m4_fails | 3.3 |
| v161_c4_skill_md_blocks_in_gate_tier1_commit | 4.1, 4.4 |
| v161_c4_skill_md_blocks_in_pre_commit | 4.2, 4.4 |
| v161_c4_skill_md_blocks_in_require_second_opinion | 4.3, 4.4 |
| v161_c4_docs_md_still_allows | 4.4 (regression) |
| v161_c4_internal_auth_still_blocks | 4.4 (regression) |
| v161_c3_plain_no_change | 5.3 (regression) |
| v161_c3_am_with_unstaged_tier1_blocks | 5.3 |
| v161_c3_pathspec_tier1_blocks | 5.3 |
| v161_c3_uncertain_unstaged_tier1_blocks | 5.3 |
| v161_c9_strict_flag_off_behaves_like_on | 6.3 |
| v161_c9_warn_flag_off_unchanged | 6.3 |
| v161_c14_path_coverage_invariant | 7.1 |
| v161_c14_marker_source_invariant | 7.1 |
| v161_c14_commit_time_policy_invariant | 7.1 |
| v161_c14_trivial_filter_ordering_invariant | 7.1 |

~28 smoke tests total.

## Implementation order (dependency-driven)

1. **C1 + C8 first** (must be in same commit). codex-missing
   fail-closed + smoke shim. Without the shim, all subsequent
   smoke runs need real codex.
2. **C2 next** (additive; no refactor). Add markers + green-proof
   check to pre-commit. Touches different code path than C4.
3. **C5 next** (independent; trivial). Config-driven markers in CI script.
4. **C4 + A2** (refactor of Tier 1 evaluation in 3 hooks). Touches
   the same blocks C3 will touch — do C4 first to keep diffs clean.
5. **C3 next** (refactor of Tier 1 detection to use COMMIT_MODE).
   Builds on C4's reorganized evaluation.
6. **C9-revised** (small; mode interaction with hash binding). Either
   auto-promote in strict OR refuse-startup. Recommend auto-promote
   for fewer surprises.
7. **C14 last** (meta-tests asserting cross-hook invariants).
   Runs after all other fixes so the asserted invariants are true.

## Risk register

| Risk | Mitigation |
|---|---|
| C2 + C4 + C3 all touch the same evaluation block; refactor risk | Implement in sequence with smoke after each step. /second-opinion will catch interaction bugs. |
| C1 fail-closed could break legitimate workflows where codex is genuinely unavailable (no API key, offline) | Operator can use enforcement_mode=warn or SECOND_OPINION_DISABLE killswitch. Document in commit message. |
| C9-revised auto-promote in strict surprises operators who set flag=false intentionally | Stderr note explains. If operators object, switch to refuse-startup (Option B). |
| C14 contract tests are parsing source files (grep, line-number compare) — fragile to formatting | Tests check semantically meaningful patterns (e.g., `green-proof` substring), not exact line content. Format changes still pass. |
| 28 smoke tests = bigger /second-opinion review surface | Expected. Previous cycles with similar scope (Layer-0-rescue, gate-level) ran 8+ Codex rounds. Budget for 4-6 rounds here. |
| C9-revised changes config semantics mid-cycle for users with strict + flag=false | Document as breaking change in commit message. Major-version-style note: "if you have strict + hash_binding=false, expect new behavior." |

## Smoke test growth target

304 baseline (post install-script cycle) + ~28 new = **~332 passing, 0 failing**.
