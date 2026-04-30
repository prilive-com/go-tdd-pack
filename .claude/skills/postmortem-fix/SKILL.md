---
name: postmortem-fix
description: Turn an escaped defect or production incident into a concrete prevention patch plan.
license: MIT
version: 1.0.0
---

# Postmortem Fix

Given a defect that made it to production, or a test/review escape, turn
the incident into prevention — not just a fix.

## Step 1: State the user-visible failure

One sentence. What did the user, operator, or downstream system see?

Do not describe the internal bug yet. Describe the observation.

## Step 2: State the true root cause

The root cause is the earliest decision or assumption that made the
failure possible, not the last line that misbehaved. Ask "why" until
you reach something actionable.

- **Symptom**: what broke
- **Proximate cause**: which line of code was wrong
- **Root cause**: what allowed the wrong line to ship

Example:

- Symptom: Orders weren't being placed after 2am UTC.
- Proximate cause: Cron job's timezone was local, not UTC.
- Root cause: No convention or lint rule requires explicit timezones in
  scheduled-job config.

## Step 3: Identify what control failed

Not all bugs are bugs-in-code. Most escaped defects reveal a process gap:

- **Missing invariant**: the code didn't encode an assumption it relies
  on
- **Missing test**: the failure scenario had no test that would catch it
- **Missing review discipline**: the reviewer missed what reviewers are
  expected to catch
- **Missing hook/gate**: CI or pre-commit didn't reject the bad pattern
- **Missing policy**: the team has no convention for handling this class
  of change
- **Architecture boundary leak**: code in module A depended on an
  internal detail of module B

Name specifically which control was absent.

## Step 4: Propose the prevention patch

Multi-layer. Do not stop at one fix.

- **Code fix**: the smallest change that makes the current symptom go
  away
- **Test**: a test that would have caught the original bug
- **Invariant or assertion**: a runtime/static check that makes the
  class of bug structurally impossible
- **Policy or review rule**: if a reviewer should have caught it, add
  that to `REVIEW.md` or the relevant rule file
- **Hook or CI gate**: if automation should have caught it, add the
  gate

You always need at least code fix + test. For P0/P1 incidents, expect
to need at least three layers.

## Step 5: Prevention summary

One paragraph stating:

- What the failure was
- What control failed
- What's in place now to prevent recurrence
- What to monitor to know the prevention worked

## Anti-patterns

- Fixing only the symptom and declaring victory.
- Adding one very specific test but no general invariant.
- Blaming the reporter's workflow instead of fixing the code.
- Rewriting unrelated code "to prevent similar issues" — that expands
  scope and loses focus. Prevent recurrence *of this bug*, not of every
  bug that might loosely rhyme with it.

## When this is a Tier 1 path

Use the `go-tdd-bugfix` workflow first to capture the bug as a failing
test. Then apply the prevention layers from this skill.
