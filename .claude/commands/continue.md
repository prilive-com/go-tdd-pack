---
description: Resume the currently-active TDD cycle from its last saved state
---

The operator wants to continue work on the currently-active TDD cycle.

1. Read `.tdd/active` — this file contains the cycle ID of the most recently active cycle.
2. Read `.tdd/cycles/<cycle-id>/state.json` for that cycle. The JSON has fields: `cycle_id`, `status`, `next_actor`, `approved_rounds`, `updated_at`, `context_hint`.
3. Summarize the current state to the operator in 2-3 lines:
   - Cycle name + when it was last updated
   - Current status (pending / reviewing / approved / etc.)
   - Whose turn it is (next_actor)
   - The context_hint
4. Based on `next_actor`:
   - `claude`: continue the implementation work (write code, write tests, address review findings — whatever the cycle plan in `.tdd/current-plan.md` indicates is the next step).
   - `codex`: tell the operator to run `scripts/tdd/run-second-opinion.sh <review-type> <cycle-id>`. Do not run it yourself unless the operator explicitly confirms.
   - `human`: there's an escalation. Read the most recent `.tdd/cycles/<cycle-id>/debates.jsonl` entry if it exists; present the decision point to the operator.
   - `none`: cycle is done. Nothing to do — confirm with the operator whether to commit, move on, or open a new cycle.

If `.tdd/active` doesn't exist or the state.json is missing, say so plainly. Don't fabricate a cycle that doesn't exist. Suggest the operator either name a specific cycle via `/resume <cycle-id>` or start a new cycle.

Known limitation: this command exists as a fallback for [anthropics/claude-code#10373](https://github.com/anthropics/claude-code/issues/10373) — SessionStart hooks don't always inject context into brand-new conversations. If you (Claude) see this command being invoked because the SessionStart context was missing, that's expected.
