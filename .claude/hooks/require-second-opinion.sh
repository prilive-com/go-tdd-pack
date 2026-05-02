#!/usr/bin/env bash
# .claude/hooks/require-second-opinion.sh
# PreToolUse on Edit|Write|MultiEdit|Bash.
#
# Mechanical enforcement of the second-opinion + TDD flow. Blocks
# code-changing tool calls until the required artifacts exist:
#   - Non-Tier-1 path → require .tdd/second-opinion-completed.md (recent)
#   - Tier 1 path     → also require .tdd/current-plan.md with all 3
#                       APPROVED markers (existing TDD discipline)
#
# Defense-in-depth (because PreToolUse deny on Edit has known bugs:
# anthropics/claude-code #37210, #18312, #41151, #21988):
#   1. chmod 444 the target file (restored after 8s)
#   2. JSON `permissionDecision: "deny"` on stdout
#   3. <claude-directive> on stderr (works around #24327 stop-instead-of-act)
#   4. Exit code 2
#
# Killswitch: SECOND_OPINION_DISABLE=1 (env var only — no file marker).

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
ADJUDICATION="${ROOT}/.tdd/second-opinion-completed.md"
TDD_CONFIG="${ROOT}/.tdd/tdd-config.json"
TDD_PLAN="${ROOT}/.tdd/current-plan.md"
AUDIT="${ROOT}/.tdd/second-opinion-enforcement.log"

mkdir -p "${ROOT}/.tdd" 2>/dev/null

tool=""
audit() {
  printf '{"ts":"%s","tool":"%s","event":"%s","extra":%s}\n' \
    "$(date -u +%FT%TZ)" "${tool:-?}" "$1" "${2:-{\}}" >> "$AUDIT" 2>/dev/null || true
}

allow() { exit 0; }

deny() {
  local reason="$1" key="$2" target="${3:-}"

  # Defense-in-depth #1: chmod 444 the target if it exists and is writable.
  # Works around #37210 (Edit deny silently ignored on macOS).
  # Restore happens after 8s so legitimate retry (after artifacts created)
  # can proceed.
  if [[ -n "$target" && -f "$target" && -w "$target" ]]; then
    chmod 444 "$target" 2>/dev/null || true
    ( sleep 8 && chmod 644 "$target" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi

  audit "deny_$key" "{\"target\":\"${target}\"}"

  # Defense-in-depth #2: JSON deny on stdout (primary mechanism).
  # Static heredoc fallback if jq is unavailable.
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg r "$reason" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $r
      }
    }'
  else
    cat <<JSON
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"${reason//\"/\\\"}"}}
JSON
  fi

  # Defense-in-depth #3: stderr message with <claude-directive>.
  # Works around #24327 (Opus 4.6+ stop-instead-of-act on hook block).
  cat >&2 <<DIRECTIVE
[require-second-opinion] BLOCKED: $reason

<claude-directive>
This is an AUTOMATED ENFORCEMENT, not a user denial. The /second-opinion
skill must run before any non-trivial code change.

You MUST do the following autonomously, in order:
  1. Invoke the /second-opinion skill on the current diff or plan.
  2. Read the findings, decide accept/partial/pushback per finding
     (with the "Why this is correct:" marker for any P0 accept).
  3. The skill will write .tdd/second-opinion-completed.md when it
     completes successfully (Step 6 of the skill body).
  4. THEN retry the tool call. The hook will allow it.

Do NOT bypass with SECOND_OPINION_DISABLE=1 unless the user has
explicitly approved the bypass for this session.

For Tier 1 paths, you also need .tdd/current-plan.md with all three
APPROVED markers from the operator (existing TDD ceremony).
</claude-directive>
DIRECTIVE

  # Defense-in-depth #4: exit code 2.
  # Works around #41151 / #21988 (JSON deny ignored, exit code respected).
  exit 2
}

# Killswitch (env-var only, no file marker).
if [[ "${SECOND_OPINION_DISABLE:-0}" == "1" ]]; then
  audit "killswitch"
  allow
fi

# If codex is missing, we cannot enforce the flow. Pass through with audit.
# (`make doctor` warns the operator separately.)
if ! command -v codex >/dev/null 2>&1; then
  audit "codex_missing"
  allow
fi

# jq is required to parse the input JSON.
if ! command -v jq >/dev/null 2>&1; then
  audit "jq_missing"
  allow
fi

stdin="$(cat)"
tool="$(jq -r '.tool_name // empty' <<<"$stdin" 2>/dev/null || echo '')"

