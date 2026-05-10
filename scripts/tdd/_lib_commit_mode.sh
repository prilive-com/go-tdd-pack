#!/usr/bin/env bash
# scripts/tdd/_lib_commit_mode.sh
#
# Shared library: parse a `git commit ...` command string, classify its
# content-selection mode, and capture explicit positional pathspecs.
# Sourced by both .claude/hooks/gate-tier1-commit.sh (PreToolUse Tier 1
# enforcement) and .claude/hooks/require-second-opinion.sh (PreToolUse
# hash binding) so the two layers agree on what files a given Bash
# git-commit will actually ship.
#
# v1.6.1 round 6 origin: Codex round 6 caught that require-second-opinion's
# hash binding always used `git diff HEAD --cached`, which silently
# allowed `git commit -am` to sweep in unstaged Tier 1 changes that
# weren't in the recorded hash. Closing that bypass required the same
# classifier in both hooks, so the function was extracted here.
#
# CONTRACT
#
# After sourcing this file, callers run:
#
#   classify_commit_mode "$CMD"
#
# Outputs (set as bash globals):
#
#   COMMIT_MODE_ALL         true / false   `-a` / `--all` / cluster `*a*`
#   COMMIT_MODE_INCLUDE     true / false   `--include` / `-i` / cluster `*i*`
#   COMMIT_MODE_PATHSPEC    true / false   `--only` / `-o` / `-p` / `-i`
#                                          / `--patch` / `--interactive`
#                                          / cluster `*o*`/`*p*`/`*i*`
#                                          / `--pathspec-from-file`
#                                          / `--`-followed-by-token
#                                          / first positional non-flag
#   COMMIT_MODE_UNCERTAIN   true / false   unknown long flag, shell
#                                          metachar outside quotes,
#                                          or shell metacharacter token
#                                          (`(`, `)`, `{`, `}`, `;`,
#                                          `&`, `|`)
#   COMMIT_PATHSPECS        bash array of explicit positional pathspecs
#                           (only populated when PATHSPEC was set by
#                           an actual pathspec; empty for interactive
#                           or `--pathspec-from-file` modes).
#
# All four false ⇒ PLAIN mode (commits the index only).
#
# DRIFT GUARD
#
# Both consumers depend on the EXACT semantics here. Any change to the
# classifier MUST be matched by:
#   - new fixtures in scripts/tdd-test-hooks.sh under the v161-r* blocks
#   - the cross-cycle invariant test "v161-c14: classify_commit_mode is
#     sourced from the lib (no inline duplicate)" which scans for
#     `classify_commit_mode()` definitions in the consumer hooks and
#     fails if any are present.
#
# PARSER PHILOSOPHY (history)
#
# This parser only needs to be perfect at *avoiding false positives*
# (correctly identifying plain `git commit -m` so unrelated unstaged
# WIP doesn't deny). For false negatives (parser missed a flag that
# adds working-tree content), the UNCERTAIN branch is the backstop:
# any --long-opt we don't explicitly recognize, plus any unquoted
# shell metachar, flips us to UNCERTAIN. Costs: occasional false
# positive on a benign newly-introduced git flag we haven't
# whitelisted; operator can /second-opinion to bypass. Benefit: no
# future Codex round can find a new bypass through unknown flags.
#
# KNOWN OUT-OF-SCOPE bypasses (gate-level, not parser):
#   - `sh -c 'git commit -a -m msg'`: outer command is `sh -c '...'`,
#     so the hook's COMMITS_RE doesn't match `git commit` and the gate
#     never fires. Same for `bash -c`, `eval`, etc.
#   - `git -c alias.ci='commit -a' ci -m msg` and pre-configured git
#     aliases (`git ci`): outer argv is `git -c` or `git ci`, not
#     `git commit`; COMMITS_RE doesn't match.
# Both bypass Layer 0 entirely. Closing them requires broadening
# COMMITS_RE or moving the gate to a git pre-commit hook. Tracked as
# follow-up; not in scope for this library.

