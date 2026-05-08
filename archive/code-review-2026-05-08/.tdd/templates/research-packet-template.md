# Research packet — <cycle-id>

date: <YYYY-MM-DDTHH:MM:SSZ>
cycle_id: <slug, e.g. auth-token-rotation>
required_for: Tier 1 plans only

## Question

<The open question(s) the plan addresses. One paragraph.
Why is this hard? What did NOT have an obvious answer when you started?>

## Sources

<≥3 authoritative sources. URL, file path, or doc reference for each.
"Authoritative" means: official docs, peer-reviewed papers, vendor
post-mortems, the project's own ADRs, or canonical books — NOT random
blog posts unless they're from the maintainer of the relevant project.

Examples:
- https://pkg.go.dev/database/sql — Go database/sql package docs
- internal/migrations/ARCHITECTURE.md — project's own migration ADR
- https://www.postgresql.org/docs/16/sql-merge.html — Postgres MERGE docs
- "Designing Data-Intensive Applications" ch. 7 — Kleppmann on transactions>

1. <source 1>
2. <source 2>
3. <source 3>
<add more as needed>

## Findings

<What did each source say? One short paragraph per source. Cite the
specific section/page/example that mattered, not the whole document.>

### From <source 1>
<finding>

### From <source 2>
<finding>

### From <source 3>
<finding>

## Impact on the plan

<How did each finding shape the plan? Cite the plan section affected.

Examples:
- "Postgres MERGE docs (source 3) showed that ON CONFLICT DO UPDATE has
  better concurrency characteristics than MERGE for our case →
  plan 'Implementation' section uses ON CONFLICT, not MERGE."
- "The Kleppmann finding on retry idempotency (source 4) drove the
  decision to add an idempotency_key column → plan 'Schema' section."
>

## Uncertainty

<What is still unknown? What assumptions does the plan make that
might be wrong? What are the failure modes if the assumptions break?

This is the section where the reviewer (Codex Pass A and Pass B) will
focus hardest. Be honest. Empty uncertainty section = the reviewer
will probe harder than if you list real uncertainties up front.>

- <uncertainty 1: what assumption could be wrong, and what would break>
- <uncertainty 2>
- <uncertainty 3 if any>

## Notes

<Optional. Anything else that doesn't fit above. Stylistic preferences,
non-goals you considered and rejected, alternatives you weighed.>
