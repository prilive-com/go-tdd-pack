# Bugfix Plan: gate-level-install-and-docs — install script + AGENTS.md/CLAUDE.md updates for git-side hooks

Status: active
Cycle ID: gate-level-install-and-docs
Change type: enhancement (operator ergonomics + discoverability;
                          deferred from gate-level-followup cycle)
Tier: 1 (touches scripts + AGENTS/CLAUDE.md)

<!-- TDD ceremony markers. Set each ONLY after the matching operator APPROVED reply. -->
Bug reproduced: yes
Human approved spec: yes
Red phase confirmed: yes
Green phase authorized: yes
Implementation reviewed: yes
Fix applied: yes
Regression tests added: yes
Bug-elsewhere check complete: yes

## Bug

`scripts/git-hooks/{pre-commit,prepare-commit-msg}` ship in the pack
but operators install them by hand per the header docs. Two real
gaps:

  1. **Install friction.** Operators have to read each hook's header,
     run `cp` + `chmod` + verify, OR set `git config core.hooksPath`
     manually. Easy to install pre-commit and forget prepare-commit-
     msg — which silently re-opens the `--no-verify` bypass closed
     last cycle.

  2. **Discoverability.** AGENTS.md and CLAUDE.md don't mention the
     git-side hook layer at all. Operators reading "Operator config
     & killswitches" learn about enforcement_mode, hash binding, and
     killswitch env vars but have no idea the git-side enforcement
     exists or what it adds.

The previous cycle (gate-level-followup) explicitly deferred both
items as part of the operator's smaller-scope decision. This cycle
ships them.

## Reproduction

```
$ ls scripts/install-git-hooks.sh 2>&1
ls: cannot access 'scripts/install-git-hooks.sh': No such file or directory

$ grep -c "git-hooks\|pre-commit\|prepare-commit-msg" AGENTS.md CLAUDE.md
AGENTS.md:0
CLAUDE.md:0
```

Confirmed absent from both surfaces.

## Acceptance criteria

### Install script

1. `scripts/install-git-hooks.sh` exists, has shebang, is executable.
2. Default mode (no flags) copies BOTH `pre-commit` and
   `prepare-commit-msg` from `scripts/git-hooks/` to `.git/hooks/`,
   chmod +x, prints what it did.
3. Idempotent: re-running on an already-installed repo verifies the
   files are byte-identical and reports "already installed" without
   writing.
4. Refuses to overwrite `.git/hooks/pre-commit` or
   `.git/hooks/prepare-commit-msg` if it exists with DIFFERENT
   content (not from this pack). Prints a clear message + the diff
   command operator should run.
5. `--symlink` flag: symlink instead of copy (future pack updates
   apply automatically).
6. `--hookspath` flag: sets `git config core.hooksPath scripts/git-hooks`
   instead of touching `.git/hooks/`. Refuses if `core.hooksPath`
   is already set to a different path.
7. `--uninstall` flag: removes both hooks from `.git/hooks/`. Only
   removes files that are byte-identical to the pack version OR are
   symlinks pointing to the pack version (refuses to delete operator's
   custom hooks).
8. Works from any cwd inside the repo (uses `git rev-parse
   --show-toplevel`); fails with a clear message outside a git repo.
9. Fails cleanly if either source hook is missing in `scripts/git-hooks/`.
10. Fails cleanly on bare repo / unsupported worktree layout.

### Documentation

11. AGENTS.md "Operator config & killswitches" section gains a new
    sub-section "Git-side enforcement (optional second layer)"
    documenting the two hooks, what they catch, the
    `TDD_GIT_HOOK_DISABLE` killswitch, and the install command.
12. CLAUDE.md gets the same sub-section (parity).

### Tests

13. Smoke tests cover: install/idempotent/refuse-overwrite/uninstall/
    symlink/--hookspath/non-git-dir fail/source-missing fail.
14. AGENTS.md + CLAUDE.md mention `scripts/install-git-hooks.sh` AND
    both hook names.

## Non-goals

- Cross-platform installer (Windows). bash + git assumed.
- Auto-detecting third-party hook managers (lefthook/husky/pre-commit)
  and integrating with them. Operators using those wire the hook
  manually per their tool's conventions.
