---
description: After an A/B/V escalation, accept Claude's version (ship as-is, don't apply Codex's recommendations).
---

# /accept-claude

Resolve an escalated review cycle by accepting Claude's version. The cycle ends; no further changes are made.

## When this applies

This command is meaningful only when `.tdd/reviews/state.json` shows `status: escalated`. The escalation message (from `runner/escalate.sh`) gives the user three choices: [A] ship Claude's version, [B] apply Codex's recommendations, [V] view transcripts. This command is the [A] choice.

## What to do

1. Read `.tdd/reviews/state.json` to confirm status is `escalated`.
2. If not, tell the user "no escalated cycle to resolve" and stop.
3. Update state.json to set status to `resolved_by_user_claude`:

```bash
cycle_id=$(jq -r '.cycle_id' .tdd/reviews/state.json)
round=$(jq -r '.round' .tdd/reviews/state.json)

jq -n \
  --arg ts "$(date -u +%FT%TZ)" \
  --arg cycle "$cycle_id" \
  --argjson round "$round" \
  '{cycle_id:$cycle, status:"resolved_by_user_claude", round:$round, updated_at:$ts}' \
  > .tdd/reviews/state.json.tmp && mv .tdd/reviews/state.json.tmp .tdd/reviews/state.json

jq -nc \
  --arg cycle "$cycle_id" --arg ts "$(date -u +%FT%TZ)" \
  --argjson round "$round" \
  '{cycle_id:$cycle, ts:$ts, round:$round, event:"resolved_by_user_claude"}' \
  >> .tdd/reviews/debates.jsonl
```

4. Confirm to the user: "Cycle <cycle_id> resolved as ship Claude's version. The runner will accept new cycles on the next edit."

## Notes

- This is a TERMINAL state. The cycle is closed; Codex's findings become "won't fix" with the user's explicit blessing.
- No code is modified. The current working tree is what ships.
- If the user later changes their mind, they'd need to manually apply Codex's recommendations from `.tdd/reviews/<cycle_id>/round-<max>.txt`.
- The opposite command is `/accept-codex` (apply Codex's recommendations).
- The neutral exit is `/abandon-review` (drop the cycle without picking a side).
