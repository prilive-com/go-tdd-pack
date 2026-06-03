Review this change.

The prompt below has two delimited sections — CHANGED and CONTEXT —
that you MUST distinguish. Findings on CHANGED lines are the author's
responsibility and may block; findings on CONTEXT lines belong to one
of two routes (see the line_scope rule below).

=== CHANGED (review and flag here) ===

This is the diff the author wants you to review. Findings tagged
`line_scope: "changed_line"` go here.

```diff
{{DIFF}}
```

=== CONTEXT (read-only — do not flag pre-existing code) ===

These files are provided for cross-file understanding (calls/contracts
that the changed code interacts with). The author did NOT modify them
in this diff. Two routes for findings that land here:

- If the changed code's behavior triggers an issue in CONTEXT
  (e.g. the change calls a CONTEXT function in a way that breaks
  the contract), tag the finding `line_scope: "change_triggered_context"`
  and explain in the body what the change did that surfaced this.
  These findings CAN block — the change is the cause.

- If the issue exists in CONTEXT and the change did NOT touch or
  trigger it, tag the finding `line_scope: "pre_existing_unrelated"`.
  These findings are informational only — the engine routes them to
  a speculative section and they NEVER drive must-address. The author
  is not on the hook for pre-existing tech debt.

Changed file paths in this diff:
{{REPO_TREE}}

If you need the broader repo layout, run `git ls-files` yourself.

{{TOOL_GROUNDING}}

## What I need from you

Return ONE JSON object matching the schema you were given. Do not add
prose before or after the JSON.

Fields:
- `verdict`: `"approve"` if there are no `blocker` or `major` findings
  with `line_scope ∈ {changed_line, change_triggered_context}`
  (minor and nit are OK to attach); `"request_changes"` otherwise.
  Pre-existing unrelated findings do NOT count toward request_changes.
- `summary_one_sentence`: ≤120 chars. What's the headline?
- `summary_one_paragraph`: ≤500 chars. The case for your verdict.
- `findings`: array. Each finding requires: severity, category, title,
  body, file, line, confidence (1-5), contradicts_grounding, and
  line_scope. Confidence is mandatory: 5=verified (you ran a
  tool/test/cited a doc), 4=high (read the surrounding code),
  3=likely, 2=plausible, 1=guess. Be honest. The line_scope rule is
  in the CONTEXT section above.
- `files_read`: array of files you actually opened (your audit trail).
- `questions_for_human`: array. Empty unless you genuinely cannot decide
  without the human.

REMEMBER:
- You may run commands and read files freely.
- You may NOT write to project files. If a finding requires editing
  code, describe the edit in the `body` field — do not make the edit
  yourself.
- The "no project writes" rule includes git commands that mutate state
  (`git add`, `git commit`, `git reset`, etc.).
