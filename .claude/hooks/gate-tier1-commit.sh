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

# Killswitch (env var; emergency-only — document in commit message).
if [[ "${TDD_COMMIT_GATE_DISABLE:-0}" == "1" ]]; then
  exit 0
fi

# F6: enforcement_mode resolver. Returns "strict"|"warn"|"off". Per-hook
# override (.enforcement_mode_overrides[hook]) wins over global; invalid
# values fall back to "strict" (defense-in-depth — typo can't soften).
resolve_enforcement_mode() {
  local hook_name="$1" cfg="$2"
  if [[ ! -f "$cfg" ]] || ! command -v jq >/dev/null 2>&1; then
    echo "strict"; return
  fi
  # Codex round 1 P1: append `|| true` so jq failure on partial/malformed
  # config doesn't abort under set -e; falls through to strict via case.
  local override
  override="$(jq -r --arg n "$hook_name" \
    '.enforcement_mode_overrides[$n] // empty' "$cfg" 2>/dev/null || true)"
  if [[ -n "$override" && "$override" != "null" ]]; then
    case "$override" in
      strict|warn|off) echo "$override"; return ;;
      # Codex round 1 P1: invalid override MUST fall back to strict
      # immediately. Falling through to global lets a typo soften
      # enforcement when global is warn/off — violates the invariant.
      *)
        echo "[gate-tier1-commit] WARN: invalid enforcement_mode_overrides[$hook_name]='$override'; using strict" >&2
        echo "strict"; return
        ;;
    esac
  fi
  local global
  global="$(jq -r '.enforcement_mode // "strict"' "$cfg" 2>/dev/null || true)"
  case "$global" in
    strict|warn|off) echo "$global" ;;
    *) echo "[gate-tier1-commit] WARN: invalid enforcement_mode='$global'; using strict" >&2; echo "strict" ;;
  esac
}

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

# Codex round 3 P1: validate config parses BEFORE downstream jq queries.
# Without this, a malformed config produces empty tier1_path_regexes /
# integration_guards / etc. — silently softening every gate this hook
# implements (fail-open). Malformed config is an environment fault;
# fail closed via deny-with-strict, bypassing enforcement_mode by design.
if ! jq -e . "$CONFIG" >/dev/null 2>&1; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":".tdd/tdd-config.json failed to parse. The Tier 1 commit gate cannot enforce discipline without a parseable config and refuses to silently soften. Fix the JSON and verify with: jq . .tdd/tdd-config.json"}}
JSON
  cat >&2 <<'DIRECTIVE'
[gate-tier1-commit] BLOCKED: .tdd/tdd-config.json failed to parse.

<claude-directive>
This is an AUTOMATED ENVIRONMENT CHECK. The hook reads tier1 path
regexes, integration guards, and enforcement_mode from the config;
without parseable JSON it would silently fail open (no Tier 1
detection, no guards). Fail closed instead.

You MUST:
  1. Fix the JSON syntax in .tdd/tdd-config.json.
  2. Verify with: jq . .tdd/tdd-config.json
  3. Then retry the commit.
</claude-directive>
DIRECTIVE
  exit 2
fi

# F6: resolve enforcement mode now that we have $CONFIG.
ENFORCEMENT_MODE="$(resolve_enforcement_mode "gate-tier1-commit" "$CONFIG")"

CMD="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[[ -z "$CMD" ]] && exit 0

