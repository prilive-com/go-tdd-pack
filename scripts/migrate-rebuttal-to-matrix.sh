#!/usr/bin/env bash
# One-shot conversion: take a v1.5.x adjudication artifact
# (.tdd/second-opinion-completed.md with `findings:` YAML block) and
# produce a v1.6.0 disposition matrix (.tdd/codex/disposition-matrix.md).
#
# Idempotent: running on an already-migrated state is a no-op.
#
# Usage:
#   scripts/migrate-rebuttal-to-matrix.sh [path-to-adjudication]
#   scripts/migrate-rebuttal-to-matrix.sh             # default: .tdd/second-opinion-completed.md
#
# What it produces:
#   .tdd/codex/disposition-matrix.md with one row per finding from the
#   input artifact's `findings:` YAML block.
#
# What it doesn't do:
#   The input artifact's `findings:` blocks may have varying levels of
#   detail. The migration preserves what's there but does not synthesize
#   missing fields. Any post-migration edits (especially adding
#   substantive Reason text for PARTIAL discipline) are the operator's
#   responsibility.

set -euo pipefail

ADJUDICATION="${1:-.tdd/second-opinion-completed.md}"

if [[ ! -f "$ADJUDICATION" ]]; then
  echo "[migrate-rebuttal-to-matrix] No adjudication at $ADJUDICATION — nothing to migrate." >&2
  exit 0
fi

OUT_DIR="$(dirname "$ADJUDICATION")/codex"
OUT="$OUT_DIR/disposition-matrix.md"

# F12: structured audit-log helper. Migrations mutate audit-trail
# content; append-only log records what ran. Never blocks the migration.
audit_migration() {
  local summary="$1"
  local log_dir log_file
  log_dir="$(dirname "$ADJUDICATION")"
  log_file="$log_dir/migration-audit.log"
  # Codex round 1 P2: append `|| true` to mkdir AND printf so the
  # helper truly never blocks under set -e (e.g., readonly fs).
  mkdir -p "$log_dir" 2>/dev/null || true
  printf '%s script=migrate-rebuttal-to-matrix input=%s output=%s summary=%q\n' \
    "$(date -u +%FT%TZ)" "$ADJUDICATION" "$OUT" "$summary" \
    >> "$log_file" 2>/dev/null || true
}

if [[ -f "$OUT" ]]; then
  echo "[migrate-rebuttal-to-matrix] Matrix already exists at $OUT — no-op." >&2
  audit_migration "no-op (output already exists)"
  exit 0
fi

mkdir -p "$OUT_DIR"

date_v="$(awk '/^date:/ { sub(/^date:[[:space:]]*/, ""); print; exit }' "$ADJUDICATION")"
scope_v="$(awk '/^scope:/ { sub(/^scope:[[:space:]]*/, ""); print; exit }' "$ADJUDICATION")"
model_v="$(awk '/^model:/ { sub(/^model:[[:space:]]*/, ""); print; exit }' "$ADJUDICATION")"
total_v="$(awk '/^findings_total:/ { sub(/^findings_total:[[:space:]]*/, ""); print; exit }' "$ADJUDICATION")"

phase_default="plan"

