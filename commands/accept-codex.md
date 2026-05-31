---
description: After an A/B/V escalation, accept Codex's recommendations (apply the suggested changes).
---

# /accept-codex

Resolve an escalated review cycle by applying Codex's recommendations from its final review.

## When this applies

This command is meaningful only when `.tdd/reviews/state.json` shows `status: escalated`. The escalation message (from `runner/escalate.sh`) gives the user three choices: [A] ship Claude's version, [B] apply Codex's recommendations, [V] view transcripts. This command is the [B] choice.

## What to do

1. Read `.tdd/reviews/state.json` to confirm status is `escalated`. If not, tell the user "no escalated cycle to resolve" and stop.

2. Read Codex's final review for actionable recommendations:
   - For round 1 issues: `.tdd/reviews/<cycle_id>/round-1.json` — extract each finding with `severity in {blocker, major, minor, nit}` and `confidence >= 3`.
   - For rounds 2+: `.tdd/reviews/<cycle_id>/round-<max>.txt` — extract remaining open items listed above the VERDICT line.

3. Apply each finding's suggested fix:
   - Read the relevant file at the cited `file:line`.
   - Make the fix described in the finding's `body` field (or for round N, the bulleted item).
   - For findings with explicit code snippets in the body, apply them as-is.
   - For findings that are vague ("consider X"), make your best judgment and add a comment noting the source: `// Per Codex review <cycle_id>`.

4. After all fixes are applied, update state.json:

```bash
cycle_id=$(jq -r '.cycle_id' .tdd/reviews/state.json)
round=$(jq -r '.round' .tdd/reviews/state.json)

jq -n \
  --arg ts "$(date -u +%FT%TZ)" \
  --arg cycle "$cycle_id" \
  --argjson round "$round" \
  '{cycle_id:$cycle, status:"resolved_by_user_codex", round:$round, updated_at:$ts}' \
  > .tdd/reviews/state.json.tmp && mv .tdd/reviews/state.json.tmp .tdd/reviews/state.json

jq -nc \
  --arg cycle "$cycle_id" --arg ts "$(date -u +%FT%TZ)" \
  --argjson round "$round" \
  '{cycle_id:$cycle, ts:$ts, round:$round, event:"resolved_by_user_codex"}' \
  >> .tdd/reviews/debates.jsonl
```

5. Summarize for the user what was changed and confirm: "Applied N Codex findings. Cycle <cycle_id> resolved."

## Notes

- This is a TERMINAL state. After applying changes, the runner will pick up the new edits via the standard fresh-cycle path (it's not the same cycle — that one is closed).
- You may end up with a NEW round of review on the changes you just made (this is normal — Codex's recommendations may not be perfectly correct, and the next cycle will catch any issues).
- If a finding's recommendation is unclear or seems wrong, skip it and note in your response which findings you skipped and why.
- The opposite command is `/accept-claude` (keep Claude's version).
- The neutral exit is `/abandon-review` (drop without applying or accepting).