# Match git commit invocations — direct, via shell wrappers, with global
# git options, or via inline alias injection. Earlier versions used a
# single regex anchored to `git[[:space:]]+commit` at command start;
# Codex review (8 rounds across two cycles) surfaced bypasses:
#   sh -c 'git commit -a'                      → outer is `sh -c`
#   git -c alias.X='commit' X                  → outer is `git -c`
#   git -c user.name=x commit -m msg            → global opt before subcommand
#   echo alias.ci=commit                        → false positive on alias substring
#   bash -c "echo done"; echo "git commit"      → false positive on text in args
#
# matches_git_commit() tokenises with xargs (quote-aware), tracks command
# boundaries (;, &&, ||), and walks tokens to recognise:
#   1. `git [global-opts] commit ...` (direct, with optional global opts)
#   2. `git -c alias.X=...commit... X` (inline alias injection)
#   3. `(sh|bash|zsh|dash|ksh) -*c* PAYLOAD` where PAYLOAD invokes `git commit`
#   4. `eval PAYLOAD` where PAYLOAD invokes `git commit`
#
# KNOWN OUT-OF-SCOPE bypasses (Codex rounds 1 F2 + 5; same architectural
# class as Layer-0-rescue out-of-scope items — can't predict exec without
# eval'ing). Tracked for follow-up cycle:
#   * `python -c "import os; os.system('git commit')"` — interpreter wrapper
#   * Pre-configured user aliases from .gitconfig (`git ci -m`) — needs
#     `git config --get alias.<word>` lookup per invocation
#   * `time bash -c "git commit"`, `sudo bash -c "..."`, `nice bash -c`,
#     `env FOO=1 bash -c`, `nohup bash -c` — transparent-exec prefix
#     before a recognised wrapper hides the wrapper from this matcher
#   * `xargs git commit` and `find -exec git commit \;` — these execute
#     commit but xargs/find are in the backstop's string-output safe-list
#   * Compact metachars without surrounding whitespace: `true|git commit`,
#     `(git commit -m x)` (no space after paren) — pre-normalisation
#     only splits `;`, `&&`, `||`, `\n`
#   * Unknown git global opts before commit (`git --some-future-opt
#     commit`) — global-opt enumeration is incomplete by construction
# Closing this class requires either a real shell parser or pivoting
# the gate to a git pre-commit hook (which sees actual `git commit`
# invocations regardless of how they're spelled).
matches_git_commit() {
  local cmd="$1"

  # Pre-normalise: insert spaces around shell control operators so xargs
  # tokenises adjacent forms (`true&&git commit`, `true;git commit`)
  # correctly. Codex round 2 P1: bash parameter expansion is a literal
  # string substitution, so this also affects content INSIDE quoted
  # strings — but that only changes what we OBSERVE, not what gets
  # executed, so it's safe for analysis.
  local _gc_norm="$cmd"
  # Treat newlines as command separators (xargs would otherwise collapse
  # them into whitespace and lose command-boundary context).
  _gc_norm="${_gc_norm//$'\n'/ ; }"
  _gc_norm="${_gc_norm//;/ ; }"
  # bash treats `&` in replacement specially (doubles it); escape with \&.
  _gc_norm="${_gc_norm//&&/ \&\& }"
  _gc_norm="${_gc_norm//||/ || }"

  local _gc_tokens=() _gc_line
  if command -v xargs >/dev/null 2>&1; then
    while IFS= read -r _gc_line; do
      _gc_tokens+=("$_gc_line")
    done < <(printf '%s' "$_gc_norm" | xargs -n1 printf '%s\n' 2>/dev/null)
  fi
  if [[ ${#_gc_tokens[@]} -eq 0 ]]; then
    read -ra _gc_tokens <<< "$_gc_norm"
  fi

  local _gc_at_start=true
  local _gc_i=0 _gc_n=${#_gc_tokens[@]}
  while [[ $_gc_i -lt $_gc_n ]]; do
    local _gc_tok="${_gc_tokens[_gc_i]}"

    if [[ "$_gc_at_start" == "true" ]]; then
      case "$_gc_tok" in
        git)
          # Walk forward through global opts, look for `commit` subcommand
          # OR `-c alias.X=...commit...` injection where alias `X` is the
          # subcommand actually invoked. Other subcommands break.
          local _gc_j=$((_gc_i + 1))
          local _gc_pending_alias=""
          while [[ $_gc_j -lt $_gc_n ]]; do
            local _gc_sub="${_gc_tokens[_gc_j]}"
            case "$_gc_sub" in
              -c)
                local _gc_kv="${_gc_tokens[$((_gc_j+1))]:-}"
                # Codex round 2 P2: only record alias name if value
                # contains `commit`; defer firing until we see the alias
                # invoked as the subcommand.
                case "$_gc_kv" in
                  alias.*=*commit*)
                    local _gc_aliasname="${_gc_kv#alias.}"
                    _gc_aliasname="${_gc_aliasname%%=*}"
                    if [[ -n "$_gc_aliasname" ]]; then
                      _gc_pending_alias="${_gc_pending_alias}|${_gc_aliasname}|"
                    fi
                    ;;
                esac
                _gc_j=$((_gc_j + 2))
                ;;
              -C|--git-dir|--work-tree|--namespace|--super-prefix|--exec-path|--list-cmds)
                _gc_j=$((_gc_j + 2)) ;;
              --git-dir=*|--work-tree=*|--namespace=*|--super-prefix=*|--exec-path=*|--list-cmds=*)
                _gc_j=$((_gc_j + 1)) ;;
              --no-pager|--bare|--paginate|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--no-optional-locks|--no-advice|--version|--help|-h|-p|-P)
                _gc_j=$((_gc_j + 1)) ;;
              commit) return 0 ;;
              *)
                # Check pending alias names against this subcommand.
                # _gc_pending_alias accumulated as `|name1|name2|`.
                if [[ -n "$_gc_pending_alias" ]]; then
                  case "$_gc_pending_alias" in
                    *"|${_gc_sub}|"*) return 0 ;;
                  esac
                fi
                break
                ;;
            esac
          done
          ;;
        sh|bash|zsh|dash|ksh)
          # Walk forward looking for -c flag (short cluster, NOT a long
          # opt that happens to contain 'c' like --norc / --rcfile).
          # Codex round 2 P1: --* must be matched before -*c*.
          local _gc_j=$((_gc_i + 1))
          while [[ $_gc_j -lt $_gc_n ]]; do
            local _gc_sub="${_gc_tokens[_gc_j]}"
            case "$_gc_sub" in
              --) break ;;
              # Long opts that take a next-token value (skip the value too).
              # Codex round 3 P1: --login is a NO-VALUE flag for bash/zsh;
              # putting it here would skip past the real -c.
              --rcfile|--init-file)
                _gc_j=$((_gc_j + 2)) ;;
              # Short opts that take a next-token value. Codex round 4 P1:
              # `bash -o posix -c '...'` would consume `posix` and then
              # break before reaching the real -c.
              -o|-O|+o|+O)
                _gc_j=$((_gc_j + 2)) ;;
              --*) _gc_j=$((_gc_j + 1)) ;;
              -*c*)
                # Codex round 2 P1: payload may itself be a recognisable
                # commit invocation (e.g., `git -c key=val commit`).
                # Recurse on the payload instead of grepping literal text.
                local _gc_payload="${_gc_tokens[$((_gc_j+1))]:-}"
                if [[ -n "$_gc_payload" ]] && matches_git_commit "$_gc_payload"; then
                  return 0
                fi
                break
                ;;
              -*) _gc_j=$((_gc_j + 1)) ;;
              *) break ;;
            esac
          done
          ;;
        eval)
          # Codex round 2 P1: `eval git commit -m x` (unquoted) tokenises
          # as eval, git, commit, ... — the next-token-only check missed.
          # eval concatenates ALL its args; concat remaining tokens up to
          # next command boundary and recurse.
          local _gc_eval_buf=""
          local _gc_j=$((_gc_i + 1))
          while [[ $_gc_j -lt $_gc_n ]]; do
            local _gc_t2="${_gc_tokens[_gc_j]}"
            case "$_gc_t2" in
              \;|'&&'|'||') break ;;
            esac
            _gc_eval_buf+=" ${_gc_t2}"
            _gc_j=$((_gc_j + 1))
          done
          if [[ -n "$_gc_eval_buf" ]] && matches_git_commit "$_gc_eval_buf"; then
            return 0
          fi
          ;;
      esac
    fi

    # Command boundary: standalone separator tokens (now standalone after
    # the pre-normalisation) reset _gc_at_start.
    case "$_gc_tok" in
      \;|'&&'|'||') _gc_at_start=true ;;
      *) _gc_at_start=false ;;
    esac

    _gc_i=$((_gc_i + 1))
  done

  # Cross-check backstop (Codex round 4 P0). Same architectural pattern
  # as Layer-0-rescue UNCERTAIN: instead of enumerating every shell-syntax
  # position where `git commit` can appear (subshell `()`, brace `{}`,
  # env-var prefix `FOO=x git commit`, pipe `|`, `time`, `nice`, etc.),
  # treat ADJACENT bare `git`+`commit` tokens as a commit invocation
  # UNLESS they are clearly arguments to a string-output command
  # (echo, printf, cat, grep, sed, awk, etc.). xargs strips quotes, so
  # `echo "git commit"` becomes one quoted token (NOT adjacent bare),
  # while a real `git commit` invocation produces two adjacent bare
  # tokens regardless of the surrounding shell syntax.
  local _gc_idx=1
  while [[ $_gc_idx -lt $_gc_n ]]; do
    if [[ "${_gc_tokens[$((_gc_idx - 1))]}" == "git" && "${_gc_tokens[_gc_idx]}" == "commit" ]]; then
      # Walk back from `git` looking for a string-output cmd at the head
      # of this command segment (stopping at known boundaries).
      local _gc_back=$((_gc_idx - 2))
      local _gc_safe=false
      while [[ $_gc_back -ge 0 ]]; do
        case "${_gc_tokens[_gc_back]}" in
          echo|printf|cat|grep|fgrep|egrep|less|more|head|tail|sed|awk|cut|sort|uniq|wc|tr|tee|jq|yq|xargs|find)
            _gc_safe=true; break ;;
          \;|'&&'|'||'|'|') break ;;
        esac
        _gc_back=$((_gc_back - 1))
      done
      if [[ "$_gc_safe" != "true" ]]; then
        return 0
      fi
    fi
    _gc_idx=$((_gc_idx + 1))
  done

  return 1
}

