---
name: go-code-review
description: Run a Staff+ Go code review against the current diff (correctness, security, concurrency, AI-bloat, TDD ceremony, tests). Use when the user asks to review, audit, look at, sanity-check, or get a second opinion on the current changes / branch / PR. Applies REVIEW.md and rules in .claude/rules/.
license: MIT
version: 1.1.0
---

# Go Code Review

Review the Go change using REVIEW.md and `.claude/rules/`.

## Required output structure

1. Review packet quality
2. Changed-files risk map
3. Executive summary (project type, decision, top 3 risks)
4. Business / domain invariants
5. Important findings
6. P2 should-fix
7. P3 nits (max 5)
8. Go-specific deep checks
9. AI-bloat / necessity review
10. TDD ceremony check (if Tier 1 path touched)
11. Test evidence
12. Release / compatibility
13. Follow-up tickets

## Rules

- Every Important finding includes file:line, code quote, trigger,
  failure scenario, minimal fix, tests.
- Do not block on taste.
- Do not invent evidence.
- Do not claim commands were run unless they were.
- Cap nits at 5.

## When to delegate

For deep specialty review, delegate to a subagent in a fresh context:

- Concurrency-heavy diff → `go-concurrency-reviewer`
- Security-relevant diff → `go-security-reviewer`
- Architecture/boundary change → `go-architect`
- Test quality concerns or TDD ceremony check → `go-test-engineer`
- Post-implementation cleanup audit → `go-bloat-reviewer`
