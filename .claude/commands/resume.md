---
description: Resume a specific TDD cycle by ID
argument-hint: <cycle-id>
---

The operator wants to resume a specific TDD cycle named `$1` (the argument they passed).

1. Read `.tdd/cycles/$1/state.json`. If the file doesn't exist, list the available cycles by checking `ls .tdd/cycles/` and ask the operator which one they meant.
2. If the file exists, summarize:
   - When it was last updated
   - Current status (pending / reviewing / approved / etc.)
   - Whose turn it is (next_actor)
   - The context_hint
3. Update `.tdd/active` to point at this cycle so subsequent SessionStart hooks pick it up: `echo "$1" > .tdd/active`. (This is OK to do — `.tdd/active` is operator-managed metadata, not gated.)
4. Then act on the cycle per `next_actor`, same logic as `/continue`:
   - `claude`: continue the implementation per `.tdd/current-plan.md`.
   - `codex`: tell the operator the runner command to run.
   - `human`: surface the escalation point.
   - `none`: cycle is done; confirm next action with operator.

If the cycle doesn't exist, don't fabricate it. List the real cycles via `ls .tdd/cycles/` and suggest names.
