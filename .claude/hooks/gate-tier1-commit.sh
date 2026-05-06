#!/usr/bin/env bash
# PreToolUse hook on Bash. Gates `git commit`, `git tag`, and `git push`
# for Tier 1 cycles.
#
# Created 2026-05-05 as part of the four-gate redesign — see
# docs/specs/tdd-gate-conflict-resolution-spec.md.
#
# Why this hook exists:
#   The edit-time hook (require-tdd-state.sh) only checks the FIRST three
#   markers (spec, red, green-authorized). It cannot enforce that the
#   operator reviewed the implementation AFTER it was written, because
#   at edit time there's no implementation to review yet.
#
#   This hook closes that loop. At commit time, for any commit that
#   touches Tier 1 production paths (per .tdd/tdd-config.json), it
#   requires:
#     - Marker M4 "Implementation reviewed: yes" set on the plan
#     - .tdd/green-proof.md exists (proof that tests went green)
#     - .tdd/second-opinion-completed.md is fresh (mtime <60min)
#
#   "red(<id>):" commits are exempt (they ARE the red phase commit).
#   "refactor(<id>):" commits require M4 (refactor is post-green).
#
# Failure mode: deny via JSON + stderr + exit 2 (defense in depth, same
# as require-second-opinion.sh).
#
# Killswitch: TDD_COMMIT_GATE_DISABLE=1 env var.

set -euo pipefail

PAYLOAD="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  exit 0  # No jq → no gating. Fail open here only because secret-scanner
          # and require-tdd-state already fail closed on jq, so the user
          # has been told.
fi

# Killswitch.
if [[ "${TDD_COMMIT_GATE_DISABLE:-0}" == "1" ]]; then
  exit 0
fi

ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PLAN="$ROOT/.tdd/current-plan.md"
CONFIG="$ROOT/.tdd/tdd-config.json"
GREEN_PROOF="$ROOT/.tdd/green-proof.md"
ADJUDICATION="$ROOT/.tdd/second-opinion-completed.md"
AUDIT_LOG="$ROOT/.tdd/tdd-commit-gate.log"
mkdir -p "$ROOT/.tdd" 2>/dev/null

# No config means TDD ceremony not configured — allow.
[[ ! -f "$CONFIG" ]] && exit 0
# No plan means no active Tier 1 cycle — allow.
[[ ! -f "$PLAN" ]] && exit 0

CMD="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[[ -z "$CMD" ]] && exit 0

# Match git commit / tag / push at command start (allow leading whitespace).
# The anchor avoids matching command bodies that mention "git commit" in
# comments or quoted strings.
COMMITS_RE='(^|;|&&|\|\|)[[:space:]]*git[[:space:]]+(commit|tag|push)([[:space:]]|$)'
if ! printf '%s' "$CMD" | grep -qE "$COMMITS_RE"; then
  exit 0
fi

# Identify the staged Tier 1 production files (if we're inside a git repo).
# `git diff --cached --name-only` gives the staged set; if there are none
# (e.g., commit -a), fall back to `git diff --name-only` plus untracked.
cd "$ROOT" 2>/dev/null || exit 0
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  exit 0
fi

CHANGED_FILES="$(git diff --cached --name-only 2>/dev/null)"
if [[ -z "$CHANGED_FILES" ]]; then
  # commit -a / commit -am / nothing staged: fall back to working tree changes
  CHANGED_FILES="$(git diff --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)"
fi
[[ -z "$CHANGED_FILES" ]] && exit 0

TIER1_REGEXES="$(jq -r '.tier1_path_regexes[]? // empty' "$CONFIG")"
TIER1_PROD=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    *_test.go) continue ;;  # tests don't trigger the commit gate
    */.tdd/*|*/.claude/*|*.md|*/docs/*|*/specs/*|*/archive/*|*/CHANGELOG.md) continue ;;
  esac
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    if printf '%s' "$f" | grep -qE "$pattern"; then
      TIER1_PROD+=("$f")
      break
    fi
  done <<< "$TIER1_REGEXES"
done <<< "$CHANGED_FILES"

