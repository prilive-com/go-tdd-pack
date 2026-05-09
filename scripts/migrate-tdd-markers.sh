#!/usr/bin/env bash
# Migrate a .tdd/current-plan.md from the 3-marker format (pre-2026-05-05) to
# the 4-marker format. Idempotent: running on an already-migrated plan is a
# no-op (with a friendly note). Backs up the original to .tdd/current-plan.md.bak.
#
# Usage:
#   scripts/migrate-tdd-markers.sh [path-to-plan]
#   scripts/migrate-tdd-markers.sh             # default: .tdd/current-plan.md
#
# What it changes:
#   - Renames "Human approved implementation: <yes|no>" → "Green phase authorized: <yes|no>"
#   - Adds "Implementation reviewed: no" line if missing
#
# Why: see docs/specs/tdd-gate-conflict-resolution-spec.md. The old marker
# name "Human approved implementation" was misleading — the marker was actually
# the operator's pre-authorization for green phase, not a post-impl review.
# Renaming makes the audit trail honest. Adding M4 introduces the missing
# post-impl review gate.

set -euo pipefail

PLAN="${1:-.tdd/current-plan.md}"

if [[ ! -f "$PLAN" ]]; then
  echo "[migrate-tdd-markers] No plan at $PLAN — nothing to migrate." >&2
  exit 0
fi

# F12: structured audit-log helper. Migrations mutate audit-trail
# content; without a log, there's no written record that the destructive
# operation ran. Append-only; never blocks the migration.
audit_migration() {
  local summary="$1"
  local log_dir log_file
  log_dir="$(dirname "$PLAN")"
  log_file="$log_dir/migration-audit.log"
  # Codex round 1 P2: append `|| true` to mkdir AND printf so the
  # helper truly never blocks under set -e (e.g., readonly fs).
  mkdir -p "$log_dir" 2>/dev/null || true
  printf '%s script=migrate-tdd-markers input=%s summary=%q\n' \
    "$(date -u +%FT%TZ)" "$PLAN" "$summary" \
    >> "$log_file" 2>/dev/null || true
}

# Detect already-migrated state.
already_has_m3_new=false
already_has_m4=false
grep -qE '^Green phase authorized: ' "$PLAN" && already_has_m3_new=true
grep -qE '^Implementation reviewed: '   "$PLAN" && already_has_m4=true

if $already_has_m3_new && $already_has_m4; then
  echo "[migrate-tdd-markers] $PLAN already uses the 4-marker format. No changes."
  audit_migration "no-op (already migrated)"
  exit 0
fi

# Backup before mutating.
cp -p "$PLAN" "${PLAN}.bak"
echo "[migrate-tdd-markers] Backup written to ${PLAN}.bak"

# Step 1: rename old M3 → new M3 in place. Match yes/no values; preserve case.
if grep -qE '^Human approved implementation: ' "$PLAN"; then
  # Use a portable sed (works with both GNU and BSD sed because we don't use -i with extension).
  tmp="$(mktemp)"
  sed 's/^Human approved implementation: /Green phase authorized: /' "$PLAN" > "$tmp"
  mv "$tmp" "$PLAN"
  echo "[migrate-tdd-markers] Renamed 'Human approved implementation' → 'Green phase authorized' in $PLAN"
fi

# Step 2: insert M4 line after the M3 line if missing.
if ! grep -qE '^Implementation reviewed: ' "$PLAN"; then
  if grep -qE '^Green phase authorized: ' "$PLAN"; then
    tmp="$(mktemp)"
    awk '
      /^Green phase authorized: / {
        print
        print "Implementation reviewed: no"
        next
      }
      { print }
    ' "$PLAN" > "$tmp"
    mv "$tmp" "$PLAN"
    echo "[migrate-tdd-markers] Inserted 'Implementation reviewed: no' after the M3 line."
  else
    # No M3 anywhere — append M4 at end. Edge case: very old or partial plan.
    printf '\nImplementation reviewed: no\n' >> "$PLAN"
    echo "[migrate-tdd-markers] Appended 'Implementation reviewed: no' (no M3 found to anchor on)."
  fi
fi

echo "[migrate-tdd-markers] Migration complete for $PLAN."
echo "[migrate-tdd-markers] Review the diff:"
echo "    diff -u ${PLAN}.bak $PLAN"

audit_migration "renamed M3 + inserted M4"