# Extract paths from the tool input. Defensive: covers Edit/Write/MultiEdit
# shapes plus future variants with .files[] / .edits[].file_path.
mapfile -t paths < <(jq -r '
  [
    .tool_input.file_path?,
    .tool_input.path?,
    (.tool_input.files[]?.file_path?),
    (.tool_input.edits[]?.file_path?)
  ] | map(select(. != null and . != "")) | unique | .[]
' <<<"$stdin" 2>/dev/null)

command="$(jq -r '.tool_input.command // empty' <<<"$stdin" 2>/dev/null || echo '')"

# Always-allow paths: edits to these never require a second opinion.
# Mirrors the skill's skip_globs plus our own infrastructure paths.
is_always_allowed_path() {
  local p="$1"
  case "$p" in
    *.md|*.txt|*CHANGELOG*|*README*|*LICENSE*) return 0 ;;
    .editorconfig|*/.editorconfig|.gitignore|*/.gitignore) return 0 ;;
    go.sum|*/go.sum) return 0 ;;
    .github/*|*/.github/*|.gitlab-ci.yml|*/.gitlab-ci.yml) return 0 ;;
    .tdd/*|*/.tdd/*) return 0 ;;
    .claude/*|*/.claude/*) return 0 ;;
    .second-opinion/*|*/.second-opinion/*) return 0 ;;
  esac
  return 1
}

# Bash mutating-pattern detection. Without these, Claude can bypass via
# `cat > file.go`, `sed -i`, `gofmt -w`, etc.
is_bash_mutating() {
  local cmd="$1"
  echo "$cmd" | grep -Eq '(^|[;&|])[[:space:]]*sed[[:space:]]+-i\b'                               && return 0
  echo "$cmd" | grep -Eq '(^|[;&|])[[:space:]]*perl[[:space:]]+-i\b'                              && return 0
  echo "$cmd" | grep -Eq '(^|[;&|])[[:space:]]*gofmt[[:space:]]+-w\b'                             && return 0
  echo "$cmd" | grep -Eq '(^|[;&|])[[:space:]]*goimports[[:space:]]+-w\b'                         && return 0
  echo "$cmd" | grep -Eq '(^|[;&|])[[:space:]]*go[[:space:]]+mod[[:space:]]+(tidy|edit|init)\b'    && return 0
  echo "$cmd" | grep -Eq '(^|[;&|])[[:space:]]*go[[:space:]]+get\b'                               && return 0
  echo "$cmd" | grep -Eq '(^|[;&|])[[:space:]]*cat[[:space:]]+[^|<]*>+[[:space:]]*[^&[:space:]]'  && return 0
  echo "$cmd" | grep -Eq '(^|[;&|])[[:space:]]*tee[[:space:]]+[^|]'                               && return 0
  echo "$cmd" | grep -Eq '(^|[;&|])[[:space:]]*truncate\b'                                        && return 0
  echo "$cmd" | grep -Eq '>>?[[:space:]]*[^&[:space:]]+\.(go|sh|py|ts|js|json|yml|yaml|toml)([[:space:]]|$)' && return 0
  return 1
}

# Decide whether this tool call is a code change that needs the gate.
case "$tool" in
  Edit|Write|MultiEdit)
    if [[ ${#paths[@]} -eq 0 ]]; then
      allow
    fi
    needs_check=false
    for p in "${paths[@]}"; do
      is_always_allowed_path "$p" || { needs_check=true; break; }
    done
    if [[ "$needs_check" == "false" ]]; then
      audit "always_allow_path_passthrough"
      allow
    fi
    ;;
  Bash)
    if [[ -z "$command" ]]; then
      allow
    fi
    if ! is_bash_mutating "$command"; then
      allow
    fi
    # Mutating Bash: try to extract target path for chmod-444 defense.
    target_from_bash=""
    if echo "$command" | grep -Eq '>>?[[:space:]]*[^&[:space:]]+'; then
      target_from_bash="$(echo "$command" | grep -oE '>>?[[:space:]]*[^&[:space:]]+' | head -1 | sed -E 's/^>>?[[:space:]]*//')"
    fi
    if [[ -z "$target_from_bash" ]]; then
      target_from_bash="$(echo "$command" | awk '{print $NF}')"
    fi
    paths=("${target_from_bash:-(unknown)}")
    ;;
  *)
    # Other tools (Read, Glob, Grep, etc.) are never blocked.
    allow
    ;;
esac

# At this point: code-changing tool call. Apply the gate.
TARGET="${paths[0]:-}"

# Check if any changed path is Tier 1 (per existing tdd-config.json).
is_tier1=false
if [[ -f "$TDD_CONFIG" ]]; then
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    for p in "${paths[@]}"; do
      if printf '%s' "$p" | grep -qE "$pattern"; then
        is_tier1=true
        break 2
      fi
    done
  done < <(jq -r '.tier1_path_regexes[]? // empty' "$TDD_CONFIG" 2>/dev/null)
fi

# Second-opinion adjudication artifact: must exist AND be recent (within last hour).
adj_ok=false
if [[ -f "$ADJUDICATION" ]]; then
  if [[ -n "$(find "$ADJUDICATION" -mmin -60 -print 2>/dev/null)" ]]; then
    adj_ok=true
  else
    audit "adjudication_stale" "{\"file\":\"$ADJUDICATION\"}"
  fi
fi

if [[ "$adj_ok" != "true" ]]; then
  deny "Second opinion not completed (or stale: file mtime > 1 hour) for this change. Run /second-opinion on the current diff/plan first; the skill will write .tdd/second-opinion-completed.md when it succeeds." \
       "no_second_opinion" "$TARGET"
fi

# Tier 1 paths additionally require the existing TDD APPROVED markers.
if [[ "$is_tier1" == "true" ]]; then
  if [[ ! -f "$TDD_PLAN" ]]; then
    deny "Tier 1 path ($TARGET) requires .tdd/current-plan.md with APPROVED markers from the operator." \
         "tier1_no_plan" "$TARGET"
  fi
  for marker in "Human approved spec: yes" "Red phase confirmed: yes" "Human approved implementation: yes"; do
    if ! grep -qF "$marker" "$TDD_PLAN" 2>/dev/null; then
      deny "Tier 1 path ($TARGET) missing TDD marker in .tdd/current-plan.md: '$marker'. Complete the TDD ceremony before edit." \
           "tier1_marker_missing" "$TARGET"
    fi
  done
fi

audit "allow"
allow
