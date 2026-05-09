# Bugfix Plan: gate-level-followup-pre-commit-hook — close R5 bypass class via git pre-commit

Status: active
Cycle ID: gate-level-followup-pre-commit-hook
Change type: enhancement (architectural — close deferred bypass class)
Tier: 1 (new gate-relevant script; not in tier1_path_regexes today
       but functionally equivalent to gate-tier1-commit.sh)

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

The `gate-tier1-commit.sh` PreToolUse hook can only see the literal
command text Claude is about to run; it cannot observe what the
shell will actually execute after expansion / aliasing / wrapping.
Documented bypass classes (R5 from cycle gate-level-bypass-closure):

  - `sh -c 'git commit -a'` — outer command is `sh -c`
  - `bash -c '...'`, `zsh -c`, `dash -c`, `eval '...'`
  - `time bash -c '...'`, `sudo bash -c`, `nice bash -c`,
    `env FOO=1 bash -c`, `nohup bash -c` (transparent-exec prefixes)
  - `xargs git commit`, `find -exec git commit \;`
  - `(git commit -m x)`, `{ git commit -m x; }` (compact metachars
    without spaces)
  - `git ci -m x` (operator-configured alias from .gitconfig)
  - `python -c "import os; os.system('git commit')"`,
    `perl -e '...'` (interpreter wrappers)
  - Future git global opts before `commit` not yet enumerated

All deferred to "follow-up cycle" with a documented architectural
recommendation: pivot to a git pre-commit hook (which runs INSIDE
git after all shell work is done — it sees the actual staged set
and the actual commit candidate, regardless of how git was invoked).

This cycle ships the architectural follow-up at minimum scope.

## Reproduction

```
TMPDIR=$(mktemp -d) && cd $TMPDIR && git init -q
mkdir -p .tdd internal/auth
cp /home/toha/go-projects-claude-starter/.tdd/tdd-config.json .tdd/
echo "package auth" > internal/auth/handler.go
git add . && git config user.email t@t && git config user.name t && git commit -q -m initial
echo "// edit" >> internal/auth/handler.go
git add internal/auth/handler.go

# All of the following SHOULD trip a Tier 1 commit gate but the
# PreToolUse hook can't see through the wrapper. There's currently
# no second-line defense.
echo '{"tool_input":{"command":"sh -c \"git commit -m sneaky\""}}' \
  | bash $PROJECT_ROOT/.claude/hooks/gate-tier1-commit.sh
# → fires. (gate-tier1-commit was hardened in the gate-level cycle.)

# But the deferred-R5 forms still slip:
echo '{"tool_input":{"command":"time bash -c \"git commit -m timed\""}}' \
  | bash $PROJECT_ROOT/.claude/hooks/gate-tier1-commit.sh
# → does NOT fire (time prefix not recognized as a wrapper)
```

A git pre-commit hook closes ALL of these classes by construction —
git invokes the hook with the actual commit context, regardless of
shell wrapping/aliasing.

## Acceptance criteria

1. `scripts/git-hooks/pre-commit` exists, has shebang, is executable
   (CI verifies the executable bit).
2. The hook reads `.tdd/tdd-config.json` and computes `tier1_path_regexes`
   matches against `git diff --cached --name-only`. If no Tier 1
   files are staged → exit 0 (allow).
3. If Tier 1 files are staged AND `.tdd/current-plan.md` is missing
   OR missing required markers (M1+M2+M3 by default; configurable
   via `required_markers_edit_time`) → exit 1 with stderr message.
4. If Tier 1 files are staged AND `.tdd/second-opinion-completed.md`
   is missing OR stale (>60min) → exit 1 with stderr message.
5. If `second_opinion.require_hash_binding_tier1: true` AND any
   Tier 1 file is staged AND recorded `diff_sha256` or `plan_sha256`
   doesn't match current → exit 1 with stderr message. Same
   format/semantics as `require-second-opinion.sh`.
6. Hook honors `enforcement_mode` (per F6) for the per-hook key
   `git-pre-commit`:
   - `strict` (default) → original deny + exit 1
   - `warn` → stderr advisory + exit 0
   - `off` → silent passthrough exit 0
7. Killswitch: `TDD_GIT_HOOK_DISABLE=1` env var → exit 0 silent.
8. Hook is INSTALLATION-OPTIONAL. Header comment documents three
   install paths:
     a. `cp scripts/git-hooks/pre-commit .git/hooks/ && chmod +x ...`
     b. `git config core.hooksPath scripts/git-hooks` (sets the
        whole dir; warns about overriding existing hooks)
     c. Use a third-party hook manager (lefthook, husky, pre-commit)
9. Hook fail-closed on malformed `.tdd/tdd-config.json` (same pattern
   as require-tdd-state.sh — F6 R2): deny with parse-error message.
10. Smoke tests verify all of the above by invoking the hook in
    isolated git fixtures (mimics what git would do).

