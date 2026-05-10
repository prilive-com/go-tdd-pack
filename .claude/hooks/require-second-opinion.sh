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

# v1.6.1 round-6 F1: source the shared commit-mode classifier so the
# hash-binding logic below can pick the right diff source for Bash
# git-commit calls (cached for plain, diff HEAD for -am, scoped pathspec
# for --only / positional pathspec, union for --include / -i). Without
# this, hash binding always used `git diff HEAD --cached` and an -am
# commit could sweep in unstaged Tier 1 WIP not in the recorded hash.
# Same lib feeds gate-tier1-commit.sh — both layers stay in sync.
LIB_COMMIT_MODE="$(dirname -- "${BASH_SOURCE[0]}")/../../scripts/tdd/_lib_commit_mode.sh"
if [[ ! -f "$LIB_COMMIT_MODE" ]]; then
  _RSO_REAL="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
  LIB_COMMIT_MODE="$(dirname -- "$_RSO_REAL")/../../scripts/tdd/_lib_commit_mode.sh"
fi
if [[ ! -f "$LIB_COMMIT_MODE" ]] && [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  LIB_COMMIT_MODE="$CLAUDE_PLUGIN_ROOT/scripts/tdd/_lib_commit_mode.sh"
fi
# v1.6.1 round-14 F1: HARD dependency. Without the lib, Bash git-commit
# classification silently degrades and a `git commit -am ...` can pass
# through is_bash_mutating's allow path. Mirror the jq hard-deny pattern
# (round 1 / C1+C8): fail closed with an install hint rather than
# soft-degrade. The earlier `[[ -f ... ]] && .` form was the bypass.
if [[ ! -f "$LIB_COMMIT_MODE" ]]; then
  cat >&2 <<HOOK_MSG
[require-second-opinion] BLOCKED: shared commit-mode library not found.
Looked for: $LIB_COMMIT_MODE

This file is a hard dependency for safe Bash git-commit classification.
Either:
  - Reinstall the plugin (the lib ships at scripts/tdd/_lib_commit_mode.sh)
  - Set CLAUDE_PLUGIN_ROOT to the plugin's root directory
HOOK_MSG
  exit 2
fi
# shellcheck source=/dev/null
. "$LIB_COMMIT_MODE"

mkdir -p "${ROOT}/.tdd" 2>/dev/null

tool=""
audit() {
  printf '{"ts":"%s","tool":"%s","event":"%s","extra":%s}\n' \
    "$(date -u +%FT%TZ)" "${tool:-?}" "$1" "${2:-{\}}" >> "$AUDIT" 2>/dev/null || true
}

allow() { exit 0; }

deny() {
  local reason="$1" key="$2" target="${3:-}"

  # F6: enforcement_mode dispatch. warn → stderr advisory + exit 0;
  # off → silent passthrough; strict → original deny logic below.
  local mode="${ENFORCEMENT_MODE:-strict}"
  case "$mode" in
    off)
      audit "off_mode_passthrough_$key" "{\"target\":\"${target}\"}"
      exit 0
      ;;
    warn)
      audit "warn_mode_$key" "{\"target\":\"${target}\"}"
      cat >&2 <<EOF
[require-second-opinion] WARNING (enforcement_mode=warn): $reason
This would be DENIED in strict mode. Set enforcement_mode: "strict" in
.tdd/tdd-config.json (or remove the override) to enforce.
EOF
      jq -n '{}' 2>/dev/null || echo '{}'
      exit 0
      ;;
  esac

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

# Codex round 3 P1: validate config parses BEFORE downstream jq queries
# read tier1_path_regexes, second_opinion.* flags, marker_aliases, etc.
# Malformed config would silently soften every Tier-1-scoped check
# (empty regexes → no Tier 1 detection → fewer enforcements). Fail
# closed via deny-with-strict, bypassing enforcement_mode by design
# (environment fault, not TDD discipline). The config-not-found case
# (file missing) still passes through silently for greenfield setup.
if [[ -f "$TDD_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
  if ! jq -e . "$TDD_CONFIG" >/dev/null 2>&1; then
    audit "config_parse_error" "{\"file\":\"$TDD_CONFIG\"}"
    if command -v jq >/dev/null 2>&1; then
      jq -nc '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: ".tdd/tdd-config.json failed to parse. The require-second-opinion hook cannot enforce Tier 1 discipline without a parseable config and refuses to silently soften. Fix the JSON and verify with: jq . .tdd/tdd-config.json"
        }
      }'
    else
      cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":".tdd/tdd-config.json failed to parse. Fix the JSON and verify with: jq . .tdd/tdd-config.json"}}
JSON
    fi
    cat >&2 <<'DIRECTIVE'
[require-second-opinion] BLOCKED: .tdd/tdd-config.json failed to parse.

<claude-directive>
This is an AUTOMATED ENVIRONMENT CHECK. Fix the JSON syntax and verify
with `jq . .tdd/tdd-config.json` before retrying.
</claude-directive>
DIRECTIVE
    exit 2
  fi
fi