if ! matches_git_commit "$CMD"; then
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
  # F6: enforcement_mode dispatch. warn → stderr advisory + exit 0;
  # off → silent passthrough; strict → original deny logic below.
  local mode="${ENFORCEMENT_MODE:-strict}"
  case "$mode" in
    off)
      audit "off_mode_passthrough" "$reason"
      exit 0
      ;;
    warn)
      audit "warn_mode" "$reason"
      cat >&2 <<EOF
[gate-tier1-commit] WARNING (enforcement_mode=warn): $reason
This would be DENIED in strict mode. Set enforcement_mode: "strict" in
.tdd/tdd-config.json (or remove the override) to enforce.
EOF
      jq -n '{}' 2>/dev/null || echo '{}'
      exit 0
      ;;
  esac
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

# ---- LAYER 0: Size threshold (project-wide, always fire) -----------------
#
# Any commit with churn (added + removed lines) above
# `second_opinion.size_threshold_lines` requires a fresh
# /second-opinion adjudication. Fires regardless of TDD cycle state or
# Tier 1 path matching — catches large refactors on non-Tier-1 paths
# that the Tier-1-specific gate misses.
#
# Default threshold: 50 lines. Set to 0 (or negative) in tdd-config.json
# to disable the layer entirely.
#
# Origin: cycle size-threshold-commit-gate (2026-05-08). Triggered by the
# observation that the gate-tier1-commit.sh refactor (commit 31c5add,
# 280-line bash refactor) shipped without /second-opinion review,
# introducing two bugs (red() bypass + broad COMMITS_RE) that another
# reviewer caught later via D-SO-04 and D-SO-05. Layer 0 closes the
# class: substantial commits cannot land without cross-model review,
# regardless of which paths they touch.

