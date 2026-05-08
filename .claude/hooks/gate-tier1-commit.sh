#!/usr/bin/env bash
# PreToolUse hook on Bash. Gates `git commit` for Tier 1 cycles, in two
# independent layers (commit-only — see "Why commit-only" below):
#
#   1. INTEGRATION GUARDS (project-wide invariants from
#      .tdd/tdd-config.json `integration_guards`). Always fire when guards
#      are defined, regardless of TDD cycle state. Encode invariants like
#      "no direct calls to API X outside wrapper Y", catch project-wide
#      regressions a grep can find that plan-review can't.
#
#   2. TDD CEREMONY CHECKS (M4 marker, green-proof, fresh adjudication).
#      Fire only when an active cycle exists (`.tdd/current-plan.md`
#      present) AND the staged change touches Tier 1 production paths.
#      Enforce the post-implementation review for high-stakes work.
#
# Why commit-only (D-SO-05, 2026-05-08): this hook's gating logic
# inspects `git diff --cached` (staged files) to decide whether Tier 1
# production is in play. That signal is meaningful for `git commit`
# but not for `git push` (which operates on already-committed history,
# not on staging) or `git tag` (which references a commit, not staging).
# An earlier version of this script matched all three operations in
# its regex, but the gating logic only ever made sense for commit. The
# header and the regex now agree — commit-only.
#
# If you want to gate push or tag, that is a separate hook concern: the
# right signal there is the range of unpushed commits or the commit
# being tagged, not staged-files state. That is out of scope for this
# hook; track as a follow-up if needed.
#
# Layer split rationale: integration guards are project-wide — they apply
# to ANY commit that violates them. TDD ceremony checks are cycle-specific —
# they only make sense for active Tier 1 work. The original v1.6.0 design
# conflated the two; a real-trial finding (pack-self dogfooding) showed
# that guards were dormant on commits that didn't happen to stage Tier 1
# files. This split fixes that.
#
# Created 2026-05-05 (TDD gate redesign);
# integration guards added 2026-05-07 (parasitoid trial feedback);
# layer split done 2026-05-08 (pack-self dogfooding).
#
# Failure mode: deny via JSON + stderr + exit 2 (defense in depth).
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

# No config means TDD ceremony not configured AND no project-wide guards
# defined — allow.
[[ ! -f "$CONFIG" ]] && exit 0

CMD="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[[ -z "$CMD" ]] && exit 0

# Match git commit at command start (allow leading whitespace).
# The anchor avoids matching command bodies that mention "git commit" in
# comments or quoted strings.
#
# D-SO-05 (2026-05-08): regex previously matched (commit|tag|push). The
# gating logic only inspects staged files — meaningful for commit, not
# for push or tag. Aligning the regex with what the script actually
# does. Header doc was updated in the same commit.
COMMITS_RE='(^|;|&&|\|\|)[[:space:]]*git[[:space:]]+commit([[:space:]]|$)'
if ! printf '%s' "$CMD" | grep -qE "$COMMITS_RE"; then
  exit 0
fi

cd "$ROOT" 2>/dev/null || exit 0
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  exit 0
fi

CHANGED_FILES="$(git diff --cached --name-only 2>/dev/null)"
if [[ -z "$CHANGED_FILES" ]]; then
  CHANGED_FILES="$(git diff --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)"
fi
[[ -z "$CHANGED_FILES" ]] && exit 0

TIER1_REGEXES="$(jq -r '.tier1_path_regexes[]? // empty' "$CONFIG")"
TIER1_PROD=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    *_test.go) continue ;;
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

# ---- Helpers (used by both integration-guards and ceremony layers) -------