# F6: enforcement_mode resolver. Returns "strict"|"warn"|"off". Per-hook
# override (.enforcement_mode_overrides[hook]) wins over global; invalid
# values fall back to "strict" (defense-in-depth — typo can't soften).
resolve_enforcement_mode() {
  local hook_name="$1" cfg="$2"
  if [[ ! -f "$cfg" ]] || ! command -v jq >/dev/null 2>&1; then
    echo "strict"; return
  fi
  # Codex round 1 P1: `|| true` so jq failure on partial/malformed
  # config doesn't abort; falls through to strict via case statement.
  local override
  override="$(jq -r --arg n "$hook_name" \
    '.enforcement_mode_overrides[$n] // empty' "$cfg" 2>/dev/null || true)"
  if [[ -n "$override" && "$override" != "null" ]]; then
    case "$override" in
      strict|warn|off) echo "$override"; return ;;
      # Codex round 1 P1: invalid override MUST short-circuit to strict.
      # Falling through to global softens enforcement on typo'd override.
      *)
        echo "[require-second-opinion] WARN: invalid enforcement_mode_overrides[$hook_name]='$override'; using strict" >&2
        echo "strict"; return
        ;;
    esac
  fi
  local global
  global="$(jq -r '.enforcement_mode // "strict"' "$cfg" 2>/dev/null || true)"
  case "$global" in
    strict|warn|off) echo "$global" ;;
    *) echo "[require-second-opinion] WARN: invalid enforcement_mode='$global'; using strict" >&2; echo "strict" ;;
  esac
}
ENFORCEMENT_MODE="$(resolve_enforcement_mode "require-second-opinion" "$TDD_CONFIG")"

# C1 (v1.6.1): codex-missing must NOT bypass the gate. The hook's
# job is to enforce the presence of a fresh ADJUDICATION ARTIFACT
# (which may have been written by a prior /second-opinion run when
# codex was available). codex-missing is a valid local state — the
# hook continues to the adjudication check below, which fires the
# enforcement_mode-aware deny() if the artifact is missing/stale.
# Operators who need to bypass entirely use SECOND_OPINION_DISABLE=1
# (already handled above).
if ! command -v codex >/dev/null 2>&1; then
  audit "codex_missing"
  # Continue to artifact enforcement; do NOT allow here.
fi

# jq is a hard dependency. Without it we can't parse tool input or
# the config (which means we can't even resolve enforcement_mode).
# Fail closed with a clear install hint. This is an environment
# fault, not a TDD discipline violation, so it bypasses
# enforcement_mode by design.
if ! command -v jq >/dev/null 2>&1; then
  audit "jq_missing"
  cat >&2 <<'HOOK_MSG'
[require-second-opinion] BLOCKED: jq is required for this hook.

Install jq:
  Debian/Ubuntu: sudo apt-get install jq
  macOS:         brew install jq
  Alpine:        apk add jq

Then retry. (This check bypasses enforcement_mode by design — without
jq we cannot read the config to determine the mode.)
HOOK_MSG
  exit 2
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
# F13: prefer canonical .tdd/tdd-config.json `trivial_paths` field;
# fall back to the inline list when config missing/empty OR jq
# unavailable.
#
# C4 + A2 (v1.6.1): Tier 1 paths (declared in tier1_path_regexes)
# are NEVER trivially exempted, regardless of file extension or
# location. Without this, a Tier 1 .md file like
# .claude/skills/second-opinion/SKILL.md would be silently allowed
# by `*.md` in the trivial list — re-opening F4-class governance
# bugs in this hook (the third location of the bug class).
is_always_allowed_path() {
  local p="$1"
  # v1.6.1 round-2 F1: tests are exempt FIRST (red-phase contract).
  # Symmetric with the two commit gates (gate-tier1-commit.sh,
  # scripts/git-hooks/pre-commit) which exempt *_test.go before any
  # Tier 1 check. Without this, editing handler_test.go in a Tier 1
  # directory denies via the C4/A2 Tier-1-first lookup below — but
  # the operator must be able to write the failing test before any
  # adjudication exists. require-tdd-state.sh's phase-aware policy
  # is the right gate for test edits AFTER red is confirmed.
  case "$p" in
    *_test.go) return 0 ;;
  esac
  # C4/A2: check Tier 1 FIRST (after the test exemption). Tier 1
  # paths are never trivially exempted. If the path matches any
  # tier1_path_regex, it must go through the full check
  # (returns 1 = not allowed).
  if [[ -f "$TDD_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
    local tier1_pat
    while IFS= read -r tier1_pat; do
      [[ -z "$tier1_pat" ]] && continue
      if printf '%s' "$p" | grep -qE "$tier1_pat"; then
        return 1  # Tier 1 → not trivially allowed
      fi
    done < <(jq -r '.tier1_path_regexes[]? // empty' "$TDD_CONFIG" 2>/dev/null)
  fi
  # Now check trivial paths (only applies to non-Tier-1 files).
  if [[ -f "$TDD_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
    local config_list_len
    config_list_len="$(jq -r '(.trivial_paths // []) | length' "$TDD_CONFIG" 2>/dev/null || echo 0)"
    if [[ "${config_list_len:-0}" -gt 0 ]]; then
      local pat
      while IFS= read -r pat; do
        [[ -z "$pat" ]] && continue
        # shellcheck disable=SC2053
        [[ "$p" == $pat ]] && return 0
      done < <(jq -r '.trivial_paths[]? // empty' "$TDD_CONFIG" 2>/dev/null)
      return 1
    fi
  fi
  # Inline fallback (preserved verbatim from pre-F13 behavior).
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

# Reject a target containing path-traversal segments (`..`). Without
# this, prefix-only classification is bypassable: ".tdd/../internal/x.go"
# matches `.tdd/*` but Bash resolves it to `internal/x.go` and writes
# production code. Codex round-1 P0 (F1 traversal).
_target_has_traversal() {
  case "$1" in
    *..*) return 0 ;;
    *) return 1 ;;
  esac
}

# Test whether a target path is skill-internal (hook state, config, etc.).
# These paths are not production code; the skill writes them as part of
# its own workflow and should not trigger the mutating-Bash gate.
# F1 closure (combined v1.6.0 review): skill self-writes to .tdd/codex/
# round1.json etc. were deadlocking because the gate required adjudication
# while the skill was in the act of writing the adjudication.
# /dev/* covers /dev/null and other device files (legitimate stderr
# redirect targets like `cat > .tdd/foo 2>/dev/null`).
_target_is_skill_internal() {
  local target="$1"
  case "$target" in
    /dev/*) return 0 ;;
    .tdd/*|.claude/*|.second-opinion/*) return 0 ;;
    */.tdd/*|*/.claude/*|*/.second-opinion/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Extract ALL redirect targets from a command. Critical for bash semantics:
# `cat > a > b` opens AND truncates `a`, then redirects stdout to `b` —
# checking only the last target lets a production write slip through.
# Codex round-1 P0 (F2 multi-redirect).
_extract_all_redirect_targets() {
  echo "$1" | awk '
    {
      n = split($0, parts, /[[:space:]]*>+[[:space:]]*/)
      for (i = 2; i <= n; i++) {
        target = parts[i]
        sub(/^[[:space:]]+/, "", target)
        sub(/[[:space:]].*$/, "", target)
        if (length(target) > 0) print target
      }
    }'
}

# Extract ALL tee positional targets — tee writes to every operand,
# not just the first. Codex round-1 P1 (F3 multi-tee).
_extract_all_tee_targets() {
  echo "$1" | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i == "tee") {
        for (j = i + 1; j <= NF; j++) {
          tok = $j
          if (tok == "|" || tok == "&" || tok == ";" || tok == "&&" || tok == "||") exit
          if (tok ~ /^[0-9]*>/) exit
          if (substr(tok, 1, 1) == "-") continue
          print tok
        }
        exit
      }
    }
  }'
}

