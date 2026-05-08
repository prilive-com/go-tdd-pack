#!/usr/bin/env bash
# .claude/hooks/guard-bash-pipefail.sh
# PreToolUse on Bash.
#
# Catches the silent-failure pattern where a Go verification command is
# piped through another command (head, tail, tee, grep, etc.) without
# `set -o pipefail`. Without pipefail, the exit code of the upstream
# command (e.g. `go build`) is masked by the exit code of the downstream
# command (e.g. `head`, which is almost always 0). Real build failures
# look like successes.
#
# Real failure example seen in production:
#   go build ./... 2>&1 | head -10 && echo "exit: $?"  →  reports exit 0
#   despite the build failing, because head -10 exited 0.

set -uo pipefail

# Pass through if jq is missing (we cannot parse the tool input).
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

stdin="$(cat)"
cmd="$(jq -r '.tool_input.command // empty' <<<"$stdin" 2>/dev/null || echo '')"

# Only inspect commands that involve a Go verification tool.
if echo "$cmd" | grep -qE '(^|[[:space:]]|;|&|\|)(go|gofmt|goimports|golangci-lint|staticcheck|govulncheck|deadcode|unparam)[[:space:]]+(build|test|vet|run|mod|tidy|install|version|env)'; then
  # Inspect: is there a pipe AND no pipefail set?
  if echo "$cmd" | grep -q '|' \
     && ! echo "$cmd" | grep -qE 'set[[:space:]]+-o[[:space:]]+pipefail|set[[:space:]]+-[a-zA-Z]*o[a-zA-Z]*[[:space:]]|pipefail|bash[[:space:]]+-o[[:space:]]+pipefail'; then
    cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Verification command pipes Go output through another command without 'set -o pipefail'. The exit code of the Go tool is masked by the downstream command (e.g. 'head' returns 0 even when 'go build' failed). Real build failures look like successes. Wrap in: bash -c 'set -o pipefail; <command> 2>&1 | head -20'"}}
JSON
    cat >&2 <<'DIRECTIVE'
[guard-bash-pipefail] BLOCKED: piped go command without pipefail.

<claude-directive>
This is an AUTOMATED CHECK. Your command pipes the output of a Go tool
(go build / go test / go vet / golangci-lint / etc.) through another
command. Without `set -o pipefail`, the exit code of the Go tool is
silently replaced by the exit code of the LAST command in the pipe
(typically 0 for `head`, `tail`, `tee`). Real build failures appear
to succeed.

Fix it by wrapping in a bash -c with pipefail:
  bash -c 'set -o pipefail; go build ./... 2>&1 | head -20'

Or run without piping at all:
  go build ./...

Or save to a file and inspect that:
  go build ./... > /tmp/build.log 2>&1; head -20 /tmp/build.log
</claude-directive>
DIRECTIVE
    exit 2
  fi
fi

exit 0