audit() {
  local decision="$1" reason="$2"
  local count="${#TIER1_PROD[@]}"
  local ts; ts="$(date -u +%FT%TZ)"
  printf '%s decision=%s reason=%s files=%d cmd=%q\n' \
    "$ts" "$decision" "$reason" "$count" "$CMD" \
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

# glob_to_regex: convert a shell glob (with ** for cross-directory) to an
# anchored regex. Treats `**/` as ZERO-OR-MORE path segments.
glob_to_regex() {
  local g="$1"
  g="${g//\\/\\\\}"
  g="${g//./\\.}"
  g="${g//+/\\+}"
  g="${g//\?/\\?}"
  g="${g//\(/\\(}"
  g="${g//\)/\\)}"
  g="${g//\[/\\[}"
  g="${g//\]/\\]}"
  g="${g//\^/\\^}"
  g="${g//\$/\\\$}"
  g="${g//\*\*\//__DSS__}"
  g="${g//\*\*/__DS__}"
  g="${g//\*/[^/]*}"
  g="${g//__DSS__/(.*/)?}"
  g="${g//__DS__/.*}"
  printf '^%s$\n' "$g"
}

# ---- LAYER 1: Integration guards (project-wide, always fire) -------------
#
# Fires on every commit when integration_guards is non-empty. Decoupled
# from TDD cycle state — guards are project-wide invariants, not
# ceremony-gated checks.
#
# Excluded dirs are configurable via integration_guards_exclude_dirs in
# tdd-config.json. Default: .git, vendor, node_modules, .tdd, .claude
# (which makes sense for downstream Go projects where .claude/.tdd contain
# the installed pack — you don't want to grep your installed starter for
# violations of YOUR project's invariants). The pack itself sets these to
# the empty subset so guards CAN scan its own production files.

GUARD_COUNT="$(jq -r '(.integration_guards // []) | length' "$CONFIG" 2>/dev/null || echo 0)"

if [[ "${GUARD_COUNT:-0}" -gt 0 ]]; then
  # Build the exclude-dir flags from config (or default).
  EXCLUDE_DIRS_FLAGS=()
  EXCLUDE_DIRS_RAW="$(jq -r '
    if (.integration_guards_exclude_dirs | type) == "array"
    then .integration_guards_exclude_dirs[]?
    else "" end
  ' "$CONFIG" 2>/dev/null)"
  if [[ -z "$EXCLUDE_DIRS_RAW" ]]; then
    # Default exclusions for downstream consumers.
    EXCLUDE_DIRS_FLAGS=(--exclude-dir='.git' --exclude-dir='vendor' --exclude-dir='node_modules' --exclude-dir='.tdd' --exclude-dir='.claude')
  else
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      EXCLUDE_DIRS_FLAGS+=(--exclude-dir="$d")
    done <<< "$EXCLUDE_DIRS_RAW"
  fi

  GUARD_VIOLATIONS_DENY=()
  GUARD_VIOLATIONS_WARN=()

  while IFS= read -r guard_json; do
    [[ -z "$guard_json" ]] && continue
    name="$(jq -r '.name // "unnamed"' <<<"$guard_json")"
    pattern="$(jq -r '.pattern // empty' <<<"$guard_json")"
    severity="$(jq -r '.severity // "deny"' <<<"$guard_json")"
    rationale="$(jq -r '.rationale // ""' <<<"$guard_json")"
    [[ -z "$pattern" ]] && continue

    allowed_regexes=()
    while IFS= read -r g; do
      [[ -z "$g" ]] && continue
      allowed_regexes+=("$(glob_to_regex "$g")")
    done < <(jq -r '.allowed_globs[]? // empty' <<<"$guard_json")

    # GNU grep needs -- AFTER --include / --exclude-dir flags, otherwise
    # treats those flags as positional path arguments. (Caught during
    # smoke testing earlier.)
    matches="$(grep -rlE \
      --include='*.go' --include='*.sql' --include='*.sh' --include='*.py' \
      --include='*.json' --include='*.yaml' --include='*.yml' \
      "${EXCLUDE_DIRS_FLAGS[@]}" \
      -- "$pattern" "$ROOT" 2>/dev/null || true)"

    [[ -z "$matches" ]] && continue

    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      rel="${f#${ROOT}/}"
      is_allowed=false
      for re in "${allowed_regexes[@]}"; do
        if [[ "$rel" =~ $re ]]; then
          is_allowed=true
          break
        fi
      done
      $is_allowed && continue
      msg="$name: $rel — $rationale"
      if [[ "$severity" == "warn" ]]; then
        GUARD_VIOLATIONS_WARN+=("$msg")
      else
        GUARD_VIOLATIONS_DENY+=("$msg")
      fi
    done <<< "$matches"
  done < <(jq -c '.integration_guards[]? // empty' "$CONFIG" 2>/dev/null)

  if [[ ${#GUARD_VIOLATIONS_WARN[@]} -gt 0 ]]; then
    echo "[gate-tier1-commit] integration-guard warnings (${#GUARD_VIOLATIONS_WARN[@]}):" >&2
    for v in "${GUARD_VIOLATIONS_WARN[@]}"; do
      echo "  WARN: $v" >&2
      audit "warn" "guard_warn:$v"
    done
  fi

  if [[ ${#GUARD_VIOLATIONS_DENY[@]} -gt 0 ]]; then
    audit "deny" "guard_violations=${#GUARD_VIOLATIONS_DENY[@]}"
    cat <<JSON
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Commit blocked: ${#GUARD_VIOLATIONS_DENY[@]} integration-guard violation(s). See stderr for details."}}
JSON
    cat >&2 <<DIRECTIVE
[gate-tier1-commit] BLOCKED: ${#GUARD_VIOLATIONS_DENY[@]} integration-guard violation(s).

<claude-directive>
This is an AUTOMATED COMMIT GATE. The repo contains code that violates
project-level integration guards declared in .tdd/tdd-config.json
(integration_guards array). These are project-wide invariants — they
fire on every commit when defined, not just Tier 1 cycles.

Violations:
DIRECTIVE
    for v in "${GUARD_VIOLATIONS_DENY[@]}"; do echo "  - $v" >&2; done
    cat >&2 <<DIRECTIVE

You MUST do one of:
  1. Fix the violation: bring the offending file(s) into compliance with
     the guard's invariant.
  2. If the file is legitimately exempt from the guard (e.g., a new
     wrapper that's allowed to call the underlying API), add its glob
     to the guard's allowed_globs list in .tdd/tdd-config.json. Document
     why in the commit message.
  3. If the guard itself is wrong (the invariant has changed), remove
     or revise it. Document why in the commit message.

Guards are FALLBACK protection. If you find yourself adding a guard
after a bug, also write the integration test that would have caught the
bug. See .claude/rules/go-integration-guards.md for the decision tree.
</claude-directive>
DIRECTIVE
    exit 2
  fi
fi

# ---- LAYER 2: TDD ceremony checks (cycle-specific) -----------------------
#
# Only fire when an active cycle exists (PLAN present) AND the staged
# change touches Tier 1 production paths. Enforces M4 + green-proof +
# fresh adjudication for the green commit of a Tier 1 cycle.

# No active cycle → no ceremony gate.
[[ ! -f "$PLAN" ]] && { audit "allow" "no_active_cycle"; exit 0; }

# No Tier 1 staged → ceremony doesn't apply.
[[ ${#TIER1_PROD[@]} -eq 0 ]] && { audit "allow" "no_tier1_staged"; exit 0; }

# Detect commit-message subject for red()/refactor()/green()/etc. classification.
SUBJECT="$(printf '%s\n' "$CMD" | awk '
  {
    n = split($0, parts, " ")
    for (i = 1; i <= n; i++) {
      if (parts[i] == "-m" || parts[i] == "--message") {
        msg = ""
        for (j = i+1; j <= n; j++) {
          if (msg == "") msg = parts[j]; else msg = msg " " parts[j]
        }
        gsub(/^["\x27]+|["\x27]+$/, "", msg)
        print msg
        exit
      }
    }
  }
')"

# Classify subject. red() commits are exempt from the M4 marker BUT
# must touch only Tier 1 test files — never Tier 1 production. The TDD
# red phase ships failing tests, not production code.
#
# Pre-fix (D-SO-04, 2026-05-08): the red(...) case branch exited 0
# unconditionally, letting `red(foo): bypass` with production Tier 1
# staged skip the M4 marker entirely. The TIER1_PROD non-empty guard
# below blocks that bypass.
case "$SUBJECT" in
  red\(*|red:*)
    if [[ ${#TIER1_PROD[@]} -gt 0 ]]; then
      deny "red_commit_with_production_files" \
           "red() commit must ship only failing tests, not production code. Production Tier 1 staged: ${TIER1_PROD[*]}. If the red phase legitimately needs a stub for a brand-new package, STOP and verify with the operator before committing."
    fi
    audit "allow" "red_commit_exempt"
    exit 0
    ;;
esac

# Require M4 marker.
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
