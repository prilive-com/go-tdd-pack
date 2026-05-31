---
description: Show the most recent Codex review cycle with all findings, verdict, and current state.
---

# /show-review

Show the user the most recent Codex review cycle.

## What to do

1. Read `.tdd/reviews/state.json` to get the current `cycle_id`, `status`, and `round`.
2. If `cycle_id` is empty or state file is missing, tell the user "no review cycle has run yet" and stop.
3. Read `.tdd/reviews/<cycle_id>/round-1.json` to get the structured round 1 findings.
4. Read each `.tdd/reviews/<cycle_id>/round-N.txt` for any rounds 2+ (free-form Codex output).
5. Read each `.tdd/reviews/<cycle_id>/claude-response-N.txt` for Claude's responses between rounds.
6. Summarize for the user, in this shape:

```
Cycle: <cycle_id>
Status: <status>  (round: <round> of <max_rounds>)
Started: <round 1 timestamp from debates.jsonl if available>

Round 1 verdict: <verdict>
Summary: <summary_one_sentence>

Findings (N total):
  - [<severity>/<category> c=<confidence>] <title>
    <one-line body excerpt>
    at <file>:<line>
  ...

Round 2: <verdict from extract-verdict.sh on round-2.txt>
Round 3: ...
```

## When to use this command

- After an escalation message, when the user wants more detail than the A/B/V message gave
- When the user asks "what did Codex find?" or "show me the latest review"
- When debugging unexpected pack behavior

## Notes

- This is a read-only command. It does not modify any state.
- All artifacts live under `.tdd/reviews/<cycle_id>/` — read them directly with the Read tool, don't try to parse via the runner.
- If `round-1.json` is missing or unparseable, surface that as part of the summary; don't crash.
