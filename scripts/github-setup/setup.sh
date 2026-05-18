#!/usr/bin/env bash
# setup.sh — Orchestrate the full setup in the right order.
#
# Usage:
#   ./setup.sh                       # full setup (creates new private repo)
#   ./setup.sh --skip-create         # skip 01 (repo already exists)
#   ./setup.sh --org                 # also run 08 (org-level baseline)
#   ./setup.sh --dry-run             # print what would run, don't execute
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SKIP_CREATE="false"
APPLY_ORG="false"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-create) SKIP_CREATE="true"; shift ;;
    --org)         APPLY_ORG="true"; shift ;;
    --dry-run)     DRY_RUN="true"; shift ;;
    -h|--help)
      # Print the header comment block (lines 2-9), skipping the shebang.
      sed -n '2,9p' "$0"
      exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

run_step() {
  local step="$1"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] would run: $step"
  else
    "./$step"
  fi
}

echo "Prilive GitHub setup orchestrator"
echo "Config: $SCRIPT_DIR/repo-config.env"
echo "Mode: $([ "$DRY_RUN" == "true" ] && echo "dry-run" || echo "live")"
echo

# Verify token early
if [[ -z "${GH_BASELINE_TOKEN:-}" ]]; then
  echo "ERROR: GH_BASELINE_TOKEN environment variable is not set." >&2
  echo "See RUNBOOK.md §3 for how to create a fine-grained PAT." >&2
  exit 1
fi

# Phase 1: Create + initial settings (private)
if [[ "$SKIP_CREATE" == "false" ]]; then
  run_step "01-create-private.sh"
fi
run_step "02-set-metadata.sh"
run_step "03-enable-security.sh"

# Phase 2: Branch + tag protection (requires default branch to exist)
echo
echo "==> Phase 2 requires the default branch to exist."
echo "    If you have not pushed any code yet, do this now:"
echo "      git remote add origin git@github.com:${ORG:-prilive-com}/${REPO_NAME:-go-tdd-pack}.git"
echo "      git branch -M main"
echo "      git push -u origin main"
echo
read -r -p "Press Enter when ready to continue, or Ctrl+C to stop: "

run_step "04-protect-main.sh"
run_step "05-protect-tags.sh"
run_step "06-set-actions-permissions.sh"
run_step "07-enable-codeql.sh"

if [[ "$APPLY_ORG" == "true" ]]; then
  run_step "08-apply-org-baseline.sh"
fi

echo
echo "==> Setup complete (excluding public flip)."
echo
echo "Next steps:"
echo "  1. Verify with: ./audit.sh"
echo "  2. When repo is ready for public release: ./99-make-public.sh"
echo
echo "Audit log: $(ls -t logs/github-setup-*.jsonl | head -1)"
