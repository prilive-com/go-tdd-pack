Review this change.

## Repository tree (top 50 lines)
{{REPO_TREE}}

## The diff under review
```diff
{{DIFF}}
```

## What I need from you

Return ONE JSON object matching the schema you were given. Do not add
prose before or after the JSON.

Fields:
- `verdict`: `"approve"` if there are no `blocker` or `major` findings
  (minor and nit are OK to attach); `"request_changes"` otherwise.
- `summary_one_sentence`: ≤120 chars. What's the headline?
- `summary_one_paragraph`: ≤500 chars. The case for your verdict.
- `findings`: array. Each has severity, category, title, body, optional
  file, optional line.
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
