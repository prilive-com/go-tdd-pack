# Bugfix Plan: f12-migration-script-audit-warning — log + flag unfilled placeholders

Status: active
Cycle ID: f12-migration-script-audit-warning
Change type: cleanup + bugfix
Tier: 1 (require-second-opinion.sh modified)

<!-- TDD ceremony markers. Set each ONLY after the matching operator APPROVED reply. -->
Bug reproduced: yes
Human approved spec: yes
Red phase confirmed: yes
Green phase authorized: yes
Implementation reviewed: yes
Fix applied: yes
Regression tests added: yes
Bug-elsewhere check complete: yes

## Bug

Two migration scripts mutate audit-trail content but don't audit
themselves and produce output that LOOKS valid to the hooks while
carrying unfilled placeholders:

  scripts/migrate-tdd-markers.sh        — 3-marker plan → 4-marker plan
  scripts/migrate-rebuttal-to-matrix.sh — v1.5.x adjudication → v1.6.0 matrix

**Bug 1 — no audit trail.** Both scripts modify (or create) files
that the hooks read as authoritative state. If a script bug corrupts
state or an operator doesn't notice the migration ran, there's no
written record. This violates the rest of the pack's discipline
where every gate decision goes to an audit log.

**Bug 2 — placeholder text passes the hook.** `migrate-rebuttal-to-
matrix.sh` writes rows like:

```
| F1 | Codex | P1 | <migrated; fill in 1-line concern> | ACCEPT | <migrated from v1.5.x — fill in concrete reason> | yes |
```

The hook's PARTIAL discipline check looks for empty/n/a/none/blank/
<10 chars in the Reason column. The placeholder text is "<migrated
from v1.5.x — fill in concrete reason>" — 50 chars, doesn't match
anti-patterns → PASSES. The hook accepts a row that is BY DEFINITION
not real adjudication.

