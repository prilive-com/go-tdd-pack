# Bugfix Plan: gate-level-no-verify-closure — close `git commit --no-verify` bypass via prepare-commit-msg

Status: active
Cycle ID: gate-level-no-verify-closure
Change type: enhancement (close known limit deferred from
                          gate-level-followup-pre-commit-hook)
Tier: 1

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

`scripts/git-hooks/pre-commit` (shipped in cycle gate-level-followup)
documents one known limit: `git commit --no-verify` (or `-n`) skips
ALL pre-commit hooks by git design. The deferred follow-up:

> Closing this requires moving to `prepare-commit-msg` (different
> semantics — can't reject, only mutate the message); architecturally
> larger than this cycle.

That spec text was wrong on one point. Per git's own documentation:

  "--no-verify" / "-n": "Bypasses the pre-commit and commit-msg hooks."

Notably absent from the bypass list: **prepare-commit-msg**. And per
githooks(5): "If [prepare-commit-msg] exits with a non-zero status,
the commit will be aborted." So prepare-commit-msg CAN reject — the
"can't reject" claim was wrong.

This cycle ships the prepare-commit-msg layer to close the
`--no-verify` bypass.

Concrete bypass surface today (with the pre-commit hook installed):

  git config alias.ci 'commit --no-verify'   # operator-configured
  git ci -m "skip the gate"                  # alias resolves to --no-verify
  # → pre-commit hook NOT invoked → Tier 1 commit lands without ceremony

  git commit -n -m msg                       # direct
  git commit --no-verify -m msg              # direct
  bash -c 'git commit --no-verify'           # wrapper still hits the
                                             # PreToolUse layer, but if it
                                             # passes (e.g., the operator
                                             # disabled guard-dangerous-bash),
                                             # pre-commit is skipped

## Reproduction

```
TMPDIR=$(mktemp -d) && cd $TMPDIR && git init -q
mkdir -p .tdd internal/auth scripts/git-hooks
cp /home/toha/go-projects-claude-starter/.tdd/tdd-config.json .tdd/
cp /home/toha/go-projects-claude-starter/scripts/git-hooks/pre-commit \
   scripts/git-hooks/
git config core.hooksPath scripts/git-hooks
echo "package auth" > internal/auth/handler.go
git add . && git config user.email t@t && git config user.name t && git commit -q -m initial

echo "// edit" >> internal/auth/handler.go
git add internal/auth/handler.go

# pre-commit fires → blocks (no plan)
git commit -m "tier1 no plan" 2>&1 | head -3
# Output: [git-pre-commit] BLOCKED ...

# But --no-verify skips pre-commit:
git commit --no-verify -m "tier1 bypass" 2>&1 | head -3
# Output: [main 1234567] tier1 bypass  ← BYPASS

# After this cycle: prepare-commit-msg also fires → blocks even with
# --no-verify.
```

## Acceptance criteria

1. `scripts/git-hooks/prepare-commit-msg` exists, has shebang, is
   executable.
2. The hook runs the SAME Tier 1 checks as `pre-commit` (delegate
   to pre-commit logic; don't duplicate).
3. The hook denies on the same conditions: missing plan, missing
   markers, missing/stale adjudication, hash mismatch (when flag on),
   malformed config.
4. The hook honors `enforcement_mode_overrides["git-prepare-commit-msg"]`
   if present, falling back to the global `enforcement_mode`. Same
   semantics as pre-commit (warn → stderr + allow; off → silent).
5. Killswitch `TDD_GIT_HOOK_DISABLE=1` ALSO disables prepare-commit-msg
   (one env var disables the entire git-side enforcement layer).
6. Hook receives 1-3 args from git ($1=message-file, $2=source,
   $3=commit-sha) — must IGNORE all args (Tier 1 check is independent
   of the message contents).
7. Update `scripts/git-hooks/pre-commit` header: replace the "KNOWN
   LIMITATION — git commit --no-verify" block with a "CLOSED IN
   FOLLOW-UP" note pointing to the prepare-commit-msg sibling.
8. Smoke tests:
   - prepare-commit-msg file exists and is executable
   - prepare-commit-msg denies on the same fixtures pre-commit denies
   - prepare-commit-msg allows on the same clean fixtures
   - prepare-commit-msg honors the killswitch
   - prepare-commit-msg honors enforcement_mode (warn/off)
   - Documentation updated in pre-commit header

## Non-goals

- Auto-install. Same operator-decision scope as pre-commit; install
  manually or via core.hooksPath.
- Coordinating output between pre-commit and prepare-commit-msg
  (they may both fire on a normal `git commit` without --no-verify;
  duplicate "BLOCKED" message is acceptable — defense in depth).
- Touching the post-rewrite or post-commit hooks. Out of scope.
- Fully closing the case where the operator removes the
  prepare-commit-msg hook from `.git/hooks/`. That's the operator's
  active opt-out; pack-side cannot prevent it.

## Affected code

- `scripts/git-hooks/prepare-commit-msg` — NEW (thin wrapper)
- `scripts/git-hooks/pre-commit` — header updated (KNOWN LIMIT →
  CLOSED IN FOLLOW-UP)
- `scripts/tdd-test-hooks.sh` — new smoke tests

## Test plan

| Test name | Pins criterion # |
|---|---|
| nv_prepare_commit_msg_exists_and_executable | 1 |
| nv_prepare_commit_msg_denies_no_plan | 3 |
| nv_prepare_commit_msg_denies_missing_marker | 3 |
| nv_prepare_commit_msg_denies_missing_adjudication | 3 |
| nv_prepare_commit_msg_allows_clean_state | regression |
| nv_prepare_commit_msg_honors_killswitch | 5 |
| nv_prepare_commit_msg_honors_warn_mode | 4 |
| nv_prepare_commit_msg_ignores_args | 6 |
| nv_pre_commit_header_updated | 7 |

## Minimum implementation

Thin wrapper that delegates to pre-commit (one file, one logic;
zero drift surface):

```bash
#!/usr/bin/env bash
# scripts/git-hooks/prepare-commit-msg
#
# Runs the SAME Tier 1 commit gate as pre-commit, but unlike
# pre-commit this hook IS NOT skipped by `git commit --no-verify`
# (per git docs / githooks(5) — --no-verify only bypasses pre-commit
# and commit-msg). Closes the `--no-verify` bypass deferred from
# cycle gate-level-followup-pre-commit-hook.
#
# This is a thin wrapper that delegates to pre-commit's check logic.
# Args from git ($1=message-file, $2=source, $3=commit-sha) are
# ignored — Tier 1 enforcement is independent of message contents.
#
# Installation, killswitch, and config: see pre-commit's header.

exec "$(dirname "$0")/pre-commit" "$@"
```

The pre-commit script itself doesn't reference its own args
(`set -uo pipefail` doesn't trip on extra args); passing them through
is harmless and future-proof if pre-commit ever wants to inspect
them.

## Risk register

| Risk | Mitigation |
|---|---|
| prepare-commit-msg fires even when commit will fail later (e.g., empty staged set after merge resolution) | The hook returns 0 early when no Tier 1 staged. Same path as pre-commit; no extra cost. |
| Both pre-commit AND prepare-commit-msg fire on a normal commit, double-output | Acceptable. Both produce "BLOCKED" messages with the same content. Defense in depth; operators see the message once and act on it. |
| Operator installs pre-commit but forgets prepare-commit-msg | Both are required to close the --no-verify bypass. core.hooksPath = scripts/git-hooks/ activates BOTH. Manual cp install needs both files; documented in headers. |
| Wrapper invocation overhead per commit | A `bash exec` is microseconds. The actual gate logic is the cost; that runs once either way. |
| Future change to pre-commit's expected env vars / arg handling breaks the wrapper | Both files are in the same directory and committed together; review process catches drift. Smoke test asserts wrapper still produces same exit code on shared fixtures. |