# Test whether ALL extracted targets are skill-internal AND none has
# path traversal. Returns 0 if all safe, 1 if any unsafe (or empty list,
# which means the extractor saw no concrete target — fail closed).
_all_targets_safe() {
  local targets="$1"
  [[ -z "$targets" ]] && return 1
  local t
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    _target_has_traversal "$t" && return 1
    _target_is_skill_internal "$t" || return 1
  done <<< "$targets"
  return 0
}

# Helper: detection-with-target-check. Runs a regex; if it matches, also
# checks ALL targets. Returns 0 (mutating) if regex matches AND any
# target is unsafe (production path or contains traversal). Returns 1
# (not mutating) if regex doesn't match OR every target is safe.
#
# Pass extractor function name as third arg (default _extract_all_redirect_targets).
_redirect_mutating() {
  local cmd="$1" pattern="$2" extractor="${3:-_extract_all_redirect_targets}"
  echo "$cmd" | grep -Eq "$pattern" || return 1
  local targets; targets="$("$extractor" "$cmd")"
  if _all_targets_safe "$targets"; then
    return 1
  fi
  return 0
}

# Bash mutating-pattern detection. Without these, Claude can bypass via
# `cat > file.go`, `sed -i`, `gofmt -w`, etc.
is_bash_mutating() {
  local cmd="$1"
  # In-place edits — no redirect target to check; always mutating.
  echo "$cmd" | grep -Eq '(^|[;&|])[[:space:]]*sed[[:space:]]+-i\b'                               && return 0
  echo "$cmd" | grep -Eq '(^|[;&|])[[:space:]]*perl[[:space:]]+-i\b'                              && return 0
  echo "$cmd" | grep -Eq '(^|[;&|])[[:space:]]*gofmt[[:space:]]+-w\b'                             && return 0
  echo "$cmd" | grep -Eq '(^|[;&|])[[:space:]]*goimports[[:space:]]+-w\b'                         && return 0
  echo "$cmd" | grep -Eq '(^|[;&|])[[:space:]]*go[[:space:]]+mod[[:space:]]+(tidy|edit|init)\b'    && return 0
  echo "$cmd" | grep -Eq '(^|[;&|])[[:space:]]*go[[:space:]]+get\b'                               && return 0
  echo "$cmd" | grep -Eq '(^|[;&|])[[:space:]]*truncate\b'                                        && return 0

  # Redirect-style mutations. Target is extracted; skill-internal paths
  # (.tdd/, .claude/, .second-opinion/) are allowed so the skill can
  # write its own artifacts without deadlock. Production targets still
  # trip the gate.
  #
  # cat > file (with the F2-from-parasitoid-trial digit-before-> guard
  # so cat foo 2>/dev/null doesn't false-positive).
  _redirect_mutating "$cmd" '(^|[;&|])[[:space:]]*cat[[:space:]]+([^|<]*[^|<0-9])?>+[[:space:]]*[^&[:space:]]'  && return 0
  # tee path (path-aware now; uses tee-specific extractor since tee writes
  # to its positional arg, not via `>` redirect; checks ALL operands)
  _redirect_mutating "$cmd" '(^|[;&|])[[:space:]]*tee[[:space:]]+[^|]' _extract_all_tee_targets  && return 0
  # >> file.ext (any redirect to source-extension files)
  _redirect_mutating "$cmd" '>>?[[:space:]]*[^&[:space:]]+\.(go|sh|py|ts|js|json|yml|yaml|toml)([[:space:]]|$)'  && return 0
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
    # v1.6.1 round-6 F1: `git commit ...` is mutating (creates a
    # commit object) but is_bash_mutating doesn't recognize it.
    # Treat git-commit as a special case BEFORE that check so the
    # candidate-set + hash-binding path below can fire. Without
    # this, an `-am` Bash command short-circuits to allow before
    # any Tier 1 detection or hash binding runs — the stale-cached-
    # hash bypass round-6 F1 was about.
    # v1.6.1 round-8 F1: token-aware detection via shared
    # matches_git_commit() (same logic as gate-tier1-commit.sh's
    # outer-command matcher). The earlier loose `\bgit\b && \bcommit\b`
    # regex misclassified `echo git commit > internal/auth/handler.go`
    # as a commit invocation and skipped is_bash_mutating's redirect-
    # target detection — a real fail-open found by Codex round 8.
    is_git_commit=false
    if declare -F matches_git_commit >/dev/null 2>&1 \
       && matches_git_commit "$command"; then
      is_git_commit=true
    fi
    if [[ "$is_git_commit" != "true" ]] && ! is_bash_mutating "$command"; then
      allow
    fi
    if [[ "$is_git_commit" == "true" ]] \
       && declare -F classify_commit_mode >/dev/null 2>&1; then
      classify_commit_mode "$command"
      bash_candidate_set=""
      # UNCERTAIN preempts the scoped INCLUDE/PATHSPEC branches (round-7 F1).
      if [[ "$COMMIT_MODE_INCLUDE" == "true" ]] \
         && [[ ${#COMMIT_PATHSPECS[@]} -gt 0 ]] \
         && [[ "$COMMIT_MODE_ALL" != "true" ]] \
         && [[ "$COMMIT_MODE_UNCERTAIN" != "true" ]]; then
        bash_candidate_set="$(git -C "$ROOT" diff --cached --name-only 2>/dev/null; \
                              git -C "$ROOT" diff HEAD --name-only -- "${COMMIT_PATHSPECS[@]}" 2>/dev/null; \
                              git -C "$ROOT" ls-files --others --exclude-standard -- "${COMMIT_PATHSPECS[@]}" 2>/dev/null)"
      elif [[ "$COMMIT_MODE_PATHSPEC" == "true" ]] \
           && [[ ${#COMMIT_PATHSPECS[@]} -gt 0 ]] \
           && [[ "$COMMIT_MODE_ALL" != "true" ]] \
           && [[ "$COMMIT_MODE_UNCERTAIN" != "true" ]]; then
        bash_candidate_set="$(git -C "$ROOT" diff HEAD --name-only -- "${COMMIT_PATHSPECS[@]}" 2>/dev/null; \
                              git -C "$ROOT" ls-files --others --exclude-standard -- "${COMMIT_PATHSPECS[@]}" 2>/dev/null)"
      elif [[ "$COMMIT_MODE_ALL" == "true" ]]; then
        # -a / -am: tracked-modified only (no untracked).
        bash_candidate_set="$(git -C "$ROOT" diff HEAD --name-only 2>/dev/null)"
      elif [[ "$COMMIT_MODE_PATHSPEC" == "true" || "$COMMIT_MODE_UNCERTAIN" == "true" || "$COMMIT_MODE_INCLUDE" == "true" ]]; then
        # interactive/patch PATHSPEC, --pathspec-from-file, UNCERTAIN,
        # or INCLUDE-with-UNCERTAIN/no-pathspecs — fail closed wide.
        bash_candidate_set="$(git -C "$ROOT" diff HEAD --name-only 2>/dev/null; git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null)"
      else
        bash_candidate_set="$(git -C "$ROOT" diff --cached --name-only 2>/dev/null)"
      fi
      paths=()
      while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        paths+=("$_line")
      done <<< "$bash_candidate_set"
      # v1.6.1 round-10 F1: union shell-redirect targets so a
      # `printf x > tier1.go && git commit -am msg` is detected even
      # though the redirect hasn't run yet at hook fire time.
      if [[ ${#COMMIT_REDIRECT_TARGETS[@]} -gt 0 ]]; then
        paths+=("${COMMIT_REDIRECT_TARGETS[@]}")
      fi
      # v1.6.1 round-11 F1: redirect-and-commit pattern is structurally
      # unsafe — the redirect content is created AFTER the hook runs,
      # so hash binding can't catch it. If any redirect target matches
      # a Tier 1 regex, deny outright with split-into-separate-calls
      # guidance. (Non-Tier-1 redirects in commit chains are still OK.)
      if [[ ${#COMMIT_REDIRECT_TARGETS[@]} -gt 0 ]] \
         && [[ -f "$TDD_CONFIG" ]] \
         && command -v jq >/dev/null 2>&1; then
        _r11_tier1_hit=""
        while IFS= read -r _r11_pat; do
          [[ -z "$_r11_pat" ]] && continue
          for _r11_tgt in "${COMMIT_REDIRECT_TARGETS[@]}"; do
            if printf '%s' "$_r11_tgt" | grep -qE "$_r11_pat"; then
              _r11_tier1_hit="$_r11_tgt"
              break 2
            fi
          done
        done < <(jq -r '.tier1_path_regexes[]? // empty' "$TDD_CONFIG" 2>/dev/null)
        if [[ -n "$_r11_tier1_hit" ]]; then
          audit "redirect_and_commit_tier1" "{\"target\":\"$_r11_tier1_hit\"}"
          deny "Compound bash command writes to a Tier 1 file ($_r11_tier1_hit) AND runs git commit. The redirect content is generated AFTER this hook runs, so the second-opinion hash binding cannot review what'll actually land in the commit. Split into separate tool calls: (1) write the file via the Edit tool (which fires the hook with the actual content), (2) commit in a follow-up Bash call." \
               "redirect_and_commit_tier1" "$_r11_tier1_hit"
        fi
      fi
      [[ ${#paths[@]} -eq 0 ]] && paths=("(no-commit-candidates)")
    else
      # Non-commit mutating Bash: try to extract target path for the
      # chmod-444 defense (as before).
      target_from_bash=""
      if echo "$command" | grep -Eq '>>?[[:space:]]*[^&[:space:]]+'; then
        target_from_bash="$(echo "$command" | grep -oE '>>?[[:space:]]*[^&[:space:]]+' | head -1 | sed -E 's/^>>?[[:space:]]*//')"
      fi
      if [[ -z "$target_from_bash" ]]; then
        target_from_bash="$(echo "$command" | awk '{print $NF}')"
      fi
      paths=("${target_from_bash:-(unknown)}")
    fi
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

# F5 — diff/plan hash binding (Tier 1, opt-in via flag).
#
# Closes the gate-bypass where a fresh adjudication for one diff
# silently covers subsequent unrelated changes (the 60-min freshness
# window is "tied to current work" only by proxy; the proxy fails
# when work changes faster than the window).
#
# Recorded by the /second-opinion skill in Step 6a:
#   diff_sha256: <sha of `git diff HEAD --cached`>
#   plan_sha256: <sha of .tdd/current-plan.md>
# Hook computes current hashes and denies on mismatch.
#
# Killswitch (emergency unblock; document in commit message if used):
#   SECOND_OPINION_HASH_DISABLE=1 git ...
#
# Default: opt-in via .tdd/tdd-config.json
#   second_opinion.require_hash_binding_tier1 (default false)
#
# C9 (v1.6.1): mode-based auto-promote. If enforcement_mode=strict
# (per-hook resolved) for require-second-opinion, hash binding is
# REQUIRED regardless of the flag. Rationale: "strict" + flag=false
# is internally inconsistent — leaves the stale-review bypass open
# (run /second-opinion on diff A → modify Tier 1 to diff B → gate
# accepts fresh artifact). Strict means strict.
if [[ "$is_tier1" == "true" ]] \
   && [[ "${SECOND_OPINION_HASH_DISABLE:-0}" != "1" ]] \
   && [[ -f "$TDD_CONFIG" ]] \
   && command -v jq >/dev/null 2>&1; then
  hash_flag="$(jq -r '.second_opinion.require_hash_binding_tier1 // false' "$TDD_CONFIG" 2>/dev/null)"
  # C9 auto-promote: strict mode forces hash binding on regardless of flag.
  if [[ "$hash_flag" != "true" ]] && [[ "$ENFORCEMENT_MODE" == "strict" ]]; then
    audit "hash_binding_auto_promoted_for_strict" "{\"mode\":\"strict\"}"
    hash_flag="true"
  fi
  # v1.6.1 round-4 F2: portable sha256 helper. Linux ships sha256sum
  # (GNU coreutils); macOS ships shasum -a 256. Both produce
  # `<hex>  <file>` so awk '{print $1}' works on either. Mirror of
  # scripts/git-hooks/pre-commit's helper. If hash binding is required
  # (flag on, OR auto-promoted by strict) AND neither tool exists,
  # DENY rather than silently skip — silent skip on macOS without
  # sha256sum was the bypass Codex round 4 flagged.
  _sha256_cmd() {
    if   command -v sha256sum >/dev/null 2>&1; then sha256sum
    elif command -v shasum    >/dev/null 2>&1; then shasum -a 256
    else return 127
    fi
  }
  if [[ "$hash_flag" == "true" ]] \
     && ! command -v sha256sum >/dev/null 2>&1 \
     && ! command -v shasum    >/dev/null 2>&1; then
    audit "hash_binding_no_sha_tool" "{\"strict\":\"$ENFORCEMENT_MODE\"}"
    deny "Hash binding is required (require_hash_binding_tier1=true, or strict mode auto-promoted) but neither sha256sum nor shasum is available on PATH. Install GNU coreutils (Linux) or BSD shasum (macOS — usually pre-installed). Killswitch: SECOND_OPINION_HASH_DISABLE=1." \
         "no_sha_tool" "$TARGET"
  fi
  if [[ "$hash_flag" == "true" ]]; then
    recorded_diff="$(awk '/^diff_sha256:/ {print $2; exit}' "$ADJUDICATION" 2>/dev/null)"
    recorded_plan="$(awk '/^plan_sha256:/ {print $2; exit}' "$ADJUDICATION" 2>/dev/null)"
    # Codex round 2 P3: validate hash format. A non-hex value would
    # corrupt the audit JSON (which interpolates the value) and could
    # produce confusing log text. sha256 is exactly 64 lowercase hex
    # chars; anything else is treated as missing (forces a re-run).
    if [[ -n "$recorded_diff" ]] && ! [[ "$recorded_diff" =~ ^[0-9a-f]{64}$ ]]; then
      recorded_diff=""
    fi
    if [[ -n "$recorded_plan" ]] && ! [[ "$recorded_plan" =~ ^[0-9a-f]{64}$ ]]; then
      recorded_plan=""
    fi

    # v1.6.1 round-6 F1: pick the diff source based on what the actual
    # commit will ship. For Edit/Write/MultiEdit (non-commit edits),
    # cached is correct ("did the staged diff change since review?").
    # For Bash git-commit, the diff that lands depends on commit mode:
    #   plain         → cached
    #   -a / -am      → diff HEAD (cached + tracked WIP, no untracked)
    #   --include /-i → cached ∪ scoped pathspec working-tree
    #   --only / pos  → scoped pathspec working-tree
    # Without this, an -am commit could sweep in unstaged Tier 1
    # changes whose hash was never bound to the recorded adjudication.
    # v1.6.1 round-8 F1: same token-aware matches_git_commit() check
    # as the Bash candidate-set branch above. v1.6.1 round-7 F1:
    # INCLUDE branch must also check UNCERTAIN — without that guard,
    # shell expansion in the command
    # (`git commit --include notes.txt $EXTRA`) could introduce files
    # invisible to the bound hash.
    if [[ "$tool" == "Bash" ]] \
       && [[ -n "${command:-}" ]] \
       && declare -F classify_commit_mode >/dev/null 2>&1 \
       && declare -F matches_git_commit >/dev/null 2>&1 \
       && matches_git_commit "$command"; then
      classify_commit_mode "$command"
      if [[ "$COMMIT_MODE_ALL" == "true" ]]; then
        current_diff="$(git -C "$ROOT" diff HEAD 2>/dev/null | _sha256_cmd | awk '{print $1}')"
      elif [[ "$COMMIT_MODE_INCLUDE" == "true" ]] \
           && [[ ${#COMMIT_PATHSPECS[@]} -gt 0 ]] \
           && [[ "$COMMIT_MODE_UNCERTAIN" != "true" ]]; then
        current_diff="$( { git -C "$ROOT" diff HEAD --cached 2>/dev/null; \
                            git -C "$ROOT" diff HEAD -- "${COMMIT_PATHSPECS[@]}" 2>/dev/null; } \
                          | _sha256_cmd | awk '{print $1}')"
      elif [[ "$COMMIT_MODE_PATHSPEC" == "true" ]] && [[ ${#COMMIT_PATHSPECS[@]} -gt 0 ]] \
           && [[ "$COMMIT_MODE_UNCERTAIN" != "true" ]]; then
        current_diff="$(git -C "$ROOT" diff HEAD -- "${COMMIT_PATHSPECS[@]}" 2>/dev/null \
                          | _sha256_cmd | awk '{print $1}')"
      elif [[ "$COMMIT_MODE_UNCERTAIN" == "true" || "$COMMIT_MODE_PATHSPEC" == "true" || "$COMMIT_MODE_INCLUDE" == "true" ]]; then
        # interactive/patch PATHSPEC, --pathspec-from-file, UNCERTAIN,
        # or INCLUDE-with-UNCERTAIN/no-pathspecs — fail closed wide.
        current_diff="$(git -C "$ROOT" diff HEAD 2>/dev/null | _sha256_cmd | awk '{print $1}')"
      else
        current_diff="$(git -C "$ROOT" diff HEAD --cached 2>/dev/null | _sha256_cmd | awk '{print $1}')"
      fi
    else
      current_diff="$(git -C "$ROOT" diff HEAD --cached 2>/dev/null | _sha256_cmd | awk '{print $1}')"
    fi
    current_plan=""
    if [[ -f "$TDD_PLAN" ]]; then
      current_plan="$(_sha256_cmd < "$TDD_PLAN" 2>/dev/null | awk '{print $1}')"
    fi

    # Codex round 1 P1: a forged or stale adjudication can omit ONE hash
    # field and the omitted dimension is silently unenforced. With Tier
    # 1 + flag on, BOTH fields must be present (and non-empty). Even
    # "no staged diff" produces a non-empty hash (sha of empty stream
    # is a valid 64-hex value), so empty-string here is always wrong.
    if [[ -z "$recorded_diff" || -z "$recorded_plan" ]]; then
      audit "missing_hash_field" "{\"flag\":\"on\",\"diff_present\":\"$([[ -n "$recorded_diff" ]] && echo true || echo false)\",\"plan_present\":\"$([[ -n "$recorded_plan" ]] && echo true || echo false)\"}"
      deny "Adjudication file is missing one or both hash fields (diff_sha256/plan_sha256). With second_opinion.require_hash_binding_tier1=true, BOTH hashes are required so the gate enforces both diff AND plan content binding. A partial omission would silently disable half the check. Re-run /second-opinion (the skill records both hashes automatically in Step 6a) — or set the flag to false in .tdd/tdd-config.json to opt out. Killswitch: SECOND_OPINION_HASH_DISABLE=1." \
           "missing_hash_field" "$TARGET"
    fi

    if [[ -n "$recorded_diff" && "$recorded_diff" != "$current_diff" ]]; then
      audit "diff_hash_mismatch" "{\"recorded\":\"${recorded_diff:0:12}\",\"current\":\"${current_diff:0:12}\"}"
      deny "Diff has changed since /second-opinion adjudication (recorded: ${recorded_diff:0:12}…, current: ${current_diff:0:12}…). The reviewed work isn't the work you're about to commit. Re-run /second-opinion on the current diff. Killswitch: SECOND_OPINION_HASH_DISABLE=1." \
           "diff_hash_mismatch" "$TARGET"
    fi

    if [[ -n "$recorded_plan" && "$recorded_plan" != "$current_plan" ]]; then
      audit "plan_hash_mismatch" "{\"recorded\":\"${recorded_plan:0:12}\",\"current\":\"${current_plan:0:12}\"}"
      deny "Plan has changed since /second-opinion adjudication (recorded: ${recorded_plan:0:12}…, current: ${current_plan:0:12}…). The reviewed plan isn't the current plan. Re-run /second-opinion. Killswitch: SECOND_OPINION_HASH_DISABLE=1." \
           "plan_hash_mismatch" "$TARGET"
    fi
  fi
fi

# PARTIAL discipline check (trial-feedback hardening): every 'stance: PARTIAL' entry in the
# adjudication artifact must have a substantive 'rejected:' field. Catches
# the sycophancy-theatre failure mode where Claude labels a finding
# PARTIAL while functionally accepting 100% of it (label drift). Real
# in-trial example: F2 labeled PARTIAL with 100% ACCEPT behaviour, no
# rejected substance.
#
# Anti-patterns rejected: blank, nothing, n/a, none, -, <10 chars.
# YAML comment lines (^# or ^[[:space:]]+#) are skipped — the template
# carries commented-out hints for the conditional fields.
partial_violation="$(awk '
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*-[[:space:]]*id:/ {
    if (in_finding && stance == "PARTIAL") {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", rejected_text)
      lc = tolower(rejected_text)
      if (rejected_text == "" || lc == "nothing" || lc == "n/a" || lc == "none" || lc == "-" || length(rejected_text) < 10) {
        print current_id; exit 0
      }
    }
    in_finding = 1; stance = ""; rejected_text = ""
    sub(/.*id:[[:space:]]*/, "", $0); current_id = $0
    next
  }
  /^[[:space:]]+stance:/ {
    sub(/.*stance:[[:space:]]*/, "", $0); stance = $0; next
  }
  /^[[:space:]]+rejected:/ {
    sub(/.*rejected:[[:space:]]*/, "", $0); rejected_text = $0; next
  }
  END {
    if (in_finding && stance == "PARTIAL") {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", rejected_text)
      lc = tolower(rejected_text)
      if (rejected_text == "" || lc == "nothing" || lc == "n/a" || lc == "none" || lc == "-" || length(rejected_text) < 10) {
        print current_id
      }
    }
  }
' "$ADJUDICATION" 2>/dev/null)"

if [[ -n "$partial_violation" ]]; then
  audit "partial_empty_rejection" "{\"finding\":\"$partial_violation\"}"
  deny "PARTIAL stance on finding ${partial_violation} has empty/insubstantive 'rejected:' field (matches anti-pattern: blank/nothing/n/a/none/-/<10 chars). PARTIAL is the load-bearing slot for sycophancy-theatre (labeling PARTIAL while functionally accepting 100%). Fill 'rejected:' with a concrete claim you disagree with, or change the stance to ACCEPT/PUSHBACK. See .claude/skills/second-opinion/SKILL.md Step 4." \
       "partial_empty_rejection" "$TARGET"
fi

# Tier 1 paths additionally require the edit-time TDD APPROVED markers.
# 2026-05-05 redesign: M1 + M2 + M3 (spec, red, green-authorized). M4
# (Implementation reviewed) is checked at commit time by gate-tier1-commit.sh,
# not here. Backwards-compat alias: old "Human approved implementation: yes"
# is accepted for "Green phase authorized: yes" with stderr deprecation.
if [[ "$is_tier1" == "true" ]]; then
  if [[ ! -f "$TDD_PLAN" ]]; then
    deny "Tier 1 path ($TARGET) requires .tdd/current-plan.md with APPROVED markers from the operator." \
         "tier1_no_plan" "$TARGET"
  fi
  TDD_CONFIG_FILE="${ROOT}/.tdd/tdd-config.json"
  # Resolve required edit-time markers from config (prefer the new field).
  required_markers=()
  if [[ -f "$TDD_CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r m; do
      [[ -n "$m" ]] && required_markers+=("$m")
    done < <(jq -r '
      if (.required_markers_edit_time | type) == "array"
      then .required_markers_edit_time[]?
      else .required_markers[]? // empty
      end
    ' "$TDD_CONFIG_FILE" 2>/dev/null)
  fi
  # Sane default if config missing or empty (matches the new 4-marker design).
  if [[ ${#required_markers[@]} -eq 0 ]]; then
    required_markers=("Human approved spec: yes" "Red phase confirmed: yes" "Green phase authorized: yes")
  fi
  # Read marker_aliases (new -> old) for backwards-compat.
  alias_pairs=""
  if [[ -f "$TDD_CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
    alias_pairs="$(jq -r '.marker_aliases // {} | to_entries[] | "\(.key)\t\(.value)"' "$TDD_CONFIG_FILE" 2>/dev/null || true)"
  fi
  for marker in "${required_markers[@]}"; do
    if grep -qF "$marker" "$TDD_PLAN" 2>/dev/null; then
      continue
    fi
    # Try alias.
    alias=""
    if [[ -n "$alias_pairs" ]]; then
      while IFS=$'\t' read -r k v; do
        [[ "$k" == "$marker" ]] && alias="$v"
      done <<< "$alias_pairs"
    fi
    if [[ -n "$alias" ]] && grep -qF "$alias" "$TDD_PLAN" 2>/dev/null; then
      echo "[require-second-opinion] DEPRECATION: plan uses old marker '$alias' (renamed to '$marker'). Run scripts/migrate-tdd-markers.sh." >&2
      continue
    fi
    deny "Tier 1 path ($TARGET) missing TDD edit-time marker in .tdd/current-plan.md: '$marker'. Complete the matching gate before editing — see docs/specs/tdd-gate-conflict-resolution-spec.md." \
         "tier1_marker_missing" "$TARGET"
  done

  # v1.6.0 Tier 1 artifact checks (opt-in via config flags). All default
  # OFF for safe rollout. Flip flags in .tdd/tdd-config.json after the
  # eval harness shows value for the codebase. See
  # docs/specs/second-opinion-v1.6.0-spec.md §3.1.
  if [[ -f "$TDD_CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
    require_packet="$(jq -r '.second_opinion.require_research_packet_tier1 // false' "$TDD_CONFIG_FILE" 2>/dev/null)"
    require_pass_a="$(jq -r '.second_opinion.require_pass_a_tier1 // false' "$TDD_CONFIG_FILE" 2>/dev/null)"
    require_matrix="$(jq -r '.second_opinion.require_disposition_matrix_tier1 // false' "$TDD_CONFIG_FILE" 2>/dev/null)"
  else
    require_packet=false
    require_pass_a=false
    require_matrix=false
  fi

  if [[ "$require_packet" == "true" ]]; then
    packet="${ROOT}/.tdd/research-packet.md"
    if [[ ! -f "$packet" ]]; then
      deny "Tier 1 path ($TARGET) requires .tdd/research-packet.md per second_opinion.require_research_packet_tier1. Write the packet before editing — see docs/specs/second-opinion-v1.6.0-spec.md §2.3 and .tdd/templates/research-packet-template.md." \
           "tier1_packet_missing" "$TARGET"
    fi
    # Count source entries (any list item under "## Sources" — supports
    # numbered lists "1. " and bullets "- " or "* ").
    source_count="$(awk '
      /^## Sources/ { in_sources = 1; next }
      /^## / { in_sources = 0 }
      in_sources && /^[[:space:]]*([0-9]+\.|-|\*)[[:space:]]+/ { count++ }
      END { print count + 0 }
    ' "$packet" 2>/dev/null)"
    if [[ "${source_count:-0}" -lt 3 ]]; then
      deny "Tier 1 path ($TARGET): .tdd/research-packet.md has only ${source_count:-0} source(s); ≥3 required. The packet anchors Codex's review against the same evidence you consulted; thin sources mean weak anchoring." \
           "tier1_packet_thin_sources" "$TARGET"
    fi
  fi

  if [[ "$require_pass_a" == "true" ]] && [[ "${SECOND_OPINION_PASS_A_DISABLE:-0}" != "1" ]]; then
    pass_a="${ROOT}/.tdd/codex/independent-design.md"
    if [[ ! -f "$pass_a" ]]; then
      deny "Tier 1 path ($TARGET) requires .tdd/codex/independent-design.md (Pass A blind independent design) per second_opinion.require_pass_a_tier1. Run /second-opinion plan to generate. Killswitch: export SECOND_OPINION_PASS_A_DISABLE=1." \
           "tier1_pass_a_missing" "$TARGET"
    fi
    if [[ -z "$(find "$pass_a" -mmin -60 -print 2>/dev/null)" ]]; then
      deny "Tier 1 path ($TARGET): .tdd/codex/independent-design.md is stale (mtime > 60min). Re-run /second-opinion plan to refresh Pass A — the plan may have changed since the last review." \
           "tier1_pass_a_stale" "$TARGET"
    fi
  fi

  if [[ "$require_matrix" == "true" ]]; then
    matrix="${ROOT}/.tdd/codex/disposition-matrix.md"
    round1="${ROOT}/.tdd/codex/round1.json"
    if [[ ! -f "$matrix" ]]; then
      deny "Tier 1 path ($TARGET) requires .tdd/codex/disposition-matrix.md per second_opinion.require_disposition_matrix_tier1. Write the matrix in Step 6 of /second-opinion — see .tdd/templates/disposition-matrix-template.md." \
           "tier1_matrix_missing" "$TARGET"
    fi
    # F12: detect unfilled migration placeholders. The migration scripts
    # (migrate-rebuttal-to-matrix.sh) produce template-shaped Reason
    # text like `<migrated; fill in 1-line concern>` and `<fill in
    # the actual reason>`. Without this check, an unedited migrated
    # matrix passes the existing PARTIAL discipline check (>10 chars,
    # no anti-pattern keyword match) — operator ships a "complete"
    # matrix that contains template lies.
    # Use grep -m1 (max 1 match) so we don't pipe through head — and `|| true`
    # so a non-matching grep doesn't bubble up as a non-zero exit
    # under pipefail (Codex round 1 P1).
    placeholder_hit="$(grep -nEm1 '<migrated;|<migrated from|<fill in' "$matrix" 2>/dev/null || true)"
    if [[ -n "$placeholder_hit" ]]; then
      # Audit JSON: don't interpolate the matched line (could contain
      # backslashes / control chars that break JSON). Codex round 1 P3.
      audit "matrix_unfilled_placeholder" "{\"matrix\":\"${matrix//\"/\\\"}\"}"
      deny "Tier 1 path ($TARGET): disposition-matrix.md contains unfilled migration placeholder text (line: ${placeholder_hit}). The migrate-rebuttal-to-matrix.sh script writes <migrated; ...> / <fill in ...> placeholders that need operator action — they're template scaffolding, not real adjudication. Edit the matrix to replace every placeholder with concrete content." \
           "matrix_unfilled_placeholder" "$TARGET"
    fi
    # Row count == findings count check (only if round1.json available).
    if [[ -f "$round1" ]] && command -v jq >/dev/null 2>&1; then
      findings_count="$(jq -r '(.findings // []) | length' "$round1" 2>/dev/null)"
      matrix_rows="$(awk '
        /^## Findings table/ { in_table = 1; next }
        /^## / { in_table = 0 }
        in_table && /^\|[[:space:]]+F[0-9]+[[:space:]]+\|/ { count++ }
        END { print count + 0 }
      ' "$matrix" 2>/dev/null)"
      if [[ -n "$findings_count" ]] && [[ "$findings_count" != "null" ]] \
         && [[ "${matrix_rows:-0}" != "$findings_count" ]]; then
        deny "Tier 1 path ($TARGET): disposition-matrix.md has ${matrix_rows:-0} row(s) but round1.json has $findings_count finding(s). Add a row per Codex finding — discipline rule: every finding gets a Disposition." \
             "tier1_matrix_count_mismatch" "$TARGET"
      fi
    fi
  fi
fi

audit "allow"
allow
