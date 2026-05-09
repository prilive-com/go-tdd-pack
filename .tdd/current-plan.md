# Bugfix Plan: f10-agents-md-update — refresh AGENTS.md + CLAUDE.md for v1.6.x state

Status: active
Cycle ID: f10-agents-md-update
Change type: docs (cleanup)
Tier: 0 (neither AGENTS.md nor CLAUDE.md matches tier1_path_regexes)

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

`AGENTS.md` (Codex-facing) and `CLAUDE.md` (Claude-CLI-facing) both
describe the pack's behavior, but the v1.6.x cycles added significant
operator-facing knobs that neither file mentions:

| Feature added | AGENTS.md mentions? | CLAUDE.md mentions? |
|---|---|---|
| second-opinion is **enforced** (not advisory) | No (line 222 says "advisory only") | No (similar) |
| F5: hash binding (`require_hash_binding_tier1`) | No | No |
| F6: enforcement_mode (strict/warn/off + overrides) | No | No |
| F8: matrix uses `F-EXAMPLE-N` placeholders | No | No |
| F9: canonical templates in `.tdd/templates/` | No | No |
| Killswitches (`TDD_COMMIT_GATE_DISABLE`, `SECOND_OPINION_DISABLE`, `SECOND_OPINION_HASH_DISABLE`) | No | No |

Concrete operator-facing impact:

1. **Stale guidance: "second-opinion is advisory only."** Operators reading
   AGENTS.md think they can skip the skill on Tier 1 work. Then the
   `require-second-opinion.sh` hook blocks their Edit with exit 2 and
   they're confused.

2. **No discoverable enforcement_mode docs.** Teams adopting the pack
   want to phase in (warn → strict). The config exists but the docs
   don't tell them.

3. **No killswitch documentation.** When a hook misfires in an
   emergency, operators don't know how to bypass cleanly. They might
   delete the hook file or git commit --no-verify, both worse than
   the documented env-var killswitch.

4. **Templates aren't discoverable.** F9 made `.tdd/templates/` the
   canonical source for the adjudication file and disposition matrix.
   AGENTS.md never mentions templates exist.

## Reproduction

```
grep -E "advisory only|enforcement_mode|hash_binding|killswitch|DISABLE|templates/" AGENTS.md
# Output (current state):
# - "advisory only" (mislabeling second-opinion)
# All other terms: no match.
```

## Acceptance criteria

1. AGENTS.md no longer says second-opinion is "advisory only".
2. AGENTS.md describes second-opinion as **required by the
   `require-second-opinion.sh` hook** when `codex` is available.
3. AGENTS.md has a section listing the 3 killswitches with one-line
   descriptions of when each is appropriate.
4. AGENTS.md mentions `enforcement_mode` and the 3 valid values
   (strict/warn/off) with one-line description of each.
5. AGENTS.md mentions `require_hash_binding_tier1` (F5) with a
   one-line description.
6. AGENTS.md references the `.tdd/templates/` directory as canonical
   for adjudication-completed.md and disposition-matrix.md.
7. CLAUDE.md gets the same updates (1-6) — keep parity unless there's
   a specific reason for divergence.
8. Smoke tests assert the new text is present in both files.

## Non-goals

- Restructuring either file. Surgical edits only.
- Adding a separate `OPERATOR_CONFIG.md`. Inline in AGENTS.md and
  CLAUDE.md is more discoverable for the audience that reads them.
- Generating both files from one source. They're allowed to diverge
  (per AGENTS.md line 28-30); shared content is currently duplicated
  by hand.
- Documenting every detail of every hook. Keep operator-facing
  surface only.

## Affected code

- `AGENTS.md` — fix line 222, add operator-facing knobs section
- `CLAUDE.md` — same updates
- `scripts/tdd-test-hooks.sh` — new self-tests

## Test plan

| Test name | Pins criterion # |
|---|---|
| f10_agents_md_no_advisory_only_for_second_opinion | 1 |
| f10_agents_md_describes_second_opinion_enforcement | 2 |
| f10_agents_md_mentions_killswitches | 3 |
| f10_agents_md_mentions_enforcement_mode | 4 |
| f10_agents_md_mentions_hash_binding | 5 |
| f10_agents_md_mentions_canonical_templates | 6 |
| f10_claude_md_no_advisory_only_for_second_opinion | 7 |
| f10_claude_md_mentions_killswitches | 7 |
| f10_claude_md_mentions_enforcement_mode | 7 |

## Minimum implementation

Add a new section to both AGENTS.md and CLAUDE.md (after the existing
"Skills available" or "Verification commands" section):

```markdown
## Operator config & killswitches

The `.tdd/tdd-config.json` carries operator-facing knobs that change
how the deny gates behave. Key fields:

- `enforcement_mode` (strict | warn | off; default strict). Applies
  to gate-tier1-commit, require-second-opinion, require-tdd-state,
  guard-bash-pipefail. `warn` emits stderr advisory + allows the
  tool call. `off` is silent passthrough. Per-hook override via
  `enforcement_mode_overrides: {hook-name: mode}`.

- `second_opinion.require_hash_binding_tier1` (default false). When
  true AND target path is Tier 1, require-second-opinion.sh denies
  if the recorded `diff_sha256` (sha of `git diff HEAD --cached`) or
  `plan_sha256` (sha of `.tdd/current-plan.md`) doesn't match
  current. Closes the bypass where a fresh adjudication for one diff
  silently covers later unrelated work.

Emergency env-var killswitches (document in commit message if used):

- `TDD_COMMIT_GATE_DISABLE=1` — bypass gate-tier1-commit.sh
- `SECOND_OPINION_DISABLE=1` — bypass require-second-opinion.sh
- `SECOND_OPINION_HASH_DISABLE=1` — bypass F5 hash binding only

Canonical templates (used by /second-opinion Step 6):

- `.tdd/templates/second-opinion-adjudication-template.md`
- `.tdd/templates/disposition-matrix-template.md`

The matrix template uses `F-EXAMPLE-N` placeholder rows; real rows
must use `F1`/`F2`/... — those are counted by the row-count gate
(F8 invariant).
```

Update line 222 of AGENTS.md from "advisory only" to a description of
actual enforcement. Same for the corresponding line in CLAUDE.md.

## Risk register

| Risk | Mitigation |
|---|---|
| Adding text expands files; line count grows | Keep new section ~30 lines per file. Acceptable cost for operator clarity. |
| AGENTS.md and CLAUDE.md drift further | They already differ; this cycle keeps them in lockstep on the operator-facing knobs. Document that intent. |
| Operator copies the wrong template | Templates are canonical (single source); SKILL.md instructs to copy them. Lower risk now than the old inline-heredoc world. |