# Validate threshold as a non-negative integer (F3, /second-opinion finding):
# jq returns config values as-is. Bad config (string "abc", float, null,
# bool, array) would make `[[ -gt ]]` error and silently skip the layer.
# Defend: if not a clean integer, fall back to the default 50.
SIZE_THRESHOLD_RAW="$(jq -r '.second_opinion.size_threshold_lines // 50' "$CONFIG" 2>/dev/null || echo 50)"
if [[ "$SIZE_THRESHOLD_RAW" =~ ^-?[0-9]+$ ]]; then
  SIZE_THRESHOLD="$SIZE_THRESHOLD_RAW"
else
  echo "[gate-tier1-commit] WARN: second_opinion.size_threshold_lines is not an integer ('$SIZE_THRESHOLD_RAW'); falling back to 50." >&2
  SIZE_THRESHOLD=50
fi

if [[ "${SIZE_THRESHOLD:-0}" -gt 0 ]]; then
  # Compute churn from the actual commit candidate set, not from
  # arbitrary working-tree state.
  #
  # F2-cycle /second-opinion finding: an earlier version of this code
  # ALWAYS combined cached + working-tree diffs. False-positive'd plain
  # `git commit -m` because unstaged tracked changes (not in the commit)
  # inflated CHURN.
  #
  # Layer-0-rescue /second-opinion finding (P1): cached-emptiness alone
  # is the wrong proxy for commit mode. `git commit -am ...` with a
  # small pre-staged change leaves cached non-empty, so the size gate
  # would count only the small staged file and miss the large tracked
  # WIP that `-a` will sweep into the commit. Bypass.
  #
  # Correct mapping by commit mode:
  #   plain `git commit`      → cached numstat (commits index only)
  #   `git commit -a` / -am   → diff HEAD numstat (commits index + tracked WIP)
  #   `git commit pathspec`   → working-tree numstat (overcount; safe)
  #
  # Pathspec parsing is shell-aware and brittle; for the pathspec case
  # we fall back to working-tree numstat, which OVERCOUNTS but is safe
  # (more reviews, never fewer).
  #
  # Binary files: numstat shows `-\t-` for binary changes. awk's
  # `$1 + $2` would treat `-` as 0, making binary changes invisible.
  # Treat any `-` entry as a large change (set churn to threshold+1)
  # so binary diffs always trigger review. Pure renames (numstat shows
  # `0\t0`) are NOT detected by line count — documented limitation;
  # follow-up cycle should add a separate file-count threshold.

  # Architecture (after Codex rounds 1-6):
  #
  # Layer 0 needs to know which diff source to count for the size
  # threshold. Git has many content-selection modes (-a, -p, pathspec,
  # --pathspec-from-file, --interactive, abbreviated long options, etc.);
  # rounds 1-6 of /second-opinion review on a full git-CLI parser kept
  # finding narrower edge cases. The architectural fix is to add a
  # cross-check backstop: classify into ALL / PATHSPEC / PLAIN / UNCERTAIN,
  # and treat UNCERTAIN as "use diff HEAD" (conservative ceiling).
  #
  # The parser only needs to be perfect at *avoiding false positives*
  # (correctly identifying plain `git commit -m` so unrelated unstaged
  # WIP doesn't deny — the F2-cycle false positive). For false negatives
  # (parser missed a flag that adds working-tree content), the UNCERTAIN
  # branch is the backstop: any --long-opt we don't explicitly recognize
  # flips us to diff HEAD. Costs: occasional false positive on a benign
  # newly-introduced git flag we haven't whitelisted; operator can
  # /second-opinion to bypass. Benefit: no future Codex round can find
  # a new bypass — unknown flags fail closed by construction.
  COMMIT_MODE_ALL=false
  COMMIT_MODE_PATHSPEC=false
  COMMIT_MODE_UNCERTAIN=false

  # Shell-expansion fail-closed (Codex rounds 7 P1, 8 P0). Commands like
  # `mode=a; git commit -$mode -m msg`, `git commit $(cat flags)`, or
  # `touch -- -a && git commit -* -m msg` (where the glob expands to -a
  # post-shell) hide content-selecting flags from a literal-text parser.
  # We can't predict what the shell will do without eval'ing (unsafe);
  # any unescaped $, backtick, or shell glob char (* ? [) flips to
  # UNCERTAIN. Costs: legitimate commits with literal $ or * in the
  # message become UNCERTAIN; operator can /second-opinion to bypass.
  # Benefit: the entire metaprogramming/glob bypass class fails closed.
  #
  # KNOWN OUT-OF-SCOPE bypasses (Codex round 8 — gate-level, not parser):
  #   - `sh -c 'git commit -a -m msg'`: outer command is `sh -c '...'`,
  #     so the hook's COMMITS_RE doesn't match `git commit` and the gate
  #     never fires. Same for `bash -c`, `eval`, etc.
  #   - `git -c alias.ci='commit -a' ci -m msg` and pre-configured git
  #     aliases (`git ci`): outer argv is `git -c` or `git ci`, not
  #     `git commit`; COMMITS_RE doesn't match.
  # Both bypass Layer 0 entirely. Closing them requires broadening
  # COMMITS_RE or moving the gate to a git pre-commit hook. Tracked as
  # follow-up; not in scope for the Layer 0 rescue cycle.
  if printf '%s' "$CMD" | grep -qE '\$|`|\*|\?|\['; then
    COMMIT_MODE_UNCERTAIN=true
  fi
  _CMD_TOKENS=()
  if command -v xargs >/dev/null 2>&1; then
    while IFS= read -r _line; do
      _CMD_TOKENS+=("$_line")
    done < <(printf '%s' "$CMD" | xargs -n1 printf '%s\n' 2>/dev/null)
  fi
  if [[ ${#_CMD_TOKENS[@]} -eq 0 ]]; then
    read -ra _CMD_TOKENS <<< "$CMD"
  fi
  # Walk tokens with state for option-with-arg flags (-m, --message, etc.)
  # and `--` end-of-options. Long options containing 'a' (--amend,
  # --author) hit the --* branch and are skipped; only -a / --all and
  # short clusters containing 'a' set COMMIT_MODE_ALL.
  #
  # Skip past the leading `git commit` (or whatever shell prelude) by
  # only starting to scan AFTER seeing the literal token `commit`.
  _expect_arg=false
  _end_of_opts=false
  _scanning=false
  for _tok in "${_CMD_TOKENS[@]}"; do
    if [[ "$_scanning" != "true" ]]; then
      [[ "$_tok" == "commit" ]] && _scanning=true
      continue
    fi
    if [[ "$_end_of_opts" == "true" ]]; then
      continue
    fi
    if [[ "$_expect_arg" == "true" ]]; then
      _expect_arg=false
      continue
    fi
    case "$_tok" in
      --) _end_of_opts=true; COMMIT_MODE_PATHSPEC=true ;;
      -a|--all|--all=*) COMMIT_MODE_ALL=true; break ;;
      # Pathspec-selecting modes (Codex round 4 P1):
      # --interactive / --patch / -p open a UI that adds working-tree
      # content; --pathspec-from-file reads pathspecs from a file.
      # All three should classify as working-tree candidate set.
      --include|-i|--only|-o|--interactive|--patch|-p) COMMIT_MODE_PATHSPEC=true ;;
      --pathspec-from-file=*) COMMIT_MODE_PATHSPEC=true ;;
      --pathspec-from-file) COMMIT_MODE_PATHSPEC=true; _expect_arg=true ;;
      # Options that REQUIRE a value as the next token.
      # NOTE: -S / --gpg-sign take an OPTIONAL key id. Per git docs the
      # key must be attached (-S<key> / --gpg-sign=<key>); a bare -S
      # signs with the default key and does NOT consume the next token
      # (Codex round 4 P1 — bare -S would otherwise eat a pathspec arg).
      --message|--file|--author|--date|--cleanup|--template|--squash|--fixup|--trailer|--reedit-message|--reuse-message|-m|-F|-c|-C)
        _expect_arg=true
        ;;
      # Short options with attached argument: -mTEXT, -FTEXT, -cREF,
      # -CREF, -STEXT. The arg starts immediately after the flag letter,
      # so any 'a' inside the arg is NOT an -a flag. Codex round 3 P2.
      -m*|-F*|-c*|-C*|-S*) ;;
      --gpg-sign|--gpg-sign=*) ;;  # bare or attached: no next-token consumption
      # Long options that are explicitly known NOT to add working-tree
      # content beyond what's already in the index. Treat as plain mode.
      --amend|--no-edit|--no-verify|--no-gpg-sign|--no-status|--no-post-rewrite|--no-template|--no-rerere-autoupdate|--no-allow-empty-message|--reset-author|--signoff|--no-signoff|--allow-empty|--allow-empty-message|--allow-empty-author|--quiet|--verbose|--dry-run|--short|--porcelain|--long|--status|--null|--no-edit-files|--branch) ;;
      --cleanup=*|--template=*|--trailer=*|--message=*|--file=*|--author=*|--date=*|--reedit-message=*|--reuse-message=*|--squash=*|--fixup=*) ;;
      # Unknown long option (incl. abbreviations like `--intera`,
      # `--patc`, future git flags). Backstop: flip to UNCERTAIN so the
      # diff-source selector uses `diff HEAD --numstat` (conservative).
      # Codex round 6 closure: don't try to perfectly enumerate git's
      # CLI; fail closed for anything we don't recognise.
      --*) COMMIT_MODE_UNCERTAIN=true ;;
      -*)
        _flag_body="${_tok#-}"
        case "$_flag_body" in
          *a*) COMMIT_MODE_ALL=true; break ;;
        esac
        # Clustered short forms like -pm (=-p -m), -vp, -np: 'p' anywhere
        # in the cluster opens patch mode → working-tree candidate set
        # (Codex round 5 P1). -m*/-F*/-c*/-C*/-S* attached-arg patterns
        # match earlier so they don't reach this branch.
        case "$_flag_body" in
          *p*) COMMIT_MODE_PATHSPEC=true ;;
        esac
        _last="${_flag_body: -1}"
        case "$_last" in
          m|F|c|C) _expect_arg=true ;;
          # 'S' deliberately NOT in the consume list — see -S note above.
        esac
        ;;
      *)
        # First non-flag positional after the option block is a pathspec
        # (or the message arg of a no-equals -m, but _expect_arg already
        # consumed that case). Pathspec mode counts the working tree
        # against HEAD because pathspec commits use working-tree content
        # for the matched paths. Codex round 3 P1.
        COMMIT_MODE_PATHSPEC=true
        break
        ;;
    esac
  done
  unset _tok _flag_body _last _expect_arg _end_of_opts _scanning _CMD_TOKENS _line

  if [[ "$COMMIT_MODE_ALL" == "true" || "$COMMIT_MODE_PATHSPEC" == "true" || "$COMMIT_MODE_UNCERTAIN" == "true" ]]; then
    # ALL / PATHSPEC / UNCERTAIN: working-tree content may land in the
    # commit. `git diff HEAD --numstat` covers both cached AND
    # tracked-but-unstaged. Conservative fail-closed: if we can't be
    # sure what's in the candidate set, count everything tracked.
    CACHED_NUMSTAT="$(git diff HEAD --numstat 2>/dev/null)"
  else
    # PLAIN mode: candidate set is the index. Empty index means git
    # commit will fail anyway ("nothing to commit") — leave CHURN at 0
    # so we don't deny on unrelated WIP. Codex round 7 P2: the previous
    # working-tree fallback re-created the F2 false positive for
    # `git commit --amend --no-edit` and similar.
    CACHED_NUMSTAT="$(git diff --cached --numstat 2>/dev/null)"
  fi
  CHURN="$(printf '%s\n' "$CACHED_NUMSTAT" | awk -v thresh="$SIZE_THRESHOLD" '
    {
      if ($1 == "-" || $2 == "-") {
        # Binary file — count as threshold+1 so layer always triggers.
        binary_seen = 1
      } else {
        added += $1
        removed += $2
      }
    }
    END {
      if (binary_seen) print thresh + 1; else print added + removed + 0
    }
  ')"
  unset CACHED_NUMSTAT
  if [[ "${CHURN:-0}" -gt "$SIZE_THRESHOLD" ]]; then
    adj_fresh=false
    if [[ -f "$ADJUDICATION" ]] \
       && [[ -n "$(find "$ADJUDICATION" -mmin -60 -print 2>/dev/null)" ]]; then
      adj_fresh=true
    fi
    if [[ "$adj_fresh" != "true" ]]; then
      audit "deny" "size_threshold_no_adjudication:${CHURN}>${SIZE_THRESHOLD}"
      cat <<JSON
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Commit blocked: ${CHURN} lines changed (threshold: ${SIZE_THRESHOLD}). Large commits require fresh /second-opinion adjudication. Run /second-opinion diff first; the skill writes .tdd/second-opinion-completed.md."}}
JSON
      cat >&2 <<DIRECTIVE
