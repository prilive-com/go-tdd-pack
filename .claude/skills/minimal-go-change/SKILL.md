---
name: minimal-go-change
description: Plan and implement the smallest safe Go change. Use for routine Go work outside Tier 1.
license: MIT
version: 1.0.0
---

# Minimal Go Change

Use this skill before implementing any non-trivial Go change in code
outside Tier 1 paths.

## Plan-only first pass

Rules:

- Do NOT edit files during the plan-only pass.
- Identify the smallest existing code path to change.
- Prefer modifying existing code over creating new abstractions.
- Do NOT add new interfaces, packages, dependencies, config fields,
  goroutines, caches, background workers, or exported APIs unless
  required.
- Every new function/type must have a direct caller and direct reason.
- Search for existing implementations before creating new ones
  (`rg -t go`).
- Identify deletion and reuse opportunities.
- Define tests before implementation.
- State explicit non-goals.

## Output

1. Goal restatement
2. Existing code paths found
3. Minimal files to change
4. Files NOT to change
5. New code justification table
6. Tests to add/update
7. Risks
8. Implementation plan
9. Stop for approval unless user explicitly asked you to proceed

## Self-review before finishing

Apply the necessity gates from `.claude/rules/go-ai-bloat.md`. If any
gate fails, fix it.
