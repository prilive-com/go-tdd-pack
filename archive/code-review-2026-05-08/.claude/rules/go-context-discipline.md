# Context Discipline Rules

LLM performance degrades as context fills, well before the stated limits.

## Standing rules

- Use `/clear` between unrelated tasks.
- For read-heavy investigation, use a subagent — do not pollute the main
  context.
- For tasks spanning >50 messages, snapshot the plan to
  `specs/<feature>.md` and start fresh.
- Performance starts to degrade around 25–30k tokens regardless of the
  advertised window.
- When the session feels confused, that is the signal to clear, not to
  push harder.
- Prefer many small subagent contexts over one fat main context.
- Trust the file system. If you've already saved a plan or note, re-read
  it rather than re-summarizing it from memory.

## Session hygiene

- After completing a milestone (gate APPROVED, green commit), consider
  `/clear` and reload only the files needed for the next phase.
- Before invoking the `go-code-review` skill or any reviewer agent,
  consider whether to do it in a fresh context — reviewers benefit from
  not having the implementation reasoning in their context.
- For TDD cycles, the `.tdd/current-plan.md` and `.tdd/red-proof.md`
  files are the durable state. The chat is not.