Same shape: the inserted Concern column ("<migrated; fill in 1-line
concern>") and the Reason column for non-PARTIAL stances. Operators
who skip the post-migration edit step would have an audit trail that
looks complete but contains template-shaped lies.

## Reproduction

```
# Create a v1.5.x adjudication with a generic ACCEPT finding
cat > /tmp/adj.md <<EOF
date: 2026-05-09T00:00:00Z
scope: Tier 1
model: gpt-5.5
findings_total: 1
findings:
  - id: F1
    severity: P1
    stance: ACCEPT
adjudicated_by: claude
EOF

scripts/migrate-rebuttal-to-matrix.sh /tmp/adj.md
# Produces /tmp/codex/disposition-matrix.md with placeholder Reason

# The require-second-opinion.sh PARTIAL discipline check would not
# flag this — the placeholder text is "substantive" by length but
# meaningless by content.

# Also: nothing in .tdd/ logs that migration ran.
ls .tdd/migration-audit.log 2>&1
# ls: cannot access '.tdd/migration-audit.log': No such file or directory
```

## Acceptance criteria

1. `scripts/migrate-tdd-markers.sh` writes a structured entry to
   `.tdd/migration-audit.log` with timestamp + script name + input
   path + summary of what changed (e.g., "renamed M3", "inserted M4").
2. `scripts/migrate-rebuttal-to-matrix.sh` writes a structured entry
   to `.tdd/migration-audit.log` with timestamp + script name +
   input/output paths + finding count.
3. `scripts/migrate-rebuttal-to-matrix.sh` emits a prominent stderr
   warning when the output file contains `<migrated; ` or
   `<migrated from v1.5.x` placeholders, listing what needs operator
   action.
4. `require-second-opinion.sh` denies (during the matrix-row-count
   check) if any matrix Reason column cell contains a
   `<migrated; ` / `<migrated from` / `<fill in` placeholder. The
   PARTIAL discipline check's anti-pattern list is extended to
   include these placeholder shapes.
5. Existing smoke tests still pass.
6. New smoke tests:
   - migrate-tdd-markers.sh appends the audit log entry
   - migrate-rebuttal-to-matrix.sh appends the audit log entry
   - migrate-rebuttal-to-matrix.sh emits placeholder warning when
     output has `<migrated; ` rows
   - require-second-opinion.sh denies on matrix with
     `<migrated; ` / `<fill in` placeholders

## Non-goals

- Refusing to run the migration on locked plans/matrices. The scripts
  remain operator-driven; we just add visibility + post-migration
  detection.
- Auto-filling the placeholders. Operator judgment is required.
- Validating placeholder syntax in arbitrary Markdown — only the
  matrix Reason column matters for the hook check.

## Affected code

- `scripts/migrate-tdd-markers.sh` — add audit log line
- `scripts/migrate-rebuttal-to-matrix.sh` — add audit log line +
  placeholder-warning detection
- `.claude/hooks/require-second-opinion.sh` — extend the matrix's
  Reason placeholder anti-pattern list to include `<migrated; `,
  `<migrated from`, `<fill in`
- `scripts/tdd-test-hooks.sh` — new smoke tests
- `.gitignore` — add `.tdd/migration-audit.log`

## Test plan

| Test name | Pins criterion # |
|---|---|
| f12_marker_migration_writes_audit_log | 1 |
| f12_matrix_migration_writes_audit_log | 2 |
| f12_matrix_migration_warns_on_placeholders | 3 |
| f12_hook_denies_matrix_with_migrated_placeholder | 4 |
| f12_hook_denies_matrix_with_fill_in_placeholder | 4 |
| f12_hook_allows_matrix_without_placeholders | 4 (regression) |

## Minimum implementation

### Audit log helper (inlined per script for portability)

```bash
audit_migration() {
  local script="$1" summary="$2"
  local log_dir="$(dirname "${PLAN:-.tdd/x}")"
  local log="${log_dir}/migration-audit.log"
  mkdir -p "$log_dir" 2>/dev/null
  printf '%s script=%s input=%s summary=%q\n' \
    "$(date -u +%FT%TZ)" "$script" "${INPUT_PATH:-?}" "$summary" \
    >> "$log" 2>/dev/null || true
}
```

### Hook anti-pattern extension

In `require-second-opinion.sh` Tier 1 require_matrix branch, add
a placeholder-detection step after the row-count check:

```bash
placeholder_row="$(grep -nE '<migrated;|<migrated from|<fill in' "$matrix" | head -1)"
if [[ -n "$placeholder_row" ]]; then
  deny "Disposition matrix contains unfilled placeholder text (${placeholder_row}). \
Migration scripts produce template placeholders that need operator action. \
Edit the matrix to add concrete content or restore the original artifact." \
       "matrix_unfilled_placeholder" "$TARGET"
fi
```

### Placeholder warning in migrate-rebuttal-to-matrix.sh

After writing `$OUT`, scan and warn:

```bash
if grep -qE '<migrated;|<migrated from|<fill in' "$OUT"; then
  cat >&2 <<WARN
[migrate-rebuttal-to-matrix] WARNING: $OUT contains unfilled placeholders.
The require-second-opinion.sh hook will DENY edits until you fix them.
Run: grep -n '<migrated;\|<migrated from\|<fill in' "$OUT"
WARN
fi
```

## Risk register

| Risk | Mitigation |
|---|---|
| Audit log grows unbounded over many migrations | Append-only; operators rarely run migrations more than once per plan/matrix. Acceptable for v1. |
| Hook denies matrix that legitimately uses `<migrated; ` text in a Reason column (e.g., describing a migration in code) | Vanishingly rare; operator can edit out the literal string. The placeholder phrasing is intentionally distinctive. |
| Both migration scripts assume `.tdd/` exists | Already true (mkdir guarded). Audit log path uses dirname of input, falls back to `.tdd/`. |
| Adds another deny path to require-second-opinion.sh; risk of test churn | Existing smoke tests don't write `<migrated; ` text in fixtures; should be neutral. |
