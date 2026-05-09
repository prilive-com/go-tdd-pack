#!/usr/bin/env bash
# scripts/install-git-hooks.sh
#
# Install scripts/git-hooks/{pre-commit,prepare-commit-msg} into the
# current repo's .git/hooks/. Both must be active to close the
# `git commit --no-verify` bypass (per cycle gate-level-no-verify-
# closure). Default: copy. Other modes via flags below.

# Codex round 1 P1 #4: include `-e` so cp/chmod/ln/git mutation failures
# (permissions, locks, etc.) propagate as non-zero exit instead of being
# masked by trailing success messages.
set -euo pipefail

usage() {
  cat <<'USG'
usage: bash scripts/install-git-hooks.sh [MODE]

Modes (mutually exclusive):
  (none)       cp + chmod +x for both hooks (default)
  --symlink    symlink each hook to the pack source (auto-update on
               pack changes; survives `git pull`)
  --hookspath  set core.hooksPath = scripts/git-hooks (covers entire
               directory; future hooks added to the dir become active
               automatically)
  --uninstall  remove pack-installed hooks. Only removes files that
               are byte-identical to the pack version OR symlinks
               pointing to it; refuses to delete operator's custom
               hooks.
  -h, --help   show this message

Notes
  - Run from anywhere inside the repo. Resolves repo root via
    `git rev-parse --show-toplevel`.
  - Refuses to overwrite an existing custom (non-pack) hook —
    operator must move/back up first.
  - Killswitch (env var, emergency only): TDD_GIT_HOOK_DISABLE=1
USG
}

MODE="copy"
case "${1:-}" in
  --symlink)   MODE="symlink" ;;
  --hookspath) MODE="hookspath" ;;
  --uninstall) MODE="uninstall" ;;
  -h|--help)   usage; exit 0 ;;
  "")          MODE="copy" ;;
  *)
    echo "[install-git-hooks] unknown flag: $1" >&2
    usage >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/git-hooks"

# Validate we're in a git repo.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[install-git-hooks] not inside a git work tree (cwd: $(pwd))" >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "$REPO_ROOT" ]]; then
  echo "[install-git-hooks] could not resolve repo root" >&2
  exit 1
fi

# Hooks dir resolution: respect existing core.hooksPath if set.
# Codex round 1 P1 #1: `git rev-parse --git-path hooks` can return a
# relative path; resolve against $REPO_ROOT so installing from a
# subdirectory doesn't create `<cwd>/.git/hooks/...`.
DEFAULT_HOOKS_DIR="$(cd "$REPO_ROOT" && git rev-parse --git-path hooks 2>/dev/null || true)"
if [[ -z "$DEFAULT_HOOKS_DIR" ]]; then
  DEFAULT_HOOKS_DIR="$REPO_ROOT/.git/hooks"
