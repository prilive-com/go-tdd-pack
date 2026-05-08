---
name: minimal-go-change
description: Plan and implement the smallest safe Go change with red-before-green where tractable. Use for any routine Go change to non-Tier-1 paths — small features, bug fixes, refactors, lint cleanups, dependency bumps, or any change where the user says "implement", "add", "fix", "update", "change", or "refactor" and the touched paths are NOT covered by .tdd/tdd-config.json tier1_path_regexes.
license: MIT
version: 1.1.0
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
