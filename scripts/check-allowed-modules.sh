#!/usr/bin/env bash
# Verify go.mod requires only modules whose prefix appears in
# .claude/allowed-modules.txt. This is the deterministic supply-chain
# floor (slopsquatting defense). Used by CI.
set -euo pipefail

ALLOWLIST="${CLAUDE_PROJECT_DIR:-$(pwd)}/.claude/allowed-modules.txt"
if [ ! -f "$ALLOWLIST" ]; then
  echo "missing $ALLOWLIST"
  exit 1
fi

if [ ! -f go.mod ]; then
  echo "no go.mod found; skipping"
  exit 0
fi

# Use `go list -m all` if available (more reliable than parsing go.mod).
if command -v go >/dev/null 2>&1; then
  new_requires="$(go list -m all 2>/dev/null | tail -n +2 | awk '{print $1}' || true)"
fi

if [ -z "${new_requires:-}" ]; then
  # awk fallback: parse go.mod directly
  new_requires="$(awk '
    /^require[[:space:]]+\(/ { in_block=1; next }
    /^\)/ { in_block=0; next }
    in_block && NF >= 2 && $1 != "//" { print $1; next }
    /^require[[:space:]]+[^(]/ { print $2 }
  ' go.mod | grep -v '^$' || true)"
fi

if [ -z "$new_requires" ]; then
  echo "no requires found"
  exit 0
fi

violations=()
while IFS= read -r mod; do
  [ -z "$mod" ] && continue
  case "$mod" in '(' | ')') continue;; esac
  matched=0
  while IFS= read -r prefix; do
    [[ -z "$prefix" || "$prefix" =~ ^[[:space:]]*# ]] && continue
    if [[ "$mod" == "$prefix"* ]]; then
      matched=1
      break
    fi
  done < "$ALLOWLIST"
  [ "$matched" -eq 0 ] && violations+=("$mod")
done <<< "$new_requires"

if [ ${#violations[@]} -gt 0 ]; then
  echo "ERROR: Modules not on allowlist (slopsquatting risk):"
  printf '  %s\n' "${violations[@]}"
  echo
  echo "If these are legitimate new dependencies:"
  echo "  1. Verify each on https://pkg.go.dev (slopsquatting defense)."
  echo "  2. Get security-reviewer signoff."
  echo "  3. Add the prefix to $ALLOWLIST."
  echo "  4. Re-run."
  exit 1
fi

echo "All modules on allowlist."
