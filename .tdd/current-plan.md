# Bugfix Plan: f5-diff-plan-hash-binding — bind adjudication to specific diff/plan content

Status: active
Cycle ID: f5-diff-plan-hash-binding
Change type: enhancement (close fundamental gate-bypass)
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

`require-second-opinion.sh` checks only that `.tdd/second-opinion-
completed.md` exists AND is recent (mtime < 60 min). No content
binding to the diff or plan that was reviewed. Concrete bypass:

  1. Operator (or Claude) runs /second-opinion on small change A
     (e.g., a typo fix or trivial cleanup).
  2. Skill writes adjudication.
  3. Operator/Claude makes large, risky change B unrelated to A.
  4. Tries to commit. Hook checks adjudication: exists, mtime ~30min
     → ALLOW.
  5. Change B was never reviewed. Tier 1 ceremony ostensibly enforced;
     actual review wasn't.

This is the highest-leverage gate-bypass in the v1.6.x review because:
- It defeats the WHOLE point of /second-opinion (review THIS change)
- It's easy to trigger accidentally (review one thing, then keep
  working) without realising the gate is open
- Time-based freshness is a proxy for "tied to current work"; the
  proxy fails when work changes faster than the freshness window

## Reproduction

```
TMPDIR=$(mktemp -d) && cd $TMPDIR && git init -q
mkdir -p .tdd internal/auth
cp /home/toha/go-projects-claude-starter/.tdd/tdd-config.json .tdd/
echo "package auth" > internal/auth/handler.go
git add . && git commit -q -m initial

# Cycle 1: review a small change
echo "// small typo fix" >> internal/auth/handler.go
git add internal/auth/handler.go
# (run /second-opinion on this small diff; skill writes adjudication)
cat > .tdd/second-opinion-completed.md <<'EOF'
date: 2026-05-09T03:00:00Z
adjudicated_by: claude
EOF

# Cycle 2: now make a HUGE unrelated change
git diff --cached  # show the small change reviewed
git restore --staged internal/auth/handler.go
sed -i '1i import "fmt"' internal/auth/handler.go  # something larger
for i in {1..100}; do echo "// new line $i" >> internal/auth/handler.go; done
git add internal/auth/handler.go

# Try to commit — gate currently allows because adjudication is recent
echo '{"tool_input":{"command":"git commit -m \"big change\""}}' \
  | CLAUDE_PROJECT_DIR=$TMPDIR bash .claude/hooks/gate-tier1-commit.sh
# Expected: deny (current diff differs from what was reviewed)
# Actual:   allow (60-min freshness check passes)
```

## Acceptance criteria

1. SKILL.md Step 6a documents how to compute and record `diff_sha256`
   (sha of `git diff HEAD --cached`) and `plan_sha256` (sha of
   `.tdd/current-plan.md`) in the adjudication file.
