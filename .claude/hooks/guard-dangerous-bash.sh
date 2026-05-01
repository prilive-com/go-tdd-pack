#!/usr/bin/env bash
# Claude Code PreToolUse hook — deterministic guard for dangerous Bash commands.
#
# This hook is the structural defense against patterns that documented incidents
# prove Claude will otherwise attempt:
#   - issue #40117: --no-verify bypass of pre-commit (6 consecutive commits)
#   - issue #29691: obfuscation of forbidden terms to evade text-based rules
#   - DataTalks.Club (Feb 2026): `terraform destroy` on production state
#   - issue #45893: unauthorized git pushes deleting files
#
# Text instructions in CLAUDE.md are advisory. This script is enforcement.
#
# Requires: bash, jq. Reads the tool-input JSON on stdin and emits a decision
# JSON on stdout. Exit 0 in all cases — the decision goes in the JSON body.

set -euo pipefail

# Fail closed if jq is missing — this hook is a primary safety boundary.
if ! command -v jq >/dev/null 2>&1; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Required hook dependency 'jq' is missing; refusing to evaluate dangerous-bash safety policy. Install jq: apt-get install jq / brew install jq / apk add jq."}}
JSON
  exit 0
fi

INPUT="$(cat)"
COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')"

emit_decision() {
  local decision="$1"
  local reason="$2"
  jq -n --arg d "$decision" --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: $d,
      permissionDecisionReason: $r
    }
  }'
}

deny() { emit_decision "deny" "$1"; exit 0; }
ask()  { emit_decision "ask"  "$1"; exit 0; }
pass() { jq -n '{}'; exit 0; }

# -----------------------------------------------------------------------------
# HARD DENY — patterns that must never execute, even with human approval.
# These reflect real incidents, not theoretical risk.
# -----------------------------------------------------------------------------

# Pre-commit bypass (issue #40117 — Claude Code 27 Mar 2026, 6 bypassed commits).
if echo "$COMMAND" | grep -Eq '(^|[[:space:]])--no-verify([[:space:]]|$)'; then
  deny "Refusing: --no-verify bypasses pre-commit hooks. Fix the underlying hook failure instead. (See issue #40117.)"
fi
# Short form of --no-verify: `git commit -n` (same bypass class).
if echo "$COMMAND" | grep -Eq 'git[[:space:]]+(.*[[:space:]])?commit([[:space:]].*)?[[:space:]]-n([[:space:]]|$)'; then
  deny "Refusing: 'git commit -n' is the short form of --no-verify (pre-commit bypass). Fix the failing hook instead."
fi
# Git config bypass that disables hooks at the command level.
if echo "$COMMAND" | grep -Eq 'git[[:space:]]+(.*[[:space:]])?-c[[:space:]]+core\.hooksPath'; then
  deny "Refusing: 'git -c core.hooksPath' disables the project's git hooks. Use the configured hooks; if they're failing, fix them."
fi
if echo "$COMMAND" | grep -Eq '(^|[[:space:]])(HUSKY=0|GIT_HOOKS=0)(=| )'; then
  deny "Refusing: hook-bypass environment variable. Pre-commit hooks exist to catch real failures."
fi
if echo "$COMMAND" | grep -Eq '^[[:space:]]*SKIP=.*git[[:space:]]+commit'; then
  deny "Refusing: pre-commit SKIP= bypass. Fix the failing hook instead of suppressing it."
fi

# History-rewriting and forced pushes (issue #45893 — unauthorized push + file deletion).
if echo "$COMMAND" | grep -Eq 'git[[:space:]]+filter-(repo|branch)'; then
  deny "Refusing: git filter-repo/filter-branch rewrites history. Requires explicit human execution."
fi
if echo "$COMMAND" | grep -Eq 'git[[:space:]]+push[[:space:]].*(-f([[:space:]]|$)|--force([[:space:]]|$))'; then
  if echo "$COMMAND" | grep -Eq -- '--force-with-lease'; then
    ask "git push --force-with-lease is safer than --force but still risky. Confirm branch and remote."
  else
    deny "Refusing: git push --force/-f can erase teammates' work. Use --force-with-lease if you must, or a fresh branch."
  fi
