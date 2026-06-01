# Pre-review user prompt — file change

Claude wants to apply this file change. Review it before it lands and
return your verdict per the system prompt.

## Payload

```json
{{PAYLOAD}}
```

## What to look at

Depending on `tool_name` in the payload:

- `Write` — full content goes in `write_content`. The file at
  `file_path` will be overwritten with this exact content.
- `Edit` — single string replace. `edit_old_string` becomes
  `edit_new_string` at `file_path`.
- `MultiEdit` — sequence of replaces in `multi_edits[]`. Applied in
  order; each `old_string → new_string` swap at `file_path`.
- `NotebookEdit` — Jupyter notebook cell. `notebook_source` is the new
  cell body; `notebook_cell_id` is the cell.

## What matters

- Correctness — does the change do what its surrounding context says it
  should?
- Safety — does it drop a sentinel, break a contract, or remove an
  invariant that other code depends on?
- Data-loss — does an `Edit` or `Write` overwrite content that looks
  hand-authored or load-bearing?
- Obvious mistakes — wrong file, wrong package, broken imports, dropped
  closing brace.

You may consult the repo (read-only) if the payload alone is
insufficient. Do not run state-changing commands.

## Output

Strict JSON per the supplied schema. `classification` must be
`file_change`.