[gate-tier1-commit] BLOCKED: large commit (${CHURN} lines > ${SIZE_THRESHOLD} threshold) without fresh /second-opinion review.

<claude-directive>
This commit changes ${CHURN} lines, above the configured size
threshold (${SIZE_THRESHOLD} lines). Large commits require a fresh
cross-model review even when not on Tier 1 paths — refactors,
sweeping renames, and large additions need a second pair of eyes.

You MUST do one of:
  1. Run /second-opinion diff on the staged changes. The skill writes
     .tdd/second-opinion-completed.md when it finishes.
  2. Split the commit: stage only a subset of files and commit them
     incrementally. Each chunk under threshold passes without review.
  3. Configure: set second_opinion.size_threshold_lines: 0 in
     .tdd/tdd-config.json to disable this layer for the project. Do
     this only if the team explicitly opts out of size-based review.

This layer is project-wide — it does NOT depend on TDD cycle state or
Tier 1 path matching. It catches the failure mode where substantial
refactors on non-Tier-1 files ship without cross-model review.
</claude-directive>
DIRECTIVE
      exit 2
    fi
  fi
fi

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

# Order matters here (combined v1.6.0 review F2, P0 fix):
# Check TIER1_PROD FIRST — if no Tier 1 staged, ceremony doesn't apply
# regardless of plan state. If Tier 1 IS staged but no plan exists,
# DENY (silent allow was the original bypass — a developer who
# deletes .tdd/current-plan.md previously got Tier 1 commits silently
# waved through). Plan-missing-with-Tier-1-staged is "ceremony was
# skipped," which is exactly what the gate exists to catch.

# No Tier 1 staged → ceremony doesn't apply.
[[ ${#TIER1_PROD[@]} -eq 0 ]] && { audit "allow" "no_tier1_staged"; exit 0; }

# Tier 1 staged but no plan → DENY (was silent allow before F2 fix).
if [[ ! -f "$PLAN" ]]; then
  deny "missing .tdd/current-plan.md with Tier 1 staged" \
    "Tier 1 commit blocked: no .tdd/current-plan.md exists, but staged files include Tier 1 production paths. Tier 1 changes require the full TDD ceremony (spec → red → green-authorized → implementation-reviewed). Run the go-tdd-feature or go-tdd-bugfix skill to start the ceremony."
fi

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