# Nothing Tier-1 staged → allow.
[[ ${#TIER1_PROD[@]} -eq 0 ]] && exit 0

# Detect commit-message subject for red()/refactor()/green()/etc. classification.
# The operator may pass -m "subject" inline or use a prepared message file.
# We extract the -m value with a portable awk; if no -m, we don't know the
# subject and assume green() semantics (most cautious).
SUBJECT="$(printf '%s\n' "$CMD" | awk '
  {
    n = split($0, parts, " ")
    for (i = 1; i <= n; i++) {
      if (parts[i] == "-m" || parts[i] == "--message") {
        # Reconstruct quoted subject from following parts.
        msg = ""
        for (j = i+1; j <= n; j++) {
          if (msg == "") msg = parts[j]; else msg = msg " " parts[j]
        }
        # Strip leading/trailing single or double quotes.
        gsub(/^["\x27]+|["\x27]+$/, "", msg)
        print msg
        exit
      }
    }
  }
')"

# Helpers.
audit() {
  local decision="$1" reason="$2"
  local ts; ts="$(date -u +%FT%TZ)"
  printf '%s decision=%s reason=%s files=%d cmd=%q\n' \
    "$ts" "$decision" "$reason" "${#TIER1_PROD[@]}" "$CMD" \
    >> "$AUDIT_LOG" 2>/dev/null || true
}

deny() {
  local reason="$1" detail="$2"
  audit "deny" "$reason"
  cat <<JSON
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"$detail"}}
JSON
  cat >&2 <<DIRECTIVE
[gate-tier1-commit] BLOCKED: $reason

<claude-directive>
This is an AUTOMATED COMMIT GATE for Tier 1 cycles. The commit touches
production code in Tier 1 paths and the cycle is missing the post-impl
review evidence.

Staged Tier 1 production files:
$(printf '  - %s\n' "${TIER1_PROD[@]}")

You MUST do one of:
  1. Run /second-opinion diff on the staged Tier 1 diff to produce a
     fresh .tdd/second-opinion-completed.md adjudication.
  2. Capture .tdd/green-proof.md showing the tests now pass for the
     scoped change.
  3. Ask the operator: "APPROVED IMPLEMENTATION for <cycle-id>?"
     The operator's APPROVED IMPLEMENTATION is gate 3. Set
     "Implementation reviewed: yes" in .tdd/current-plan.md ONLY after
     that explicit reply. NEVER self-approve.

Then re-run the commit. Do NOT try to bypass the hook by editing the
plan markers without the operator's APPROVED IMPLEMENTATION reply.

Killswitch (emergency only, document in commit message):
  TDD_COMMIT_GATE_DISABLE=1 git commit ...
</claude-directive>
DIRECTIVE
  exit 2
}

# Classify subject. red() commits are exempt (they're the red-phase commit).
# Anything else (green, refactor, etc.) needs M4.
case "$SUBJECT" in
  red\(*|red:*)
    audit "allow" "red_commit_exempt"
    exit 0
    ;;
esac

# Require M4 marker (with backwards-compat alias if any future renaming).
M4="Implementation reviewed: yes"
if ! grep -qF "$M4" "$PLAN"; then
  deny "missing marker '$M4'" \
    "Tier 1 commit blocked: .tdd/current-plan.md is missing 'Implementation reviewed: yes'. Operator must say APPROVED IMPLEMENTATION at gate 3 before this marker can be set. See docs/specs/tdd-gate-conflict-resolution-spec.md."
fi

# Require green-proof artifact.
if [[ ! -f "$GREEN_PROOF" ]]; then
  deny "missing .tdd/green-proof.md" \
    "Tier 1 commit blocked: .tdd/green-proof.md does not exist. Capture verbatim test-passing output (the green proof) before committing the green phase."
fi

# Require fresh second-opinion adjudication (<60min mtime).
if [[ ! -f "$ADJUDICATION" ]]; then
  deny "missing .tdd/second-opinion-completed.md" \
    "Tier 1 commit blocked: .tdd/second-opinion-completed.md does not exist. Run /second-opinion diff on the staged Tier 1 diff to produce the adjudication artifact."
fi
if [[ -z "$(find "$ADJUDICATION" -mmin -60 -print 2>/dev/null)" ]]; then
  deny "stale .tdd/second-opinion-completed.md (mtime > 60min)" \
    "Tier 1 commit blocked: .tdd/second-opinion-completed.md is older than 60 minutes. Re-run /second-opinion diff on the current staged diff."
fi

audit "allow" "all_gates_satisfied"
exit 0
