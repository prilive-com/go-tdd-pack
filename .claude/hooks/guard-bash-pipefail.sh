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
  #
  # F7 fix (cycle f7-pipefail-substring-bypass): the prior regex had
  # bypass classes — bare `pipefail` substring (matched anywhere),
  # loose `set -o <opt>` (didn't verify pipefail follows), and the
  # initial F7 fix was still too loose: `printf -o pipefail`, `grep -o
  # pipefail`, etc. would silence the gate because `-o pipefail` appears
  # in an unrelated tool's argv (Codex round 1 P1).
  #
  # New regex: require `set` or `bash` IMMEDIATELY before the cluster
  # (with optional intervening short flags like -e, -u). Covers:
  #   set -o pipefail            set + -o pipefail
  #   set -eo pipefail           set + -eo pipefail (cluster)
  #   set -e -o pipefail         set + -e + -o pipefail
  #   set -e -u -o pipefail      set + -e + -u + -o pipefail
  #   bash -o pipefail -c '...'  bash + -o pipefail
  #   bash -l -o pipefail -c     bash + -l + -o pipefail
  # Rejects:
  #   bare `pipefail` substring
  #   `set -o errexit` (no pipefail after cluster)
  #   `printf -o pipefail` / `grep -o pipefail` (not set/bash)
  #   `--with-pipefail` long flag
  #
  # KNOWN LIMIT (out of scope for F7): substring match against quote
  # boundaries means `echo "set -o pipefail before running tests"` would
  # silence the gate because the literal text inside the quoted echo arg
  # matches the regex. The anchor includes `"` and `'` so legitimate
  # `bash -c "set -o pipefail; ..."` works, which means quoted text
  # in OTHER commands can also match. This is the same architectural
  # class as the gate-level cycle (no shell-aware tokenisation here).
  # Documented; follow-up cycle if needed. Threat model: contrived
  # bypass; Claude doesn't typically craft such echo strings.
  if echo "$cmd" | grep -q '|' \
     && ! echo "$cmd" | grep -qE '(^|[[:space:];&|()"'"'"'])(set|bash)([[:space:]]+-[a-zA-Z]+)*[[:space:]]+-[a-zA-Z]*o[a-zA-Z]*[[:space:]]+pipefail([[:space:]]|;|&|$)'; then
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