findings_table="$(awk '
  BEGIN {
    in_findings = 0
    in_finding = 0
    id = ""; sev = ""; stance = ""
    accepted = ""; rejected = ""; why_split = ""; why_correct = ""
  }
  /^findings:/ { in_findings = 1; next }
  /^[a-z_]+:/ && !/^[[:space:]]/ { if (in_findings) in_findings = 0 }
  in_findings && /^[[:space:]]*-[[:space:]]*id:/ {
    if (in_finding && id != "") emit_row()
    in_finding = 1
    id = $0; sub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/, "", id)
    sev = ""; stance = ""; accepted = ""; rejected = ""; why_split = ""; why_correct = ""
    next
  }
  in_findings && /^[[:space:]]+severity:/ {
    sev = $0; sub(/^[[:space:]]+severity:[[:space:]]*/, "", sev)
  }
  in_findings && /^[[:space:]]+stance:/ {
    stance = $0; sub(/^[[:space:]]+stance:[[:space:]]*/, "", stance)
  }
  in_findings && /^[[:space:]]+accepted:/ {
    accepted = $0; sub(/^[[:space:]]+accepted:[[:space:]]*/, "", accepted)
  }
  in_findings && /^[[:space:]]+rejected:/ {
    rejected = $0; sub(/^[[:space:]]+rejected:[[:space:]]*/, "", rejected)
  }
  in_findings && /^[[:space:]]+why_split:/ {
    why_split = $0; sub(/^[[:space:]]+why_split:[[:space:]]*/, "", why_split)
  }
  in_findings && /^[[:space:]]+why_correct:/ {
    why_correct = $0; sub(/^[[:space:]]+why_correct:[[:space:]]*/, "", why_correct)
  }
  END { if (in_finding && id != "") emit_row() }

  function emit_row() {
    reason = ""
    if (stance == "PARTIAL" && (accepted != "" || rejected != "" || why_split != "")) {
      reason = "What I am accepting: " accepted "<br>What I am rejecting: " rejected "<br>Why this split is correct: " why_split
    } else if (stance == "ACCEPT" && sev == "P0" && why_correct != "") {
      reason = "Why this is correct: " why_correct
    } else {
      reason = "<migrated from v1.5.x — fill in concrete reason>"
    }
    spec_change = "no"
    if (stance == "ACCEPT") spec_change = "yes"
    else if (stance == "PARTIAL") spec_change = "partial"
    printf "| %s | Codex | %s | <migrated; fill in 1-line concern> | %s | %s | %s |\n", id, sev, stance, reason, spec_change
  }
' "$ADJUDICATION")"

if [[ -z "$findings_table" ]]; then
  findings_table="| <NO FINDINGS FOUND IN INPUT — manual fill required> |  |  |  |  |  |  |"
fi

cat > "$OUT" <<EOF
# Concern Disposition Matrix
date: ${date_v:-<unknown>}
cycle_id: <fill in — not present in v1.5.x input>
findings_total: ${total_v:-0}
codex_model: ${model_v:-<unknown>}
review_phase: $phase_default

<!-- Migrated from $ADJUDICATION on $(date -u +%FT%TZ) by scripts/migrate-rebuttal-to-matrix.sh
     Original scope: ${scope_v:-<unknown>}
     Operator action required: fill in <migrated; ...> placeholders below. -->

## Cross-cutting observations

<add observations after migration — see template>

## Findings table

| ID | Source | Severity | Concern (1 line) | Disposition | Reason | Spec change |
|----|--------|----------|------------------|-------------|--------|-------------|
$findings_table

## Pass A divergences

<not applicable — v1.5.x cycles ran without Pass A>
EOF

echo "[migrate-rebuttal-to-matrix] Wrote $OUT"
echo "[migrate-rebuttal-to-matrix] Operator action required:"
echo "  1. Fill in the <migrated; ...> placeholders in the matrix"
echo "  2. Add cross-cutting observations (or write 'No cross-cutting patterns.')"
echo "  3. Set review_phase to 'plan' or 'diff' as appropriate"
echo "  4. Verify findings_total matches the row count"

# F12: prominent placeholder warning. The require-second-opinion.sh
# hook (extended in F12) denies any matrix that still contains
# <migrated;|<migrated from|<fill in placeholder text. Surface this
# loudly so the operator doesn't ship a "complete" matrix that's
# actually template-shaped.
if grep -qE '<migrated;|<migrated from|<fill in' "$OUT"; then
  cat >&2 <<WARN
[migrate-rebuttal-to-matrix] WARNING: $OUT contains unfilled placeholder text.
The require-second-opinion.sh hook will DENY edits while these placeholders
remain. To find them: grep -nE '<migrated;|<migrated from|<fill in' "$OUT"
WARN
  audit_migration "wrote matrix with placeholders (operator action required)"
else
  audit_migration "wrote matrix (no placeholders detected)"
fi