- Auto-running on `make install` or as a setup step. Install is
  explicitly opt-in.
- A separate uninstall confirmation prompt. The script is destructive
  by design when `--uninstall` is passed; operator owns the choice.

## Affected code

- `scripts/install-git-hooks.sh` — NEW
- `AGENTS.md` — new "Git-side enforcement" sub-section
- `CLAUDE.md` — same (parity)
- `scripts/tdd-test-hooks.sh` — new smoke tests

## Test plan

| Test name | Pins criterion # |
|---|---|
| install_script_exists_and_executable | 1 |
| install_default_copies_both_hooks | 2 |
| install_idempotent_on_pack_content | 3 |
| install_refuses_overwrite_of_custom_hook | 4 |
| install_symlink_mode | 5 |
| install_hookspath_mode | 6 |
| install_uninstall_removes_pack_hooks | 7 |
| install_uninstall_preserves_custom_hooks | 7 |
| install_fails_outside_git_repo | 8 |
| install_fails_on_missing_source | 9 |
| docs_agents_md_mentions_install_script | 14 |
| docs_agents_md_mentions_both_hook_names | 14 |
| docs_claude_md_mentions_install_script | 14 |
| docs_claude_md_mentions_both_hook_names | 14 |

## Minimum implementation

### `scripts/install-git-hooks.sh`

```bash
#!/usr/bin/env bash
# Install scripts/git-hooks/{pre-commit,prepare-commit-msg} into the
# current repo's .git/hooks/. Default: copy. Flags:
#   --symlink     Symlink instead of copy (auto-update on pack changes)
#   --hookspath   Set core.hooksPath instead of touching .git/hooks
#   --uninstall   Remove pack-installed hooks (preserves custom hooks)
#   -h, --help    Show usage

set -uo pipefail

usage() {
  cat <<USG
usage: scripts/install-git-hooks.sh [--symlink|--hookspath|--uninstall|-h]

  Default     cp + chmod +x for pre-commit and prepare-commit-msg
  --symlink   symlink to scripts/git-hooks/<hook> (auto-update)
  --hookspath set core.hooksPath scripts/git-hooks (covers entire dir)
  --uninstall remove pack-installed hooks (refuses to remove custom)
USG
}

# ... (install / refuse-overwrite / idempotent / uninstall logic)
```

### AGENTS.md / CLAUDE.md addition

In "Operator config & killswitches", add:

```markdown
### Git-side enforcement (optional second layer)

The pack also ships `scripts/git-hooks/{pre-commit,prepare-commit-msg}`
that run inside git itself. They mirror the PreToolUse Tier 1 commit
gate but execute AFTER shell expansion / aliasing / wrapping, closing
bypass classes the PreToolUse layer can't see (sh -c, transparent-exec
prefixes, aliases, --no-verify, interpreter wrappers).

Install (opt-in):
  bash scripts/install-git-hooks.sh             # default: copy
  bash scripts/install-git-hooks.sh --symlink   # symlink for auto-update
  bash scripts/install-git-hooks.sh --hookspath # set core.hooksPath
  bash scripts/install-git-hooks.sh --uninstall # reverse

Both hooks must be installed to close the `--no-verify` bypass.
Killswitch (env var, emergency only): `TDD_GIT_HOOK_DISABLE=1`.
```

## Risk register

| Risk | Mitigation |
|---|---|
| Install script overwrites operator's custom pre-commit | AC 4: refuse + clear diff command. Operator must move/back up first. |
| Operator runs --uninstall and it removes their custom hook | AC 7: only removes byte-identical or symlink-to-pack files. |
| --hookspath disables operator's existing hooks | Header warns; confirms before setting if `core.hooksPath` already configured to non-empty. |
| AGENTS.md / CLAUDE.md drift | Tests assert presence of install command + both hook names in BOTH files. |
| Install script's "byte-identical" check breaks if pack updates the hook | Idempotent flag detects diff and re-installs (default copy mode); symlink mode auto-updates by construction. Acceptable: re-running install is the documented update path. |
| Operator on a worktree (where .git is a file) | git rev-parse --git-path hooks resolves correctly; install to that resolved path. |