2. The adjudication file format includes both fields (empty string OK
   for the case that doesn't apply, e.g., plan_sha256="" for non-Tier-1).
3. `require-second-opinion.sh` reads the recorded hashes from the
   adjudication file.
4. When `second_opinion.require_hash_binding_tier1: true` AND the
   target path is Tier 1:
   a. Recorded `diff_sha256` non-empty and ≠ current → DENY with
      "diff has changed since adjudication" diagnostic.
   b. Recorded `plan_sha256` non-empty and ≠ current → DENY with
      "plan has changed since adjudication" diagnostic.
5. When the flag is OFF (default false) OR the path is NOT Tier 1:
   existing mtime-only behavior preserved (no regression).
6. Killswitch `SECOND_OPINION_HASH_DISABLE=1` env var overrides the
   flag (for emergency unblock; documented in hook header).
7. `.tdd/tdd-config.json` has the new flag with default `false`
   (matches the v1.6.0 opt-in rollout pattern of require_research_
   packet_tier1, require_pass_a_tier1, require_disposition_matrix_tier1).
8. Smoke tests cover the matrix below.

## Non-goals

- Hash binding for non-Tier-1 paths. The opt-in flag is Tier-1-scoped;
  follow-up cycle if/when consumers want it broader.
- Semantic equivalence (same code, different formatting → same hash).
  Bytewise sha256 is the v1 contract; semantic hash is a much bigger
  cycle.
- Auto-recovery (hook offers to re-run /second-opinion). The hook
  denies and the operator runs /second-opinion manually. Auto-rerun
  has its own scope concerns.
- Server-side enforcement (hash recorded in commit metadata). v1 is
  local-only; CI verification is a possible follow-up.

## Affected code

- `.claude/skills/second-opinion/SKILL.md` — Step 6a hash computation
- `.claude/hooks/require-second-opinion.sh` — hash verification
- `.tdd/tdd-config.json` — new flag `second_opinion.require_hash_binding_tier1: false`
- `scripts/tdd-test-hooks.sh` — new tests covering the matrix

## Test plan

| Test name | Pins criterion # |
|---|---|
| f5_diff_hash_mismatch_denies_tier1 | 4a |
| f5_diff_hash_match_allows_tier1 | 4a |
| f5_plan_hash_mismatch_denies_tier1 | 4b |
| f5_plan_hash_match_allows_tier1 | 4b |
| f5_flag_off_ignores_hash_legacy_behavior | 5 |
| f5_non_tier1_path_ignores_hash | 5 |
| f5_killswitch_env_var_overrides | 6 |
| f5_legacy_adjudication_without_hashes_denies_when_flag_on | 4 |

## Minimum implementation

### SKILL.md Step 6a — augment the adjudication template

```bash
mkdir -p .tdd

# Compute hashes BEFORE writing the adjudication so they're stable.
diff_sha=$(git diff HEAD --cached 2>/dev/null | sha256sum | awk '{print $1}')
plan_sha=""
if [[ -f .tdd/current-plan.md ]]; then
  plan_sha=$(sha256sum .tdd/current-plan.md | awk '{print $1}')
fi

cat > .tdd/second-opinion-completed.md <<EOF
# Second opinion adjudication
date: $(date -u +%FT%TZ)
scope: ...
model: ...
diff_sha256: $diff_sha
plan_sha256: $plan_sha
files_in_scope:
  - ...
findings_total: ...
...
EOF
```

### Hook — after the existing freshness check

```bash
# F5 — diff/plan hash binding (Tier 1, opt-in via flag).
# Closes the bypass where a fresh adjudication for one diff covers
# subsequent unrelated changes. Killswitch: SECOND_OPINION_HASH_DISABLE=1.
if [[ "$is_tier1" == "true" ]] \
   && [[ "${SECOND_OPINION_HASH_DISABLE:-0}" != "1" ]] \
   && [[ -f "$TDD_CONFIG_FILE" ]] \
   && command -v jq >/dev/null 2>&1 \
   && [[ "$(jq -r '.second_opinion.require_hash_binding_tier1 // false' "$TDD_CONFIG_FILE")" == "true" ]]; then

  recorded_diff="$(awk '/^diff_sha256:/ {print $2; exit}' "$ADJUDICATION" 2>/dev/null)"
  recorded_plan="$(awk '/^plan_sha256:/ {print $2; exit}' "$ADJUDICATION" 2>/dev/null)"

  current_diff="$(git -C "$ROOT" diff HEAD --cached 2>/dev/null | sha256sum | awk '{print $1}')"
  current_plan=""
  [[ -f "$TDD_PLAN" ]] && current_plan="$(sha256sum "$TDD_PLAN" | awk '{print $1}')"

  if [[ -n "$recorded_diff" && "$recorded_diff" != "$current_diff" ]]; then
    deny "Diff has changed since /second-opinion adjudication (recorded: ${recorded_diff:0:12}…, current: ${current_diff:0:12}…). The reviewed work isn't the work you're about to commit. Re-run /second-opinion on the current diff." \
         "diff_hash_mismatch" "$TARGET"
  fi
  if [[ -n "$recorded_plan" && "$recorded_plan" != "$current_plan" ]]; then
    deny "Plan has changed since /second-opinion adjudication (recorded: ${recorded_plan:0:12}…, current: ${current_plan:0:12}…). The reviewed plan isn't the current plan. Re-run /second-opinion." \
         "plan_hash_mismatch" "$TARGET"
  fi
  if [[ -z "$recorded_diff" && -z "$recorded_plan" ]]; then
    deny "Adjudication file lacks both diff_sha256 and plan_sha256 fields. With second_opinion.require_hash_binding_tier1=true, hash binding is required. Re-run /second-opinion (the skill records hashes automatically) — or set the flag to false in .tdd/tdd-config.json to opt out." \
         "no_hash_binding" "$TARGET"
  fi
fi
```

### tdd-config.json — new flag

```json
{
  "second_opinion": {
    ...
    "require_hash_binding_tier1": false
  }
}
```

## Risk register

| Risk | Mitigation |
|---|---|
| Hash mismatch on legitimate workflows (review → apply finding → restage → commit) | Documented friction. Operator can re-run /second-opinion (cheap) or use killswitch. The friction is the FEATURE — every commit's actual content is bound to a review. |
| `git diff HEAD --cached` is empty (nothing staged) → empty hash matches → trivial bypass | Both recorded and current would be empty (sha256 of empty stream is well-defined). The check `recorded != current` would be FALSE for both empty. So this case allows. That's correct: nothing to commit means nothing to review. |
| Operator commits with `git commit -a` (auto-stages) — cached diff was empty at adjudication, full at commit | Caught by the hash mismatch (recorded empty ≠ current non-empty). Forces operator to stage explicitly + /second-opinion the staged content before commit. Correct enforcement. |
| Tampering: operator edits the adjudication file's hash to match current diff | Out of scope. Operator can already disable hooks; this is a discipline tool, not a security boundary. |
| Performance: `git diff HEAD --cached` on huge repos is slow | sha256sum is fast; git diff is the cost. Same operation as Layer 0 already runs. Acceptable. |
| Existing tests break because their fixtures don't have hash fields | Tests using flag=false (default) don't trigger the check — no regression. New tests use flag=true explicitly. |