fi
if echo "$COMMAND" | grep -Eq 'git[[:space:]]+reset[[:space:]]+--hard[[:space:]]+origin/'; then
  deny "Refusing: git reset --hard origin/* discards local work irrecoverably. Stash or branch first."
fi

# Infrastructure destruction (DataTalks.Club incident, Feb 2026).
if echo "$COMMAND" | grep -Eq 'terraform[[:space:]]+destroy'; then
  deny "Refusing: terraform destroy. Infrastructure teardown requires explicit human execution, not agent approval."
fi
if echo "$COMMAND" | grep -Eq 'terraform[[:space:]]+apply.*-auto-approve'; then
  deny "Refusing: terraform apply -auto-approve skips plan review. Run 'terraform plan' first and review the diff."
fi

# Destructive filesystem operations.
if echo "$COMMAND" | grep -Eq '(^|[[:space:]])rm[[:space:]]+-[rRfF]+[[:space:]]+(/([[:space:]]|$)|/\*|~|~/|\$HOME|\$\{HOME\})'; then
  deny "Refusing: rm -rf against /, ~, or \$HOME. Recovery is not possible."
fi

# Piped-to-shell remote execution (supply chain). Allow optional `sudo` between
# the pipe and the shell — the sudo variant is a known bypass class.
if echo "$COMMAND" | grep -Eq '(curl|wget)[[:space:]][^|]*\|[[:space:]]*(sudo[[:space:]]+)?(sh|bash|zsh)([[:space:]]|$)'; then
  deny "Refusing: piping remote content to a shell. Download, inspect, then run explicitly."
fi

# Destructive DB statements and data-loss flags.
if echo "$COMMAND" | grep -Eq -- '(--accept-data-loss)'; then
  deny "Refusing: --accept-data-loss flags are used only in explicit disaster-recovery workflows."
fi
if echo "$COMMAND" | grep -Eq 'psql[[:space:]].*(production|prod-|prd-|-h[[:space:]]*prod)'; then
  deny "Refusing: direct psql against production. Use a read replica or operator runbook."
fi
if echo "$COMMAND" | grep -Eq '(DROP[[:space:]]+TABLE|TRUNCATE[[:space:]]+TABLE|DROP[[:space:]]+DATABASE)' \
   && echo "$COMMAND" | grep -Eq '(production|prod-|prd-)'; then
  deny "Refusing: DROP/TRUNCATE against production-looking target."
fi

# Privilege escalation.
if echo "$COMMAND" | grep -Eq '^[[:space:]]*sudo([[:space:]]|$)'; then
  deny "Refusing: sudo. Run privileged commands in a deliberate human-executed step."
fi
if echo "$COMMAND" | grep -Eq 'chmod[[:space:]]+777'; then
  deny "Refusing: chmod 777 grants world-write. If you need looser perms, use 644/755 or change ownership."
fi

# -----------------------------------------------------------------------------
# ASK — risky but legitimate in context. Route to human.
# -----------------------------------------------------------------------------

if echo "$COMMAND" | grep -Eq '^[[:space:]]*git[[:space:]]+push([[:space:]]|$)'; then
  ask "git push to a remote. Confirm branch, remote, and whether this should be force-with-lease."
fi
if echo "$COMMAND" | grep -Eq '^[[:space:]]*git[[:space:]]+tag([[:space:]]|$)'; then
  ask "git tag modifies history. Confirm this is an intended release tag."
fi
if echo "$COMMAND" | grep -Eq 'docker[[:space:]]+push'; then
  ask "docker push publishes an image. Confirm registry and tag."
fi
if echo "$COMMAND" | grep -Eq '^[[:space:]]*kubectl([[:space:]]|$)'; then
  ask "kubectl changes cluster state. Confirm context is not production."
fi
if echo "$COMMAND" | grep -Eq 'terraform[[:space:]]+apply'; then
  ask "terraform apply. Confirm the plan has been reviewed and the workspace is correct."
fi
if echo "$COMMAND" | grep -Eq 'helm[[:space:]]+(upgrade|install)'; then
  ask "helm upgrade/install changes cluster state. Confirm chart version and namespace."
fi

# Default: allow. Claude Code's own permissions.allow list still applies on top.
pass
