---
name: specify
description: Spec-driven Layer 0 — capture intent, non-goals, acceptance criteria as a tracked spec under specs/ before writing any non-trivial code. Drives Specify -> Plan -> Tasks -> Implement with three human approval gates. Use whenever the user asks to design, plan, spec out, scope, or implement something that spans more than ~1 hour, touches public API, touches a Tier 1 path, or has non-trivial business invariants.
license: MIT
version: 1.1.0
---

# Specify - Layer 0 Spec Gate

For any non-trivial change, capture the spec before code.

## Workflow

1. Create `specs/<feature-name>/spec.md`:
   - Goal (one paragraph, observable)
   - Non-goals (forced explicit)
   - User-visible behavior
   - Acceptance criteria (numbered, testable)
   - Out of scope
   - Risks
   - Dependencies

2. Stop. Ask: "Spec drafted at `specs/<feature-name>/spec.md`. Reply
   APPROVED or list changes."

3. After APPROVED, create `specs/<feature-name>/plan.md`:
   - High-level approach (3-5 bullets, no implementation)
   - Files to change (estimate)
   - Files NOT to change (forced explicit)
   - Test plan
   - Migration story (if applicable)

4. Stop. Ask: "Plan drafted. Reply APPROVED or list changes."

5. After APPROVED, create `specs/<feature-name>/tasks.md`:
   - Numbered work items
   - Each item has acceptance test reference

6. Then proceed to implementation. For Tier 1 paths, switch to
   `go-tdd-feature` or `go-tdd-bugfix`.

## When this skill applies

- Any change spanning >1 hour or >50 messages
- Any change touching public API
- Any Tier 1 path change
- Any change with non-trivial business invariants

## When to skip

- Doc fixes, typos, formatting
- One-line bug fixes with obvious cause
- Test-only changes
