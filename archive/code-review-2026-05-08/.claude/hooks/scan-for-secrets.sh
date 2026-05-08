#!/usr/bin/env bash
# Claude Code PreToolUse hook — content-based secret scan on Write/Edit.
#
# This is the defense that path-based denials miss: Claude will happily write
# a secret into config.local.yaml or notes.md if only .env is denied by path.
# This hook inspects the ACTUAL CONTENT Claude is about to write and blocks
# the write if a secret is detected.
#
# Strategy:
#   1. Prefer gitleaks if installed — production-grade scanner with low FP rate.
#   2. Fall back to built-in regex patterns for common high-entropy tokens.
#      This is a backstop only; install gitleaks for real protection:
#        brew install gitleaks   |   go install github.com/gitleaks/gitleaks/v8@latest
#
# Requires: bash, jq. Reads tool-input JSON on stdin, emits a decision on stdout.
# Exit 0 in all cases; the decision goes in the JSON body.

set -euo pipefail

# Fail closed if jq is missing — this hook is a primary safety boundary.
if ! command -v jq >/dev/null 2>&1; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Required hook dependency 'jq' is missing; refusing to evaluate secret-scan policy. Install jq: apt-get install jq / brew install jq / apk add jq."}}
JSON
  exit 0
fi

INPUT="$(cat)"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')"
FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')"

# Extract content to scan. Two strategies:
#
# 1. Reconstruction (preferred for Edit / MultiEdit when python3 is available
#    and the target file exists): apply the replacement to the file's current
#    content and scan the result. Closes the "straddle" hole where a secret is
#    split between an existing line prefix (`apikey = "`) and a new edit value
#    (`sk_live_..."`); the snippet alone matches no pattern, but the result does.
#
# 2. Snippet-only fallback (Write tool, or python3 missing, or new file): scan
#    the joined `content` / `new_string` / `file_text` / `edits[].new_string`
#    snippets. This is what v1.0–1.1 did unconditionally.
#
# python3 is used because bash parameter expansion (`${var/pat/repl}`) treats
# `pat` as a glob, which is wrong for arbitrary user content. Python's
# str.replace handles arbitrary characters cleanly.

CONTENT=""

if command -v python3 >/dev/null 2>&1 \
   && [ -n "$FILE_PATH" ] && [ -f "$FILE_PATH" ] \
   && { [ "$TOOL" = "Edit" ] || [ "$TOOL" = "MultiEdit" ]; }; then
  CONTENT="$(printf '%s' "$INPUT" | python3 -c '
import sys, json
data = json.load(sys.stdin)
fp = data.get("tool_input", {}).get("file_path", "")
try:
    content = open(fp).read()
except OSError:
    sys.exit(0)
tool = data.get("tool_name", "")
ti = data.get("tool_input", {})
if tool == "Edit":
    old = ti.get("old_string", "")
    new = ti.get("new_string", "")
    if old:
        content = content.replace(old, new, 1)
elif tool == "MultiEdit":
    for edit in ti.get("edits", []) or []:
        old = edit.get("old_string", "")
        new = edit.get("new_string", "")
        if old:
            content = content.replace(old, new, 1)
sys.stdout.write(content)
' 2>/dev/null || true)"
fi

# Fallback or non-Edit tools: scan the snippets directly.
if [ -z "$CONTENT" ]; then
  CONTENT="$(printf '%s' "$INPUT" | jq -r '
    [
      (.tool_input.content // empty),
      (.tool_input.new_string // empty),
      (.tool_input.file_text // empty),
      (.tool_input.edits[]?.new_string // empty)
    ] | join("\n")
  ')"
fi

emit_decision() {
  jq -n --arg d "$1" --arg r "$2" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: $d,
      permissionDecisionReason: $r
    }
  }'
}

deny() { emit_decision "deny" "$1"; exit 0; }
pass() { jq -n '{}'; exit 0; }

# Nothing to scan — allow.
if [ -z "$CONTENT" ]; then
  pass
fi

# --- Preferred path: gitleaks (if installed) ---------------------------------
if command -v gitleaks >/dev/null 2>&1; then
  TMPF="$(mktemp)"
  trap 'rm -f "$TMPF"' EXIT
  printf '%s' "$CONTENT" > "$TMPF"

  # `gitleaks detect --no-git` scans the file path we just wrote.
  # Redact so the decision reason doesn't leak the secret into logs.
  if ! gitleaks detect --no-git --source "$TMPF" --no-banner --redact --report-format json --report-path /dev/null >/dev/null 2>&1; then
    deny "Refusing write to $FILE_PATH: gitleaks detected a secret in the proposed content. If this is a real credential, rotate it immediately. If it is a test fixture, use a clearly-fake placeholder like 'sk-test-EXAMPLE-DO-NOT-USE'."
  fi

  pass
fi

# --- Fallback: built-in regex backstop ---------------------------------------
# These are deliberately narrow to keep false-positive rate low. Real protection
# comes from gitleaks; this is insurance against agents writing the obvious stuff.
#
# Character-class note: inside POSIX extended regex [...] the hyphen must be
# placed FIRST or LAST to be literal. `[A-Za-z0-9\-_]` DOES NOT match a hyphen
# in most implementations; use `[A-Za-z0-9_-]` instead.

check_pattern() {
  local name="$1" regex="$2"
  if printf '%s' "$CONTENT" | grep -Eqi -- "$regex"; then
    deny "Refusing write to $FILE_PATH: content appears to contain $name. If real, rotate now. If a fixture, use an obvious placeholder. (gitleaks not installed; falling back to built-in scanner — install gitleaks for better coverage.)"
  fi
}

# AWS
check_pattern "an AWS access key"        'AKIA[0-9A-Z]{16}'
check_pattern "an AWS secret key"        'aws_secret_access_key[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9/+=]{40}'

# Private keys (PEM).
check_pattern "a private key (PEM)"      '-----BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY'

# Generic high-confidence API tokens.
check_pattern "a Stripe live key"        'sk_live_[0-9a-zA-Z]{24,}'
check_pattern "a GitHub token"           '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}'
check_pattern "a Slack token"            'xox[abprs]-[A-Za-z0-9-]{10,}'
check_pattern "a Google API key"         'AIza[0-9A-Za-z_-]{35}'
check_pattern "an Anthropic API key"     'sk-ant-[A-Za-z0-9_-]{40,}'
check_pattern "an OpenAI API key"        'sk-(proj-|svcacct-)?[A-Za-z0-9_-]{40,}'

# Cloud providers.
check_pattern "an Azure secret"          'AccountKey=[A-Za-z0-9+/=]{40,}'
check_pattern "a GCP service key"        '"type":[[:space:]]*"service_account"'

# Database connection strings with embedded credentials.
check_pattern "a Postgres DSN with password"  'postgres(ql)?://[^:[:space:]]+:[^@[:space:]]{6,}@'
check_pattern "a MySQL DSN with password"     'mysql://[^:[:space:]]+:[^@[:space:]]{6,}@'
check_pattern "a MongoDB DSN with password"   'mongodb(\+srv)?://[^:[:space:]]+:[^@[:space:]]{6,}@'

# Generic — only trigger on an assignment with a plausible secret shape.
check_pattern "an inline bearer token"   'Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9_.-]{20,}'
check_pattern "a password assignment"    '(^|[[:space:]])(password|passwd|pwd)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"'[:space:]$]{8,}["'"'"']'

pass