elif [[ "$DEFAULT_HOOKS_DIR" != /* ]]; then
  DEFAULT_HOOKS_DIR="$REPO_ROOT/$DEFAULT_HOOKS_DIR"
fi

HOOK_NAMES=(pre-commit prepare-commit-msg)

# Pre-flight: source files must exist (validates the pack).
for h in "${HOOK_NAMES[@]}"; do
  if [[ ! -f "$SOURCE_DIR/$h" ]]; then
    echo "[install-git-hooks] source hook missing: $SOURCE_DIR/$h" >&2
    echo "[install-git-hooks] did you run from a checkout that includes scripts/git-hooks/?" >&2
    exit 1
  fi
done

# is_pack_installed <target>
# Returns 0 if the target file is byte-identical to its pack source
# OR is a symlink resolving to the pack source.
# Codex round 1 P2: check `-L` BEFORE `-e` so dangling symlinks (which
# `-e` reports as absent) are still recognised as existing targets.
is_pack_installed() {
  local name target src
  name="$(basename "$1")"
  target="$1"
  src="$SOURCE_DIR/$name"
  if [[ ! -e "$target" ]] && [[ ! -L "$target" ]]; then
    return 1
  fi
  if [[ -L "$target" ]]; then
    local resolved
    resolved="$(readlink -f "$target" 2>/dev/null || readlink "$target" 2>/dev/null || true)"
    [[ -z "$resolved" ]] && return 1
    [[ "$resolved" == "$src" ]] && return 0
    [[ "$resolved" == "$(readlink -f "$src" 2>/dev/null || echo "$src")" ]] && return 0
    return 1
  fi
  cmp -s "$target" "$src"
}

# target_exists_for_overwrite_check <target>
# True if the target is a regular file OR ANY symlink (including
# dangling). Used by overwrite-refusal logic so a dangling custom
# symlink isn't silently replaced. Codex round 1 P2.
target_exists_for_overwrite_check() {
  [[ -e "$1" ]] || [[ -L "$1" ]]
}

case "$MODE" in
  copy)
    mkdir -p "$DEFAULT_HOOKS_DIR"
    installed=0; skipped=0; restored=0
    for h in "${HOOK_NAMES[@]}"; do
      tgt="$DEFAULT_HOOKS_DIR/$h"
      src="$SOURCE_DIR/$h"
      if target_exists_for_overwrite_check "$tgt" && ! is_pack_installed "$tgt"; then
        echo "[install-git-hooks] REFUSED: $tgt exists with non-pack content." >&2
        echo "  inspect:  diff -u '$src' '$tgt'" >&2
        echo "  resolve:  back up $tgt, remove it, then re-run this script." >&2
        exit 1
      fi
      if is_pack_installed "$tgt"; then
        # Codex round 1 P1 #2: ensure the executable bit is still set.
        # Operator may have chmod-d it off; restore it without rewriting
        # the file so re-install is still meaningfully idempotent.
        if [[ ! -L "$tgt" ]] && [[ ! -x "$tgt" ]]; then
          chmod +x "$tgt"
          echo "[install-git-hooks] restored +x on $tgt"
          restored=$((restored + 1))
        else
          echo "[install-git-hooks] $h already installed (identical to pack)"
          skipped=$((skipped + 1))
        fi
      else
        cp "$src" "$tgt"
        chmod +x "$tgt"
        echo "[install-git-hooks] installed $tgt"
        installed=$((installed + 1))
      fi
    done
    echo "[install-git-hooks] done. installed=$installed restored=$restored skipped=$skipped"
    ;;

  symlink)
    mkdir -p "$DEFAULT_HOOKS_DIR"
    for h in "${HOOK_NAMES[@]}"; do
      tgt="$DEFAULT_HOOKS_DIR/$h"
      src="$SOURCE_DIR/$h"
      if target_exists_for_overwrite_check "$tgt" && ! is_pack_installed "$tgt"; then
        echo "[install-git-hooks] REFUSED: $tgt exists with non-pack content." >&2
        echo "  inspect:  diff -u '$src' '$tgt'  (or readlink for symlinks)" >&2
        echo "  resolve:  back up $tgt, remove it, then re-run this script." >&2
        exit 1
      fi
      ln -sf "$src" "$tgt"
      echo "[install-git-hooks] symlinked $tgt -> $src"
    done
    ;;

  hookspath)
    rel_path="$(realpath --relative-to="$REPO_ROOT" "$SOURCE_DIR" 2>/dev/null || echo "scripts/git-hooks")"
    existing="$(git -C "$REPO_ROOT" config --get core.hooksPath 2>/dev/null || true)"
    if [[ -n "$existing" ]] && [[ "$existing" != "$rel_path" ]]; then
      echo "[install-git-hooks] REFUSED: core.hooksPath is already set to '$existing'." >&2
      echo "  This would override your existing setting. To proceed:" >&2
      echo "    git config --unset core.hooksPath  &&  bash $0 --hookspath" >&2
      exit 1
    fi
    git -C "$REPO_ROOT" config core.hooksPath "$rel_path"
    echo "[install-git-hooks] set core.hooksPath = $rel_path"
    echo "[install-git-hooks] both hooks now active automatically (no .git/hooks/ files needed)"
    ;;

  uninstall)
    removed=0; preserved=0; hookspath_unset=false
    for h in "${HOOK_NAMES[@]}"; do
      tgt="$DEFAULT_HOOKS_DIR/$h"
      if [[ ! -e "$tgt" ]] && [[ ! -L "$tgt" ]]; then
        continue
      fi
      if is_pack_installed "$tgt"; then
        rm -f "$tgt"
        echo "[install-git-hooks] removed $tgt"
        removed=$((removed + 1))
      else
        echo "[install-git-hooks] PRESERVED $tgt (custom hook; not removing)" >&2
        preserved=$((preserved + 1))
      fi
    done
    # Codex round 1 P1 #3: --uninstall must also reverse --hookspath.
    # If core.hooksPath points at our pack source, unset it so the
    # operator's repo returns to the default .git/hooks/.
    existing_hookspath="$(git -C "$REPO_ROOT" config --get core.hooksPath 2>/dev/null || true)"
    if [[ -n "$existing_hookspath" ]]; then
      # Resolve the configured path relative to repo root, then compare
      # to our pack source dir.
      resolved_hookspath="$existing_hookspath"
      [[ "$resolved_hookspath" != /* ]] && resolved_hookspath="$REPO_ROOT/$existing_hookspath"
      if [[ "$(cd "$resolved_hookspath" 2>/dev/null && pwd)" == "$SOURCE_DIR" ]]; then
        git -C "$REPO_ROOT" config --unset core.hooksPath
        echo "[install-git-hooks] unset core.hooksPath (was '$existing_hookspath' → pack dir)"
        hookspath_unset=true
      fi
    fi
    echo "[install-git-hooks] uninstall done. removed=$removed preserved=$preserved hookspath_unset=$hookspath_unset"
    ;;
esac
