# Bugfix Plan: f7-pipefail-substring-bypass — tighten pipefail detection regex

Status: active
Cycle ID: f7-pipefail-substring-bypass
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

F7 from the v1.6.x review: `guard-bash-pipefail.sh` line 30's
"pipefail is set" detection regex has two bypass classes.

```bash
! echo "$cmd" | grep -qE 'set[[:space:]]+-o[[:space:]]+pipefail|set[[:space:]]+-[a-zA-Z]*o[a-zA-Z]*[[:space:]]|pipefail|bash[[:space:]]+-o[[:space:]]+pipefail'
```

**Bypass A** — bare `pipefail` substring (third alternation):
matches the literal word `pipefail` ANYWHERE in the command, even
when it's part of a path, a grep argument, or a comment. Anyone can
silence the gate by mentioning the word.

```
go build ./pipefail/... 2>&1 | head -10
go test ./... 2>&1 | grep pipefail
echo "remember pipefail"; go build ./... | head
```

All three currently exit 0 silently — the gate doesn't fire.

**Bypass B** — `set -o <option>` regex too loose:
the second alternation `set[[:space:]]+-[a-zA-Z]*o[a-zA-Z]*[[:space:]]`
requires the cluster to end with whitespace but does NOT verify that
`pipefail` follows. So `set -o errexit` (a different option) or
`set -e` (which the regex allows because the cluster pattern can be
empty around 'o') would silence the gate.

```
set -o errexit; go build ./... | head -10
```

Currently exits 0 silently.

## Reproduction

Direct reproduction (verified):

```
echo '{"tool_input":{"command":"go build ./pipefail/... 2>&1 | head -10"}}' \
  | bash .claude/hooks/guard-bash-pipefail.sh
echo "exit: $?"
# Expected: deny + exit 2 (gate fires)
# Actual:   exit 0 silently (bypass)
```

## Acceptance criteria

1. `go build ./pipefail/... 2>&1 | head -10` (pipefail as path) → DENY
2. `go test ./... 2>&1 | grep pipefail` (pipefail in grep arg) → DENY
3. `echo "remember pipefail"; go build ./... | head` (in echo) → DENY
4. `set -o errexit; go build ./... | head` (different `-o` option) → DENY
5. `set -o pipefail; go build ./... | head` → ALLOW (regression preserved)
6. `set -eo pipefail; go build ./... | head` (cluster) → ALLOW
7. `bash -c 'set -o pipefail; go build ./... | head'` → ALLOW (in payload)
8. `bash -o pipefail -c 'go build ./... | head'` → ALLOW (bash flag)
9. `go build ./... | head -10` (no pipefail mentioned) → DENY (regression)

## Non-goals

- Detecting environment-set pipefail (`SHELLOPTS=pipefail bash -c '...'`).
  Rare in practice; not in the spec.
- Detecting `shopt -s` (different mechanism).
- Cross-shell support (zsh/dash). The hook's outer Go-tool regex
  applies to bash idioms; we keep that scope.

## Affected code

- `.claude/hooks/guard-bash-pipefail.sh` line 30 — replace the regex
- `scripts/tdd-test-hooks.sh` — add 9 smoke tests (one per AC)

## Test plan

| Test name | Pins criterion # |
|---|---|
| f7_path_with_pipefail_blocked | 1 |
| f7_grep_arg_pipefail_blocked | 2 |
| f7_echo_with_pipefail_blocked | 3 |
| f7_set_o_errexit_blocked | 4 |
| f7_set_o_pipefail_allowed | 5 |
| f7_set_eo_pipefail_allowed | 6 |
| f7_bash_c_with_pipefail_allowed | 7 |
| f7_bash_o_pipefail_flag_allowed | 8 |
| f7_no_pipefail_blocked | 9 |

## Minimum implementation

Replace the current regex with one that requires `pipefail` to follow
a recognised pipefail-enabling pattern, anchored to whitespace/start:

```
(^|[[:space:];&|()])-[a-zA-Z]*o[a-zA-Z]*[[:space:]]+pipefail([[:space:]]|;|&|$)
```

Covers:
- `set -o pipefail` — `-o ` cluster (empty around o), then space, then pipefail
- `set -eo pipefail` — `-eo` cluster, then space, then pipefail
- `bash -o pipefail` — same shape, just different command
- `set -e -o pipefail` — substring match anywhere
- `set -o errexit -o pipefail` — substring match at the second `-o`

Rejects:
- bare `pipefail` (no `-o ` before it)
- `set -o errexit` (no `pipefail` after the cluster)
- `pipefail` as a path/arg

## Risk register

| Risk | Mitigation |
|---|---|
| Regex too narrow; misses `SHELLOPTS=pipefail` env-var form | Documented as out-of-scope; rare. |
| Word `pipefail` appears in a long flag like `--with-pipefail` | The regex anchors `-o[[:space:]]+pipefail` so `--with-pipefail` (ends in pipefail without `-o ` before) doesn't match. ✓ |
| Future bash flag for pipefail without `-o` | Add to regex when surfaced. |