# matches_git_commit: token-aware "is this command a `git commit ...`
# invocation?" detector. Handles direct invocations, git global
# options before `commit` (-C, -c, --git-dir=, --work-tree=, etc.),
# inline alias injection (`git -c alias.X=commit X`), shell wrappers
# (`sh -c '...'`, `bash -c '...'`, `eval ...`), and the cross-check
# backstop for adjacent bare `git`+`commit` tokens not preceded by a
# string-output command.
#
# Origin: extracted from .claude/hooks/gate-tier1-commit.sh after
# v1.6.1 round-8 P0, where require-second-opinion.sh's loose
# `\bgit\b && \bcommit\b` regex misclassified
# `echo git commit > internal/auth/handler.go` as a commit
# invocation and skipped redirect-target detection.
#
# KNOWN OUT-OF-SCOPE bypasses (Codex rounds 1 F2 + 5; same
# architectural class as Layer-0-rescue out-of-scope items):
#   * `python -c "import os; os.system('git commit')"` — interpreter wrapper
#   * Pre-configured user aliases from .gitconfig (`git ci -m`)
#   * `time bash -c "git commit"`, `sudo bash -c`, `nice bash -c`,
#     `env FOO=1 bash -c`, `nohup bash -c`
#   * `xargs git commit`, `find -exec git commit \;`
#   * Compact metachars without surrounding whitespace
matches_git_commit() {
  local cmd="$1"

  # Pre-normalise: insert spaces around shell control operators so
  # xargs tokenises adjacent forms (`true&&git commit`,
  # `true;git commit`) correctly.
  local _gc_norm="$cmd"
  _gc_norm="${_gc_norm//$'\n'/ ; }"
  _gc_norm="${_gc_norm//;/ ; }"
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
          local _gc_j=$((_gc_i + 1))
          local _gc_pending_alias=""
          while [[ $_gc_j -lt $_gc_n ]]; do
            local _gc_sub="${_gc_tokens[_gc_j]}"
            case "$_gc_sub" in
              -c)
                local _gc_kv="${_gc_tokens[$((_gc_j+1))]:-}"
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
          local _gc_j=$((_gc_i + 1))
          while [[ $_gc_j -lt $_gc_n ]]; do
            local _gc_sub="${_gc_tokens[_gc_j]}"
            case "$_gc_sub" in
              --) break ;;
              --rcfile|--init-file)
                _gc_j=$((_gc_j + 2)) ;;
              -o|-O|+o|+O)
                _gc_j=$((_gc_j + 2)) ;;
              --*) _gc_j=$((_gc_j + 1)) ;;
              -*c*)
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

    case "$_gc_tok" in
      \;|'&&'|'||') _gc_at_start=true ;;
      *) _gc_at_start=false ;;
    esac

    _gc_i=$((_gc_i + 1))
  done

  # Cross-check backstop: adjacent bare `git`+`commit` tokens not
  # preceded by a string-output command match. Catches subshell
  # `(git commit)`, brace `{git commit;}`, env-var prefix
  # `FOO=x git commit`, etc.
  local _gc_idx=1
  while [[ $_gc_idx -lt $_gc_n ]]; do
    if [[ "${_gc_tokens[$((_gc_idx - 1))]}" == "git" && "${_gc_tokens[_gc_idx]}" == "commit" ]]; then
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

