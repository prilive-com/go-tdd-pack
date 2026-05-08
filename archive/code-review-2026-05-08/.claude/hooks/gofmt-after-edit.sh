#!/usr/bin/env bash
# Claude Code PostToolUse hook — Go-first formatter.
#
# Primary target: Go files. Runs gofmt + goimports silently. Never blocks
# an edit — formatter failure is logged and ignored.
#
# Secondary targets (silent no-op if formatter is absent):
#   .json, .yml, .yaml, .md  → prettier (if installed)
#   .sh, .bash               → shfmt (if installed)
#
# Most projects will only use the Go path.

set -uo pipefail

INPUT="$(cat)"
FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")"

[ -z "$FILE_PATH" ] && exit 0
[ ! -f "$FILE_PATH" ] && exit 0

try() {
  "$@" >/dev/null 2>&1 || true
}

case "$FILE_PATH" in
  *.go)
    command -v gofmt     >/dev/null 2>&1 && try gofmt -w "$FILE_PATH"
    command -v goimports >/dev/null 2>&1 && try goimports -w "$FILE_PATH"
    ;;

  *.json|*.yml|*.yaml|*.md)
    command -v prettier >/dev/null 2>&1 && try prettier --write --log-level=error "$FILE_PATH"
    ;;

  *.sh|*.bash)
    command -v shfmt >/dev/null 2>&1 && try shfmt -w "$FILE_PATH"
    ;;
esac

exit 0
