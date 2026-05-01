---
name: migration-review
description: Review a database migration (SQL, golang-migrate, goose, Flyway, etc.) for safety, reversibility, zero-downtime correctness. DB safety review is high-stakes; only invoke explicitly when reviewing a migration.
disable-model-invocation: true
license: MIT
version: 1.1.0
---

# Migration Review

Database migrations are one of the highest-blast-radius changes a repo
ships. Review every migration against these criteria before approval.

Migrations are Tier 1 by default — `go-tdd-feature` or `go-tdd-bugfix`
applies in addition to this review.

## Step 1: Reversibility

- Is there a DOWN migration (or equivalent rollback)?
- Does the DOWN migration actually undo the UP? (Common mistake: UP
  adds column X and backfills; DOWN drops column X but the backfilled
  data is gone.)
- Is the DOWN migration tested, or at least executed once in a
  throwaway environment?
- If rollback would cause data loss, is that called out explicitly?

If there is no safe rollback, the PR description must say so and justify
why forward-only is acceptable for this change.

## Step 2: Zero-downtime

For any database with uptime requirements:

- Is there any `ALTER TABLE` that locks the whole table? On Postgres,
  adding a column is fine; adding a `NOT NULL` column without a default
  on a large table is not.
- Is the migration compatible with both the currently-deployed
  application code AND the new application code?
- Does the deploy plan require: deploy schema change, let it settle,
  deploy app change, let it settle, cleanup?
- Are indexes created concurrently (`CREATE INDEX CONCURRENTLY` on
  Postgres)?

## Step 3: Concurrent correctness

- Are explicit `LOCK TABLE` statements scoped as tightly as possible?
- Is the migration idempotent? (Re-running should be safe.)
- Does it handle the case where previous migrations are partially
  applied (interrupted run)?
- Transactions: is DDL in a single transaction where the database
  supports it (Postgres does; MySQL often doesn't)?

## Step 4: Data migrations

If the migration also moves/transforms data:

- Schema change and data migration split into separate migrations?
- Batch size reasonable for production volume? (Processing 10M rows in
  one transaction is a production incident waiting to happen.)
- Progress tracking / resumability if the batch is large?
- Destructive transformations (DROPs, TRUNCATEs) explicitly gated behind
  a safety flag?

## Step 5: Application compatibility

- Does the currently-running application work with the new schema?
- Does the new application work with the old schema (needed during
  rolling deploy)?
- If a column is renamed, is the old name kept as a view/synonym during
  transition?

## Step 6: Review artifacts

Every migration PR should include:

- The migration SQL itself
- A plain-language description of what it does
- Expected execution time on production-sized data (at least an estimate)
- Rollback procedure
- Any feature flags needed during transition

## Findings format

For each issue:

- **Severity**: P0 (blocks merge), P1 (must fix before deploy), P2
  (should fix), P3 (nit)
- **File:line**
- **Problem**: concrete description of what will happen
- **Fix**: the smallest change that resolves it

## When in doubt

If any of the Step 2–4 questions has an uncertain answer, the PR is not
ready to merge. It's not ready to merge even if CI is green. Rollback
of a bad migration is often impossible — caution up front costs nothing.
