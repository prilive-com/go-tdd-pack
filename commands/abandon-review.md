---
description: Abandon the current review cycle. Use when the user wants to skip review for the current change.
---

# /abandon-review

Mark the current cycle as abandoned so future edits start fresh cycles.

## What to do

1. Read `.tdd/reviews/state.json` to confirm there's an active cycle.
2. If status is already a terminal state (`converged`, `failed`, `abandoned`, `resolved_by_user_*`), tell the user "no cycle to abandon" and stop.
3. Otherwise, update state.json to set status to `abandoned`:

```bash
jq -n \
  --arg ts "$(date -u +%FT%TZ)" \
  --arg cycle "$(jq -r '.cycle_id' .tdd/reviews/state.json)" \
  --arg round "$(jq -r '.round' .tdd/reviews/state.json)" \
  '{cycle_id:$cycle, status:"abandoned", round:($round|tonumber), updated_at:$ts}' \
  > .tdd/reviews/state.json.tmp && mv .tdd/reviews/state.json.tmp .tdd/reviews/state.json
```

4. Append an audit log entry to `.tdd/reviews/debates.jsonl`:

```bash
jq -nc \
  --arg cycle "$cycle_id" --arg ts "$(date -u +%FT%TZ)" \
  --argjson round "$round" \
  '{cycle_id:$cycle, ts:$ts, round:$round, event:"abandoned_by_user"}' \
  >> .tdd/reviews/debates.jsonl
```

5. Confirm to the user: "Cycle <cycle_id> abandoned. Next edit will start a fresh cycle."

## When to use this command

- The user explicitly says "abandon" / "skip" / "drop this review"
- After an A/B/V escalation when the user wants to bypass without picking A or B
- When the user is mid-refactor and wants to defer review

## Notes

- The cycle directory under `.tdd/reviews/<cycle_id>/` is kept for audit. Only state.json is updated.
- Once abandoned, the runner can start fresh cycles on subsequent edits. The blocking guard in `runner/review-runner.sh` does not block on terminal states.
- If you want to permanently disable review (not just for this cycle), the user should use `export PRILIVE_REVIEW_DISABLE=1` instead.
