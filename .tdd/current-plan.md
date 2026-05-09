# Bugfix Plan: f1-path-aware-mutating-bash — close skill-self-write deadlock

Status: active
Cycle ID: f1-path-aware-mutating-bash
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

F1 from the combined v1.6.0 code review (P0 — deadlocks normal use):

`require-second-opinion.sh`'s `is_bash_mutating()` detects mutating
Bash patterns (`cat > path`, `tee path`, `>> file.ext`, etc.) but
DOES NOT check whether the target path is skill-internal. The skill
itself writes to `.tdd/codex/round1.json`, `.tdd/codex/disposition-
matrix.md`, `.tdd/second-opinion-completed.md`, `.tdd/codex/
independent-design.md` — all via `cat > path` patterns embedded in
the bash blocks of SKILL.md.

Result: when the skill attempts to write its own artifacts, the hook
fires, `is_bash_mutating` returns true, hook requires fresh
adjudication. But on a cold cycle (no prior adjudication), the
artifact doesn't exist yet — and the skill is in the act of writing
it. **Deadlock.** The cycle can't bootstrap.

Workaround today: operators have to use Edit/Write directly (which the
hook tolerates because `.tdd/**` is in the Edit-branch always-allow)
or pre-create the artifact file via Edit before the skill writes to it.
Both are friction; the skill should Just Work.

## Reproduction

```
TMPDIR=$(mktemp -d) && git init "$TMPDIR" ...
cp .tdd/tdd-config.json "$TMPDIR/.tdd/"
mkdir -p "$TMPDIR/internal/auth"
echo "package auth" > "$TMPDIR/internal/auth/handler.go"
git add . && git commit -m initial

# Simulate skill-self-write (no current-plan.md, no adjudication):
echo '{"tool_name":"Bash","tool_input":{"command":"cat > .tdd/codex/round1.json"}}' \
  | CLAUDE_PROJECT_DIR=$TMPDIR bash .claude/hooks/require-second-opinion.sh

# Expected: allow (target is skill-internal)
# Actual:   deny (is_bash_mutating returns true; no adjudication)
```

## Expected behavior

Bash commands writing to skill-internal paths (`.tdd/**`, `.claude/**`,
`.second-opinion/**`) are not classified as "mutating production code."
The hook allows them so the skill can self-bootstrap.

Bash commands writing to PRODUCTION paths (`internal/**`,
`cmd/**`, etc.) continue to be classified as mutating and require
adjudication.

## Acceptance criteria

1. `is_bash_mutating()` (or its caller) extracts the redirect target
   from `cat > path`, `tee path`, and `>> path.ext` patterns.
2. If the extracted target matches a skill-internal path prefix
   (`.tdd/`, `.claude/`, `.second-opinion/`), the command is treated
   as non-mutating (returns false).
3. Bash commands with no extractable target OR with a target matching
   PRODUCTION paths continue to be treated as mutating (existing
   behavior preserved).
4. Block-redirect form `{ ... } > .tdd/codex/disposition-matrix.md`
   ALSO extracts the target and is treated as non-mutating if target
   is skill-internal.
5. Smoke test: `cat > .tdd/codex/round1.json` → allow (was deny).
6. Smoke test: `cat > .tdd/second-opinion-completed.md` → allow.
7. Smoke test: `cat > internal/auth/handler.go` → still deny (no
   regression).
8. Smoke test: `tee .tdd/research-packet.md` → allow.
9. Smoke test: `tee internal/auth/handler.go` → still deny.
10. Smoke test: `{ ... } > .tdd/codex/disposition-matrix.md` → allow.
11. Existing 117 smoke tests still pass.

## Non-goals

- Consolidating all three "trivial paths" lists into one config field
  (F13 from the v1.6.0 review). That's a separate cycle.
- Changing `is_always_allowed_path()` for the Edit branch (already
  works correctly for `.tdd/**`).
- Path-aware checks for `sed -i`, `gofmt -w`, `go mod tidy` etc. —
  those targets are positional args and rarely write skill-internal
  paths in practice. Keep simple-deny for those.

## Affected code

- `.claude/hooks/require-second-opinion.sh` — add target extraction
  and skill-internal check inside `is_bash_mutating` for redirect
  patterns.
- `scripts/tdd-test-hooks.sh` — add 6 new smoke tests (5, 6, 7, 8,
  9, 10 above).

## Test plan

| Test name | Pins criterion # |
|---|---|
| f1_cat_redirect_to_tdd_allowed | 5 |
| f1_cat_redirect_to_second_opinion_artifact_allowed | 6 |
| f1_cat_redirect_to_production_still_denied | 7 |
| f1_tee_to_tdd_allowed | 8 |
| f1_tee_to_production_still_denied | 9 |
| f1_block_redirect_to_tdd_allowed | 10 |

## Minimum implementation

In `is_bash_mutating()`, for each redirect pattern:
1. Run the existing detection.
2. If matched, extract the target file (everything after the last
   `>` token, trimmed).
3. Check target against skill-internal prefixes
   (`.tdd/`, `.claude/`, `.second-opinion/`).
4. If skill-internal → continue (don't return 0; treat as non-mutating).
5. Otherwise → return 0 (mutating, existing behavior).

```bash
# Helper inside the hook
_extract_redirect_target() {
  echo "$1" | awk -F'>+' '
    NF >= 2 {
      tgt = $NF
      sub(/^[[:space:]]+/, "", tgt)
      sub(/[[:space:]].*$/, "", tgt)
      print tgt
    }'
}

_target_is_skill_internal() {
  local target="$1"
  case "$target" in
    .tdd/*|.claude/*|.second-opinion/*|*/.tdd/*|*/.claude/*|*/.second-opinion/*) return 0 ;;
    *) return 1 ;;
  esac
}
```

Then wrap each redirect-style detection:

```bash
# OLD:
echo "$cmd" | grep -Eq '(^|[;&|])[[:space:]]*cat[[:space:]]+([^|<]*[^|<0-9])?>+[[:space:]]*[^&[:space:]]'  && return 0

# NEW:
if echo "$cmd" | grep -Eq '(^|[;&|])[[:space:]]*cat[[:space:]]+([^|<]*[^|<0-9])?>+[[:space:]]*[^&[:space:]]'; then
  target="$(_extract_redirect_target "$cmd")"
  if [[ -n "$target" ]] && _target_is_skill_internal "$target"; then
    : # skill-internal, fall through to next detection
  else
    return 0
  fi
fi
```

Same wrapping for `tee`, `>> file.ext`. The block-redirect form
`{ ... } > path` needs a new detection regex; same target extraction.

## Risk register

| Risk | Mitigation |
|---|---|
| Extraction of multiple targets in compound commands (`cat a > b; cat c > d`) | Target extraction returns the LAST `>` target. If the last is skill-internal, all earlier targets are de facto allowed too. Acceptable for typical skill-bootstrap cases (one redirect per command). |
| Operator deliberately writes production code via `cat > .tdd/foo` then moves it | The `.tdd/` directory contains hook state, not production code. Operators don't typically write production code there. Mitigation: integration_guards can encode "no production code in .tdd/" if needed. |
| New paths the skill writes to (future cycles) outside `.tdd/`, `.claude/`, `.second-opinion/` | Add to the prefix list. Documented limitation; expand on demand. |
