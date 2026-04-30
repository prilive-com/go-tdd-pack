#!/usr/bin/env bash
# Claude Code PreToolUse hook — denies edits to obvious secret-bearing files
# and routes migration edits to human approval.
#
# This is a path-only check. Content scanning is in scan-for-secrets.sh.

set -euo pipefail

INPUT="$(cat)"
FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')"

deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
}

case "$FILE_PATH" in
  migrations/*|*/migrations/*)
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "ask",
        permissionDecisionReason: "Migration edits are high-risk and require explicit approval. Use the migration-review skill to plan the change before editing."
      }
    }'
    ;;
  .env|.env.*|*/.env|*/.env.*|secrets/*|*/secrets/*|private/*|*/private/*|credentials/*|*/credentials/*|config/*credentials*.json|config/*secret*|*/id_rsa*|*/id_ed25519*|*.pem|*.key)
    deny "Protected secret-bearing file. Use an approved secret management flow instead."
    ;;
  *)
    jq -n '{}'
    ;;
esac
