# Bugfix Plan: gate-level-bypass-closure — broaden COMMITS_RE for shell wrappers + inline aliases

Status: active
Cycle ID: gate-level-bypass-closure
Change type: bugfix
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

Layer 0 size threshold and Tier 1 ceremony checks in
`gate-tier1-commit.sh` are bypassed because `COMMITS_RE` only matches
literal `git commit` at command start (or after a shell separator).
Two known forms slip through:

```
sh -c 'git commit -a -m msg'                  # outer is `sh -c`
git -c alias.ci='commit -a' ci -m msg          # outer is `git -c`
```

Origin: Codex round 8 P0 finding from the Layer-0-rescue cycle. The
parser fixes shipped in 278d268 close all parser-level bypasses for
literal `git commit ...` invocations, but leave these gate-level
bypasses open.

## Reproduction

With the buggy HEAD code, `sh -c 'git commit -a'` exits 0 silently
even when staged Tier 1 file + no plan should deny:

```
TMPDIR=$(mktemp -d) && git init "$TMPDIR" ...
cp .tdd/tdd-config.json "$TMPDIR/.tdd/"
echo "package auth" > "$TMPDIR/internal/auth/handler.go"
git add . && git commit -m initial
echo "// edit" >> "$TMPDIR/internal/auth/handler.go"
git add internal/auth/handler.go

# Bypass form — no plan, Tier 1 staged. Expected: deny.
echo '{"tool_input":{"command":"sh -c \"git commit -a -m sneaky\""}}' \
  | CLAUDE_PROJECT_DIR=$TMPDIR bash .claude/hooks/gate-tier1-commit.sh
# Actual: exit 0 silently (gate didn't fire)
```

## Acceptance criteria

1. `sh -c 'git commit -a'` triggers gate (currently bypasses)
2. `bash -c`, `zsh -c`, `dash -c`, `ksh -c`, `eval` wrappers all trigger
3. `git -c alias.ci='commit -a' ci` triggers when alias value contains `commit`
4. Negative: `echo "git commit -m foo"` does NOT trigger (commit-as-string)
5. Negative: `git log --grep="git commit"` does NOT trigger (grep arg)
6. Negative: `cat file | grep "git commit"` does NOT trigger (pipe arg)
7. Existing direct `git commit` matching unchanged — 150 baseline tests pass
8. New smoke tests cover positive (1-3) and negative (4-6) cases

## Non-goals

- Pre-configured user aliases from `.gitconfig` (`git ci -m msg` where
  `ci` is operator-defined). Detection requires `git config --get
  alias.<word>` per hook invocation; real but rare in threat model
  (operator-configured, not Claude-injected). Document as known
  limitation; defer to follow-up cycle.
- Wrappers that read commands from files (`bash some-script.sh` where
  the script contains `git commit`). We don't read script files.
- `python -c '...'` or other interpreters that could shell-out. Same
  as above — too broad to scan.

## Affected code

- `.claude/hooks/gate-tier1-commit.sh` lines 82-85 — replace single
  COMMITS_RE with a function that checks multiple invocation patterns
- `scripts/tdd-test-hooks.sh` — ~10 new smoke tests

## Test plan

| Test name | Pins criterion # |
|---|---|
| gate_sh_c_wrapper_triggers | 1 |
| gate_bash_c_wrapper_triggers | 2 |
| gate_zsh_c_wrapper_triggers | 2 |
| gate_eval_wrapper_triggers | 2 |
| gate_inline_alias_injection_triggers | 3 |
| gate_inline_alias_without_commit_does_not_trigger | 4 |
| gate_echo_commit_string_does_not_trigger | 4 |
| gate_grep_commit_string_does_not_trigger | 5 |
| gate_pipe_grep_commit_does_not_trigger | 6 |
| gate_existing_direct_commit_still_triggers | 7 |

## Risk register

| Risk | Mitigation |
|---|---|
| New patterns produce false positives in legitimate workflows | Keep wrapper detection narrow: must match the wrapper form AND contain `git commit` substring. Tests 4-6 guard. |
| `git -c alias.X=commit X` regex too narrow; misses URL-encoded or quoted variants | Stick to common shell-quoting forms; document edge cases. |
| `eval` matching might catch unrelated `eval $(...)` shell setup | The eval branch requires `git commit` substring after eval; legitimate shell setup eval doesn't typically contain `git commit`. |
