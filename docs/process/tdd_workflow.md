# TDD Workflow (Tier Model)

This document describes the tiered TDD discipline applied to Go changes
in this repository. It is referenced by:

- `.claude/skills/go-tdd-feature/SKILL.md`
- `.claude/skills/go-tdd-bugfix/SKILL.md`
- `.claude/hooks/route-to-tdd.sh` (advisory router)
- `.claude/hooks/require-tdd-state.sh` (blocking gate on Tier 1)

## Tier Model

| Tier | Trigger | Process |
|------|---------|---------|
| **Tier 1 — Full ceremony** | File matches `.tdd/tdd-config.json` `tier1_path_regexes` | spec → APPROVED → red proof → APPROVED → green → cleanup. Two human gates. Plan markers required. Hook blocks production edits. |
| **Tier 2 — Standard discipline** | Production Go code outside Tier 1 | `minimal-go-change` skill. Red-before-green where tractable. Race detector green. No plan file. No hook blocks. |
| **Tier 3 — Light** | Test infrastructure, refactors with full coverage | No ceremony. CI catches regressions. |
| **Tier 4 — None** | Docs, CHANGELOG, `.claude/` config, CI YAML | No process. Hooks silent on these paths. |

## Tier 1 — Full cycle

```
1. Spec → .tdd/current-plan.md filled in.
2. STOP. Operator: APPROVED.
3. Set marker: Human approved spec: yes.
4. Write failing tests. Run them. Capture VERBATIM output to .tdd/red-proof.md.
5. Fill "Why this is not a false red" section.
6. Commit: red(<id>): <description>
7. Set marker: Red phase confirmed: yes.
8. STOP. Operator: APPROVED.
9. Set marker: Human approved implementation: yes.
10. Hook now permits production edits.
11. Implement. Tests go green. Race detector green.
12. Commit: green(<id>): <description>
13. Set marker: Green phase confirmed: yes.
14. Refactor (no behavior change). Linters green.
15. Commit: refactor(<id>): <description> (separately).
16. Set marker: Refactor phase complete: yes.
17. Final test sweep. Update CHANGELOG.
```

## Gate vocabulary

- **APPROVED** — advance phase
- **CHANGES <reason>** — revise current phase, re-ask
- **STOP** — halt, leave partial state

## Forbidden

- **Self-approving.** Never set "Human approved implementation: yes"
  without an explicit APPROVED reply from the human.
- **Editing tests in green phase.** If tests need changes, the spec
  was incomplete. STOP, return to red.
- **Paraphrased red proof.** Verbatim test output is the artifact that
  proves the test ran and failed.
- **False reds.** The "Why this is not a false red" section must
  explain that the failure is genuine, not a setup error.

## Bypass procedure

For an emergency hotfix where the operator vouches for the change:

1. Edit `.tdd/current-plan.md` to set the three required markers to
   `yes`.
2. Document the bypass reason in the commit message.
3. Open a follow-up issue to add the missing test.
4. The CI `tdd-ceremony-check` job will flag the missing red commit;
   the bypass reason should be in the PR/MR description.

## Why this exists

Two human gates on Tier 1 paths catches the failure mode where the
agent infers the wrong invariant from the user's request and writes
plausible-but-wrong code. By forcing a spec-then-failing-test
checkpoint, the human gets two chances to redirect before any
production code is touched.

The hook is the structural defense. CLAUDE.md rules are advisory —
documented incidents prove the agent will violate text rules under
pressure.