classify_commit_mode() {
  local CMD="$1"
  COMMIT_MODE_ALL=false
  COMMIT_MODE_PATHSPEC=false
  COMMIT_MODE_UNCERTAIN=false
  COMMIT_MODE_INCLUDE=false
  COMMIT_PATHSPECS=()
  # v1.6.1 round-10 F1: redirect targets (`> file`, `>> file`) elsewhere
  # in the same compound bash command. PreToolUse hooks fire before the
  # bash runs, so a `printf x > tier1.go && git commit -am msg` shows
  # an empty diff at hook time but the redirect mutates the Tier 1 file
  # before the commit picks it up. Both consumers (gate-tier1-commit.sh
  # CHANGED_FILES and require-second-opinion.sh paths) union these
  # targets into their candidate sets so Tier 1 detection still fires.
  COMMIT_REDIRECT_TARGETS=()

  # Shell-expansion fail-closed (quote-aware, v1.6.1 round-5 F1).
  # Single-quoted regions disable ALL expansion; double-quoted regions
  # disable * ? [ but still allow $ and backtick. Strip single-quoted
  # regions, then check $ / backtick on the remainder; strip
  # double-quoted regions and check * ? [ on the residual.
  local _cmd_no_sq _cmd_no_q
  _cmd_no_sq="$(printf '%s' "$CMD" | sed -e "s/'[^']*'//g")"
  if printf '%s' "$_cmd_no_sq" | grep -qE '\$|`'; then
    COMMIT_MODE_UNCERTAIN=true
  fi
  if [[ "$COMMIT_MODE_UNCERTAIN" != "true" ]]; then
    _cmd_no_q="$(printf '%s' "$_cmd_no_sq" | sed -e 's/"[^"]*"//g')"
    if printf '%s' "$_cmd_no_q" | grep -qE '\*|\?|\['; then
      COMMIT_MODE_UNCERTAIN=true
    fi
  fi

  # v1.6.1 round-9 F1: compound `git add <tier1> && git commit -m msg`
  # bypass. PreToolUse hooks fire BEFORE bash runs, so cached/staged
  # state is empty until the `git add` portion runs. Any index- or
  # worktree-mutating git subcommand alongside the commit means the
  # candidate set at hook time doesn't reflect what'll actually be
  # committed; flip to UNCERTAIN so the wide-scope candidate set
  # catches the mutation. Conservative: flags presence anywhere in
  # the command rather than doing positional analysis.
  if printf '%s' "$_cmd_no_sq" | grep -qE '\bgit[[:space:]]+(add|rm|mv|restore|stash|checkout|switch|reset|apply|am|cherry-pick|merge|rebase|revert)\b'; then
    COMMIT_MODE_UNCERTAIN=true
  fi

  # v1.6.1 round-12 F1: alias-defined commit. `git -c alias.ci='commit -a' ci`
  # tokenises so the literal `commit` token never appears in argv (it's
  # a string inside the -c value). The token-walk loop below would
  # never fire and the consumer would fall back to PLAIN cached-only,
  # missing what the alias actually does. Fail closed UNCERTAIN
  # whenever a -c alias.X= injection is present: matches_git_commit()
  # already handles routing such commands here, but classify can't see
  # past the alias body.
  if printf '%s' "$CMD" | grep -qE '\bgit[[:space:]]+-c[[:space:]]+alias\.[A-Za-z0-9_-]+='; then
    COMMIT_MODE_UNCERTAIN=true
  fi

  # v1.6.1 round-10 F1: shell redirect targets in the same compound
  # command. `printf x > tier1.go && git commit -am msg` mutates a
  # Tier 1 file before the commit; the redirect target must be added
  # to the candidate set so Tier 1 detection sees it.
  local _line
  while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    COMMIT_REDIRECT_TARGETS+=("$_line")
  done < <(printf '%s' "$_cmd_no_sq" \
            | grep -oE '>>?[[:space:]]*[^&[:space:]|;)]+' 2>/dev/null \
            | sed -E 's/^>>?[[:space:]]*//' \
            | grep -vE '^/dev/(null|stdout|stderr|tty|zero|random|urandom)$' \
            || true)

  # v1.6.1 round-15 F1: in-place editor targets. `sed -i 'script' file`,
  # `perl -i -pe 'script' file`, `gawk -i inplace -f script file`. The
  # editor mutates the target in place — if it's Tier 1 the round-11
  # deny on COMMIT_REDIRECT_TARGETS-matching-Tier-1 catches it. Split
  # by separators (so each editor segment is isolated), match the
  # editor pattern, take the LAST positional as the target. Conservative:
  # multi-file invocations only catch the last file; false positives
  # cost nothing since the round-11 Tier 1 regex check filters.
  local _ip_segment _ip_target
  while IFS= read -r _ip_segment || [[ -n "$_ip_segment" ]]; do
    [[ -z "$_ip_segment" ]] && continue
    if printf '%s' "$_ip_segment" \
         | grep -qE '\b(sed|perl|gawk|awk)[[:space:]][^|;&]*(-i|--in-place)'; then
      _ip_target="$(printf '%s' "$_ip_segment" | awk '{print $NF}')"
      [[ -n "$_ip_target" ]] && COMMIT_REDIRECT_TARGETS+=("$_ip_target")
    fi
  done < <(printf '%s\n' "$_cmd_no_sq" | tr ';|&\n' '\n')

  local _CMD_TOKENS=()
  local _line
  if command -v xargs >/dev/null 2>&1; then
    while IFS= read -r _line; do
      _CMD_TOKENS+=("$_line")
    done < <(printf '%s' "$CMD" | xargs -n1 printf '%s\n' 2>/dev/null)
  fi
  if [[ ${#_CMD_TOKENS[@]} -eq 0 ]]; then
    read -ra _CMD_TOKENS <<< "$CMD"
  fi

  local _expect_arg=false
  local _end_of_opts=false
  local _scanning=false
  local _tok _flag_body _last
  for _tok in "${_CMD_TOKENS[@]}"; do
    if [[ "$_scanning" != "true" ]]; then
      [[ "$_tok" == "commit" ]] && _scanning=true
      continue
    fi
    if [[ "$_end_of_opts" == "true" ]]; then
      # After `--`, every remaining non-empty token is a pathspec.
      # v1.6.1 round-4 F1: only flip to PATHSPEC mode when an actual
      # pathspec follows. Bare `git commit -m msg --` commits the
      # index only — must stay PLAIN so unrelated working-tree WIP
      # doesn't widen the candidate set.
      if [[ -n "$_tok" ]]; then
        COMMIT_MODE_PATHSPEC=true
        COMMIT_PATHSPECS+=("$_tok")
      fi
      continue
    fi
    if [[ "$_expect_arg" == "true" ]]; then
      _expect_arg=false
      continue
    fi
    case "$_tok" in
      # v1.6.1 round-4 F1: bare `--` only marks end-of-options; the
      # PATHSPEC flip happens above when (and only when) a real
      # pathspec actually follows.
      --) _end_of_opts=true ;;
      -a|--all|--all=*) COMMIT_MODE_ALL=true; break ;;
      # v1.6.1 round-3 F1: split --include/-i (additive) from
      # --only/-o (replacement). Interactive/patch modes stay PATHSPEC
      # because they select from working-tree, not from staged.
      --include|-i) COMMIT_MODE_INCLUDE=true; COMMIT_MODE_PATHSPEC=true ;;
      --only|-o|--interactive|--patch|-p) COMMIT_MODE_PATHSPEC=true ;;
      --pathspec-from-file=*) COMMIT_MODE_PATHSPEC=true ;;
      --pathspec-from-file) COMMIT_MODE_PATHSPEC=true; _expect_arg=true ;;
      --message|--file|--author|--date|--cleanup|--template|--squash|--fixup|--trailer|--reedit-message|--reuse-message|-m|-F|-c|-C)
        _expect_arg=true
        ;;
      -m*|-F*|-c*|-C*|-S*) ;;
      --gpg-sign|--gpg-sign=*) ;;
      --amend|--no-edit|--no-verify|--no-gpg-sign|--no-status|--no-post-rewrite|--no-template|--no-rerere-autoupdate|--no-allow-empty-message|--reset-author|--signoff|--no-signoff|--allow-empty|--allow-empty-message|--allow-empty-author|--quiet|--verbose|--dry-run|--short|--porcelain|--long|--status|--null|--no-edit-files|--branch) ;;
      --cleanup=*|--template=*|--trailer=*|--message=*|--file=*|--author=*|--date=*|--reedit-message=*|--reuse-message=*|--squash=*|--fixup=*) ;;
      --*) COMMIT_MODE_UNCERTAIN=true ;;
      -*)
        _flag_body="${_tok#-}"
        case "$_flag_body" in
          *a*) COMMIT_MODE_ALL=true; break ;;
        esac
        # v1.6.1 round-3 F1: cluster handler must mirror exact-match
        # case for `i` (--include) and `o` (--only). -m*/-F*/-c*/-C*/-S*
        # attached-arg patterns matched earlier so they don't reach here.
        case "$_flag_body" in
          *i*) COMMIT_MODE_INCLUDE=true; COMMIT_MODE_PATHSPEC=true ;;
        esac
        case "$_flag_body" in
          *o*|*p*) COMMIT_MODE_PATHSPEC=true ;;
        esac
        _last="${_flag_body: -1}"
        case "$_last" in
          m|F|c|C) _expect_arg=true ;;
        esac
        ;;
      *)
        # Positional arg. v1.6.1 round-2 F2: shell metacharacters
        # that escaped tokenization (subshell/brace/separator) flip
        # to UNCERTAIN. Otherwise it's a real pathspec; keep scanning
        # so subsequent flags and additional pathspecs are still
        # classified correctly (real git accepts pathspecs interleaved
        # with flags).
        case "$_tok" in
          \(*|\)*|\{*|\}*|\;*|\&*|\|*)
            COMMIT_MODE_UNCERTAIN=true
            _end_of_opts=true
            ;;
          *)
            COMMIT_MODE_PATHSPEC=true
            COMMIT_PATHSPECS+=("$_tok")
            ;;
        esac
        ;;
    esac
  done
}
