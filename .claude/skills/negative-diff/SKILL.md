---
name: negative-diff
description: Post-implementation cleanup pass that explicitly looks for code to delete, inline, or reuse rather than add. Run after implementation is complete and tests pass.
license: MIT
version: 1.0.0
---

# Negative Diff

Cleanup pass scoped to the current PR's recent additions.

## Scope

- Last commit / current branch's added code only.
- Do NOT delete legacy code you don't fully understand.

## Process

1. Run mechanical tools first:
   - `staticcheck ./...`
   - `deadcode ./...`
   - `unparam ./...`

2. For each new symbol added in this PR:
   - Two real callers? If no → delete or inline.
   - Existing equivalent in repo? If yes → reuse.
   - Added "for future use"? If yes → delete.
   - Interface with one implementation? If yes → replace with concrete.

3. For each new dependency:
   - Could 30 lines of stdlib replace it? If yes → remove.
   - Already a similar package in go.mod? If yes → consolidate.

4. For each new test:
   - Verifies only that the mock was called? If yes → rewrite or delete.
   - Could the test fail meaningfully? If no → rewrite.

## Output

A delete-list: `file:line:symbol:reason`. Then minimal cleanup patches.

## Forbidden

- Deleting load-bearing legacy code without understanding it.
- Refactoring while deleting (one concern at a time).
- Restructuring file organization (different concern).

## When this skill applies

- After every Tier 1 cycle, before declaring done.
- After any PR over 200 lines.
- During quarterly cleanup passes (with `go-modernize`).