## Non-goals

- Auto-install. Operators run the install command from the header
  comment. Smaller scope per operator decision.
- Updating AGENTS.md / CLAUDE.md. Documentation lives in the hook
  header for now; AGENTS.md update is a separate cycle.
- Replacing `gate-tier1-commit.sh`. The PreToolUse hook STAYS as
  defense-in-depth (fast-path; visible feedback to Claude before
  it runs git). The git pre-commit is the second line.
- Coordinating between the two hooks (sharing audit logs, etc.).
  Each runs independently; double-firing on the same commit is fine.
- Cross-platform packaging (Windows, etc.). bash + git assumed.

## Affected code

- `scripts/git-hooks/pre-commit` — NEW
- `scripts/tdd-test-hooks.sh` — new smoke tests

## Test plan

| Test name | Pins criterion # |
|---|---|
| gh_pre_commit_file_exists_and_executable | 1 |
| gh_pre_commit_no_tier1_staged_allows | 2 |
| gh_pre_commit_tier1_no_plan_denies | 3 |
| gh_pre_commit_tier1_missing_marker_denies | 3 |
| gh_pre_commit_tier1_no_adjudication_denies | 4 |
| gh_pre_commit_tier1_stale_adjudication_denies | 4 |
| gh_pre_commit_hash_mismatch_denies | 5 |
| gh_pre_commit_warn_mode_allows_with_stderr | 6 |
| gh_pre_commit_off_mode_silent_pass | 6 |
| gh_pre_commit_killswitch_allows | 7 |
| gh_pre_commit_header_documents_install | 8 |
| gh_pre_commit_malformed_config_denies | 9 |
| gh_pre_commit_clean_state_allows | regression |
| gh_pre_commit_closes_sh_c_bypass_via_install | 9 (proves the architectural claim) |

## Minimum implementation

```bash
#!/usr/bin/env bash
# scripts/git-hooks/pre-commit
# Tier 1 commit gate at git's commit-time layer.
#
# Why this exists: the .claude/hooks/gate-tier1-commit.sh PreToolUse
# hook can only see the literal command text Claude is about to run;
# it can't observe what the shell will execute after expansion /
# aliasing / wrapping. This git pre-commit runs INSIDE git after
# that work is done — it sees the actual staged set and the actual
# commit candidate, regardless of how git was invoked.
#
# Closes the "transparent-exec wrapper / alias / interpreter" bypass
# class deferred from cycle gate-level-bypass-closure (R5 P0/P1
# findings).
#
# INSTALLATION (operator action required; this hook is opt-in):
#   Option A — copy to .git/hooks/pre-commit:
#     cp scripts/git-hooks/pre-commit .git/hooks/pre-commit
#     chmod +x .git/hooks/pre-commit
#   Option B — point git at scripts/git-hooks via core.hooksPath:
#     git config core.hooksPath scripts/git-hooks
#     (warning: this DISABLES any existing .git/hooks/pre-commit)
#   Option C — third-party hook manager (lefthook, husky, pre-commit):
#     wire your manager to invoke scripts/git-hooks/pre-commit
#
# KILLSWITCH (emergency; document in commit message if used):
#   TDD_GIT_HOOK_DISABLE=1 git commit ...

set -uo pipefail

[[ "${TDD_GIT_HOOK_DISABLE:-0}" == "1" ]] && exit 0

# ... (full implementation modeled on gate-tier1-commit.sh's checks)
```

The hook re-uses the SAME logic as `gate-tier1-commit.sh` (Tier 1
detection, plan markers, adjudication, hash binding, enforcement_mode)
but its INPUT is git's pre-commit context (no JSON; staged diff is
authoritative) instead of PreToolUse JSON.

## Risk register

| Risk | Mitigation |
|---|---|
| Operator doesn't install the hook → no second-line defense | Documented in hook header; operator decision. PreToolUse hook stays as first line. |
| Hook duplicates gate-tier1-commit.sh logic; drift risk | Same risk as F13 closed for trivial_paths. Document the coupling and add a smoke test that asserts both hooks behave the same on the same fixture (or accept the drift since the inputs differ). |
| Setting `core.hooksPath` overrides existing local pre-commit hooks operator has set up | Header explicitly warns about this. Option A (copy) is safer for shared installs. |
| `git diff --cached --name-only` can return paths the hook doesn't expect (renames, mode-only, deletions) | Existing `gate-tier1-commit.sh` handles these; new hook reuses the same handling. |
| The new hook runs on EVERY commit (not just Claude's) | Yes — that's the point. This is the git-side enforcement. Operators who want Claude-only enforcement uninstall the git pre-commit and rely on the PreToolUse hook. |
| Tests can't verify "real git pre-commit" because git doesn't pass JSON | Tests invoke the script directly with the same env (cwd in repo, staged set present); identical to what git does. |
