# Concern Disposition Matrix — <cycle-id>

date: <YYYY-MM-DDTHH:MM:SSZ>
cycle_id: <slug>
findings_total: <N — must equal row count below>
codex_session: <session-id>
codex_model: <model name>
review_phase: <plan | diff>

<This file replaces the v1.5.x free-form rebuttal text. Every Codex
finding (including P3 nits) MUST have a row. Disposition column is
mandatory. Smoke test enforces row count == findings_total.>

## Cross-cutting observations

<0-3 sentences. Empty if no cross-cutting pattern across findings.

Examples:
- "Three findings (F2, F5, F7) point at error handling. Style change in
  cycle scope: stop wrapping errors with %w in lib code; use sentinel
  errors instead. Affects F2/F5/F7 simultaneously."
- "Two findings (F1, F4) are about the same goroutine spawn. Single
  fix in plan resolves both."
- "No cross-cutting patterns."
>

## Findings table

<One row per Codex finding. Disposition values: ACCEPT | PARTIAL | REJECT | PUSHBACK.

Reason column requirements:
- P0 ACCEPT: must include the literal phrase "Why this is correct:"
  followed by ≥3 sentences explaining the underlying technical claim.
- PARTIAL (any severity): must include all three sub-sections inline:
    What I am accepting: <concrete change>
    What I am rejecting: <concrete claim — NOT "nothing"/"n/a"/"none"/blank>
    Why this split is correct: <≥2 sentences>
- REJECT, PUSHBACK, P1+ ACCEPT: ≥1 sentence concrete reason. "External
  reviewer flagged X" is NEVER acceptable as the reason; the reason is
  the underlying technical claim.

Spec change column: yes | partial | no.>

| ID | Source | Severity | Concern (1 line) | Disposition | Reason | Spec change |
|----|--------|----------|------------------|-------------|--------|-------------|
| F-EXAMPLE-1 | Codex  | P0       | <one-line concern> | <ACCEPT|PARTIAL|REJECT|PUSHBACK> | <reason per discipline rules above> | <yes|partial|no> |
| F-EXAMPLE-2 | Codex  | P1       | ... | ... | ... | ... |
| F-EXAMPLE-3 | Codex  | P2       | ... | ... | ... | ... |

<!--
NOTE on placeholder IDs: rows above use F-EXAMPLE-N intentionally so the
hook's row-count regex (^\|[[:space:]]+F[0-9]+[[:space:]]+\|) does NOT
match them. When Claude writes real adjudication rows, use F1, F2, F3,
... — those WILL be counted by the regex. Closes F8 from the combined
v1.6.0 review (placeholder rows were previously counted as real findings,
masking unedited-template adjudications as complete).
-->

<add rows until every finding from Codex's JSON output has a row>

## Pass A divergences (Tier 1 only)

<This section appears only when Pass A produced an independent design.
List the major divergences between Codex's independent design and
Claude's plan, with Claude's stance on each divergence.

Format: one bullet per divergence. Mark whether the divergence was
addressed by a finding (referenced by F-ID) or is a stylistic-only
difference Claude is overriding.

Examples:
- Codex Pass A used MERGE; Claude used ON CONFLICT. Stylistic — both
  correct; Claude prefers ON CONFLICT for the project's existing patterns.
- Codex Pass A added an idempotency_key column; Claude did not.
  Addressed by F2 (P1 ACCEPT) — plan now includes the column.
>
