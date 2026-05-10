#!/usr/bin/env bash
# PreToolUse hook on Edit|Write|MultiEdit. Blocks production-code edits in
# Tier 1 high-stakes paths (per .tdd/tdd-config.json) unless
# .tdd/current-plan.md has the required markers.
#
# Implementation notes:
# - Uses exit 2 + stderr for blocking. Per official Anthropic docs, this
#   takes precedence over permissions.allow rules and is the most reliable
#   blocking mechanism across Claude Code versions.
# - Adds <claude-directive> markup to the stderr message to mitigate
#   reports of Opus 4.6+ stopping on hook blocks instead of acting on
#   the feedback.
# - jq is required. The hook fails closed with a clear error if jq is missing.
#
# 2026-05-05 redesign (see docs/specs/tdd-gate-conflict-resolution-spec.md):
# - Four-marker model. Edit-time markers are M1+M2+M3 (spec, red, green-
#   authorized). M4 (Implementation reviewed) is checked at commit time
#   by gate-tier1-commit.sh, not here.
# - Backwards-compat alias: old "Human approved implementation: yes" is
#   honored as "Green phase authorized: yes" with a stderr deprecation
#   warning. Drop the alias in the next major version.
# - Phase-aware test-file policy. Tier-1 test files are no longer always
#   exempt; they are governed by .test_file_policy in the config so the
#   "don't edit tests in green phase" rule can be enforced.

set -euo pipefail

PAYLOAD="$(cat)"

# jq guard MUST come before any jq invocation. The previous version called jq
# at line 18 to extract FILE and then exited 0 on empty FILE — which fails OPEN
# (Tier 1 edits silently allowed) when jq is missing. Order matters here.
if ! command -v jq >/dev/null 2>&1; then
  cat >&2 <<'HOOK_MSG'
[require-tdd-state] BLOCKED: jq is required for the TDD gate hook.

<claude-directive>
This is an AUTOMATED ENVIRONMENT CHECK, not a user denial. The TDD
enforcement hook needs jq to parse .tdd/tdd-config.json. Suggest the
user install jq with one of:
  - Debian/Ubuntu: sudo apt-get install jq
  - macOS:         brew install jq
  - Alpine:        apk add jq

Do NOT proceed with the edit. Do NOT bypass the hook. Inform the user
of the missing dependency and wait for them to install it.
</claude-directive>
HOOK_MSG
  exit 2
fi

# Now safe to use jq.
#
# Defensive path extraction: collect every candidate path the tool might be
# touching. Current Edit/Write/MultiEdit shapes only set tool_input.file_path
# (sometimes .path), but future tool variants may use .files[].file_path or
# .edits[].file_path. Reading all four keeps the gate correct under shape drift.
PATHS="$(printf '%s' "$PAYLOAD" | jq -r '
  [
    .tool_input.file_path?,
    .tool_input.path?,
    (.tool_input.files[]?.file_path?),
    (.tool_input.edits[]?.file_path?)
  ]
  | map(select(. != null and . != ""))
  | unique
  | .[]
' 2>/dev/null || true)"
[[ -z "$PATHS" ]] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CONFIG="$PROJECT_DIR/.tdd/tdd-config.json"
PLAN="$PROJECT_DIR/.tdd/current-plan.md"

# No config means TDD ceremony not configured for this project — allow.
[[ ! -f "$CONFIG" ]] && exit 0

# Codex round 2 P1: validate the config parses BEFORE running any
# subsequent jq queries. Without this guard, a malformed/partial
# tdd-config.json would cause one of the many jq calls below to
# fail under `set -e`, aborting the hook and leaving the operator
# with NO gate — silent fail-open. Fail closed instead with a clear
# message so the operator can fix the config. This bypasses the
# enforcement_mode dispatch by design: malformed config is an
# environment fault, not a TDD discipline violation.
if ! jq -e . "$CONFIG" >/dev/null 2>&1; then
  cat >&2 <<HOOK_MSG
[require-tdd-state] BLOCKED: .tdd/tdd-config.json failed to parse.

<claude-directive>
This is an AUTOMATED ENVIRONMENT CHECK. The TDD config file at
$CONFIG contains invalid JSON. The hook cannot enforce TDD discipline
without a parseable config and refuses to silently fail open.

You MUST:
  1. Fix the JSON syntax in .tdd/tdd-config.json.
  2. Verify with: jq . .tdd/tdd-config.json
  3. Then retry the edit.

Do NOT proceed with the edit until the config is valid.
</claude-directive>
HOOK_MSG
  exit 2
fi

# F6: enforcement_mode resolver. Returns "strict"|"warn"|"off". Per-hook
# override (.enforcement_mode_overrides[hook]) wins over global; invalid
# values fall back to "strict" (defense-in-depth — typo can't soften).
resolve_enforcement_mode() {
  local hook_name="$1" cfg="$2"
  if [[ ! -f "$cfg" ]] || ! command -v jq >/dev/null 2>&1; then
    echo "strict"; return
  fi
  # Codex round 1 P1: `|| true` so jq failure on partial/malformed
  # config doesn't abort under set -e; falls through to strict.
  local override
  override="$(jq -r --arg n "$hook_name" \
    '.enforcement_mode_overrides[$n] // empty' "$cfg" 2>/dev/null || true)"
  if [[ -n "$override" && "$override" != "null" ]]; then
    case "$override" in
      strict|warn|off) echo "$override"; return ;;
      # Codex round 1 P1: invalid override MUST short-circuit to strict.
      *)
        echo "[require-tdd-state] WARN: invalid enforcement_mode_overrides[$hook_name]='$override'; using strict" >&2
        echo "strict"; return
        ;;
    esac
  fi
  local global
  global="$(jq -r '.enforcement_mode // "strict"' "$cfg" 2>/dev/null || true)"
  case "$global" in
    strict|warn|off) echo "$global" ;;
    *) echo "[require-tdd-state] WARN: invalid enforcement_mode='$global'; using strict" >&2; echo "strict" ;;
  esac
}
ENFORCEMENT_MODE="$(resolve_enforcement_mode "require-tdd-state" "$CONFIG")"

# F6: short-circuit BEFORE printing the long deny stderr if mode is soft.
# warn → emit one-line stderr advisory + exit 0; off → silent passthrough.
# strict → return (caller falls through to original deny + exit 2).
f6_warn_and_exit_if_softened() {
  local reason="$1"
  case "${ENFORCEMENT_MODE:-strict}" in
    off)
      # Codex round 1 P2: emit `{}` so callers conformant with
      # the PreToolUse contract get an explicit pass payload.
      jq -n '{}' 2>/dev/null || echo '{}'
      exit 0
      ;;
    warn)
      cat >&2 <<EOF
[require-tdd-state] WARNING (enforcement_mode=warn): $reason
This would be DENIED in strict mode. Set enforcement_mode: "strict" in
.tdd/tdd-config.json (or remove the override) to enforce.
EOF
      jq -n '{}' 2>/dev/null || echo '{}'
      exit 0
      ;;
  esac
}

# Read tier1 regexes once (avoid re-reading per-file in the loop).
TIER1_REGEXES="$(jq -r '.tier1_path_regexes[]? // empty' "$CONFIG")"

# Walk every candidate path. Skip always-allow non-test paths (docs, .claude,
# CHANGELOG, archive). Test files are NOT in the always-allow list anymore —
# they go through phase-aware policy (see test_file_policy below).
TIER1_MATCHED=()
while IFS= read -r FILE; do
  [[ -z "$FILE" ]] && continue
  # Always-allow patterns. Files matching these are exempted from Tier 1
  # regex evaluation entirely. Each pattern justified:
  #   */.tdd/*  */.claude/*       — pack state / config (downstream-installed
  #                                  pack code in their .claude/.tdd/ dirs)
  #   */docs/*  */specs/*  */archive/* — documentation / history dirs
  #   CHANGELOG* */CHANGELOG* etc.  — community files (any depth)
  #   *CLAUDE.md *AGENTS.md         — operating-rule files (any depth)
  #
  # The bare `*.md` pattern was removed in cycle f4-narrow-md-always-
  # allow (2026-05-08). It exempted ALL markdown from Tier 1 regex
  # evaluation, which made pack-internal markdown like
  # .claude/skills/second-opinion/SKILL.md ungovernable even though
  # the regex listed it as Tier 1. The replacement covers the
  # canonical always-allowed filenames; non-canonical .md files fall
  # through to regex evaluation and are allowed by default if no
  # Tier 1 regex matches.
  #
  # F13 carve-out (2026-05-09): this hook does NOT consult
  # `.tdd/tdd-config.json` `trivial_paths`. The require-second-opinion.sh
  # hook + /second-opinion skill share that list because they implement
  # the same "skip second opinion on docs/CI/etc" policy. THIS hook
  # governs Tier 1 production-code edits — including pack-internal
  # markdown like .claude/skills/second-opinion/SKILL.md. If we used
  # trivial_paths here, *.md would skip Tier 1 enforcement entirely
  # (re-opening cycle f4). The list below is intentionally narrower.
  case "$FILE" in
    */.tdd/*|*/.claude/*|*/docs/*|*/specs/*|*/archive/*) continue ;;
    CHANGELOG*|*/CHANGELOG*|README*|*/README*|LICENSE*|*/LICENSE*) continue ;;
    *CLAUDE.md|*AGENTS.md) continue ;;
  esac
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    if printf '%s' "$FILE" | grep -qE "$pattern"; then
      TIER1_MATCHED+=("$FILE")
      break
    fi
  done <<< "$TIER1_REGEXES"
done <<< "$PATHS"

[[ ${#TIER1_MATCHED[@]} -eq 0 ]] && exit 0

# Categorize Tier-1-matched files into test files and production files.
# They are governed by different rules:
#   - Production files: must have M1+M2+M3 set on the plan.
#   - Test files: governed by test_file_policy (phase-aware).
TIER1_TESTS=()
TIER1_PROD=()
for f in "${TIER1_MATCHED[@]}"; do
  case "$f" in
    *_test.go) TIER1_TESTS+=("$f") ;;
    *) TIER1_PROD+=("$f") ;;
  esac
done

# Helper: render a Tier-1-matched path list for deny messages.
fmt_paths() {
  local IFS=$'\n'
  printf '  %s\n' "$@"
}

# ---- Test-file policy ------------------------------------------------------
#
# Phase-aware. The default config allows test edits before/during red phase
# and denies them after red is confirmed (the documented "don't edit tests
# in green phase" rule). Operators can flip allow_after_red_confirmed: true
# in config when the spec was incomplete and a return to red phase is needed.
if [[ ${#TIER1_TESTS[@]} -gt 0 ]]; then
  ALLOW_BEFORE_SPEC="$(jq -r '.test_file_policy.allow_before_spec_approved // true' "$CONFIG")"
  ALLOW_IN_RED="$(jq -r '.test_file_policy.allow_in_red_phase // true' "$CONFIG")"
  ALLOW_AFTER_RED="$(jq -r '.test_file_policy.allow_after_red_confirmed // false' "$CONFIG")"

  # v1.7.0: typed test-edit exception system. When
  # post_red_mechanical_update.enabled = true AND a matching approved
  # exception exists in .tdd/exceptions/post-red-test-edits.json that
  # covers all the staged TIER1_TESTS files AND the validator passes,
  # allow the edits. Otherwise fall through to the legacy block.
  # TEST_EDIT_EXCEPTION_DISABLE=1 is the killswitch (emergency-only;
  # document reason in commit message).
  TYPED_EXCEPTIONS_ENABLED="$(jq -r '.test_file_policy.post_red_mechanical_update.enabled // false' "$CONFIG")"

  M1_SET=false
  M2_SET=false
  if [[ -f "$PLAN" ]]; then
    grep -qF 'Human approved spec: yes' "$PLAN" && M1_SET=true
    grep -qF 'Red phase confirmed: yes' "$PLAN" && M2_SET=true
  fi

  # Try typed-exception path BEFORE the legacy block.
  if [[ "$M2_SET" == "true" ]] \
     && [[ "$TYPED_EXCEPTIONS_ENABLED" == "true" ]] \
     && [[ "${TEST_EDIT_EXCEPTION_DISABLE:-0}" != "1" ]]; then
    EXC_ARTIFACT="${PROJECT_DIR}/.tdd/exceptions/post-red-test-edits.json"
    LIB_TYPED_EXC="$(dirname -- "${BASH_SOURCE[0]}")/../../scripts/tdd/_lib_test_edit_exception.sh"
    if [[ ! -f "$LIB_TYPED_EXC" ]] && [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
      LIB_TYPED_EXC="$CLAUDE_PLUGIN_ROOT/scripts/tdd/_lib_test_edit_exception.sh"
    fi
    if [[ -f "$EXC_ARTIFACT" ]] && [[ -f "$LIB_TYPED_EXC" ]]; then
      # shellcheck source=/dev/null
      . "$LIB_TYPED_EXC"
      _current_plan_hash=""
      if command -v sha256sum >/dev/null 2>&1; then
        _current_plan_hash="$(sha256sum < "$PLAN" 2>/dev/null | awk '{print $1}')"
      elif command -v shasum >/dev/null 2>&1; then
        _current_plan_hash="$(shasum -a 256 < "$PLAN" 2>/dev/null | awk '{print $1}')"
      fi
      _current_cycle_id="$( { grep -E '^Cycle ID:' "$PLAN" 2>/dev/null || true; } | head -1 | sed -E 's/^Cycle ID:[[:space:]]*//')"

      # v1.7.0 round-5 F1: compute red_proof_hash from current
      # .tdd/red-proof.md so the hook can verify the matched
      # exception is bound to the CURRENT red proof, not a stale one
      # left over from an earlier red phase.
      _current_red_proof_hash=""
      _current_red_proof="$PROJECT_DIR/.tdd/red-proof.md"
      if [[ -f "$_current_red_proof" ]]; then
        if command -v sha256sum >/dev/null 2>&1; then
          _current_red_proof_hash="$(sha256sum < "$_current_red_proof" 2>/dev/null | awk '{print $1}')"
        elif command -v shasum >/dev/null 2>&1; then
          _current_red_proof_hash="$(shasum -a 256 < "$_current_red_proof" 2>/dev/null | awk '{print $1}')"
        fi
      fi

      # v1.7.0 round-2 F4: refuse to honor exceptions when current
      # cycle_id or plan_hash CANNOT BE COMPUTED (fail closed).
      _typed_exc_matched=true
      if [[ -z "$_current_plan_hash" ]] || [[ -z "$_current_cycle_id" ]]; then
        _typed_exc_matched=false
      fi

      # v1.7.0 round-2 F2: per-file exception tracking. Map file →
      # matched exception (rather than overwriting one shared variable).
      declare -A _file_exception_map
      if [[ "$_typed_exc_matched" == "true" ]]; then
        for _tf in "${TIER1_TESTS[@]}"; do
          # Glob direction (round-1 F2): file path tested against glob-as-regex.
          # Round-2 F4: REQUIRE non-empty exact match for cycle_id + plan_hash.
          _matched_exc_json="$(jq -r --arg f "$_tf" --arg ph "$_current_plan_hash" --arg cid "$_current_cycle_id" '
            .exceptions[]?
            | select(.status == "approved")
            | select(.binding.cycle_id == $cid)
            | select(.binding.plan_hash == $ph)
            | select((.binding.cycle_id // "") != "")
            | select((.binding.plan_hash // "") != "")
            | select(any(.scope.paths[]?;
                . as $glob
                | $f | test("^" + ($glob
                    | gsub("\\."; "\\.")
                    | gsub("\\*\\*/"; "(.*/)?")
                    | gsub("\\*\\*"; ".*")
                    | gsub("\\*"; "[^/]*")) + "$")))
            | tojson
          ' "$EXC_ARTIFACT" 2>/dev/null | head -1)"
          if [[ -z "$_matched_exc_json" ]]; then
            _typed_exc_matched=false
            break
          fi
          # v1.7.0 round-3 F3 + round-4 F3: recompute change_intent_hash
          # over (cycle_id, symbols, type, reason, paths, operations)
          # and verify against stored binding.change_intent_hash. The
          # round-4 widening binds scope.paths and operations so a
          # post-approval edit that broadens either field invalidates
          # the hash and fails the check.
          _stored_intent="$(printf '%s' "$_matched_exc_json" | jq -r '.binding.change_intent_hash // ""')"
          _intent_input="$(printf '%s' "$_matched_exc_json" | jq -r '
            (.binding.cycle_id // "") + "|"
            + ((.scope.symbols // []) | join(",")) + "|"
            + .type + "|" + .reason + "|"
            + ((.scope.paths // []) | join(",")) + "|"
            + ((.operations // []) | join(","))
          ')"
          _computed_intent=""
          if command -v sha256sum >/dev/null 2>&1; then
            _computed_intent="$(printf '%s' "$_intent_input" | sha256sum | awk '{print $1}')"
          elif command -v shasum >/dev/null 2>&1; then
            _computed_intent="$(printf '%s' "$_intent_input" | shasum -a 256 | awk '{print $1}')"
          fi
          if [[ -z "$_stored_intent" ]] || [[ "$_stored_intent" != "$_computed_intent" ]]; then
            _typed_exc_matched=false
            break
          fi
          # v1.7.0 round-5 F1: red_proof_hash binding. Stored hash must
          # match current .tdd/red-proof.md hash. Empty stored value or
          # missing red-proof.md fail closed.
          _stored_red_proof_hash="$(printf '%s' "$_matched_exc_json" | jq -r '.binding.red_proof_hash // ""')"
          if [[ -z "$_stored_red_proof_hash" ]] \
             || [[ -z "$_current_red_proof_hash" ]] \
             || [[ "$_stored_red_proof_hash" != "$_current_red_proof_hash" ]]; then
            _typed_exc_matched=false
            break
          fi
          # v1.7.0 round-5 F1: lifecycle expiration. expires field
          # supports two values:
          #   - "next_green_commit" — invalidates once any commit lands
          #     after .tdd/red-proof.md was written (we approximate
          #     "next green commit" as "any commit since the red-proof
          #     was last modified" — close enough; a future major
          #     version can refine to a marker file).
          #   - "<ISO8601>" — absolute expiry timestamp.
          # Missing/unknown values default to "next_green_commit".
          _expires="$(printf '%s' "$_matched_exc_json" | jq -r '.expires // ""')"
          if [[ -z "$_expires" ]]; then
            _expires="$(jq -r '.expires // "next_green_commit"' "$EXC_ARTIFACT" 2>/dev/null || echo next_green_commit)"
          fi
          case "$_expires" in
            next_green_commit)
              # v1.7.0 round-7 F4: bind expiry to git HEAD captured at
              # approval time (binding.head_at_approval). When the
              # current HEAD differs from the stored value, a commit
              # has landed since approval — exception is consumed.
              # Mtime-based check was bypassable: an operator could
              # `touch .tdd/red-proof.md` after a green commit to
              # extend the exception.
              if command -v git >/dev/null 2>&1 \
                 && [[ -d "$PROJECT_DIR/.git" ]]; then
                _stored_head="$(printf '%s' "$_matched_exc_json" | jq -r '.binding.head_at_approval // ""')"
                _current_head="$(cd "$PROJECT_DIR" && git rev-parse HEAD 2>/dev/null || echo "")"
                if [[ -z "$_stored_head" ]] \
                   || [[ -z "$_current_head" ]] \
                   || [[ "$_stored_head" != "$_current_head" ]]; then
                  _typed_exc_matched=false
                  break
                fi
              fi
              ;;
            *)
              # v1.7.0 round-6 F3: ISO8601 absolute. Compare via
              # date(1) -> epoch. Try GNU `-d` first, then BSD `-j -f`
              # form. Fail CLOSED on parse failure (unparseable
              # expires must not silently extend the exception).
              _exp_ts=0
              if command -v date >/dev/null 2>&1; then
                _exp_ts="$(date -d "$_expires" +%s 2>/dev/null || echo 0)"
                if [[ "$_exp_ts" -eq 0 ]]; then
                  _exp_ts="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$_expires" +%s 2>/dev/null || echo 0)"
                fi
              fi
              if [[ "$_exp_ts" -le 0 ]]; then
                _typed_exc_matched=false
                break
              fi
              _now_ts="$(date +%s)"
              if [[ "$_now_ts" -ge "$_exp_ts" ]]; then
                _typed_exc_matched=false
                break
              fi
              ;;
          esac
          _file_exception_map["$_tf"]="$_matched_exc_json"
        done
      fi

      if [[ "$_typed_exc_matched" == "true" ]]; then
        # v1.7.0 round-2 F1: validate the PROPOSED Edit/Write/MultiEdit
        # payload, not the pre-existing worktree diff. Reconstruct a
        # synthetic unified diff from tool_input.{old,new}_string.
        # Round-2 F2: validate per-file with each file's matched
        # exception. Round-2 F5: capture validator stderr to surface
        # in deny diagnostic.
        _validator_failed=false
        _validator_stderr=""
        for _tf in "${TIER1_TESTS[@]}"; do
          _exc_for_file="${_file_exception_map["$_tf"]}"
          # Resolve absolute path BEFORE the diff builder + op-inference
          # block — both reference $_abs_tf.
          _abs_tf="$_tf"
          [[ "$_tf" != /* ]] && _abs_tf="${PROJECT_DIR}/${_tf}"
          # v1.7.0 round-3 F1 + round-4 F2: build a REAL unified diff
          # from PAYLOAD. Earlier rounds prefixed every old line with
          # '-' and every new line with '+', which made unchanged
          # surrounding lines appear as +/- changes — assertion-line
          # context was wrongly flagged. Round-4: extract per-edit
          # old/new strings, write each to tmp files, run `diff -u`
          # to get a true line-diff, and concatenate. Falls back to
          # the prefix construction only when `diff` is missing.
          _build_real_diff() {
            local old="$1" new="$2" relpath="$3"
            local _of _nf _out
            _of="$(mktemp "${TMPDIR:-/tmp}/v17old.XXXXXX")"
            _nf="$(mktemp "${TMPDIR:-/tmp}/v17new.XXXXXX")"
            # Trailing newline avoids `diff -u` treating "no newline at
            # end of file" as a content change (which previously made
            # an unchanged final line appear as -/+ in the diff).
            printf '%s\n' "$old" > "$_of"
            printf '%s\n' "$new" > "$_nf"
            if command -v diff >/dev/null 2>&1; then
              _out="$(diff -u --label "a/$relpath" --label "b/$relpath" "$_of" "$_nf" 2>/dev/null || true)"
            else
              _out="--- a/$relpath
+++ b/$relpath
$(printf '%s\n' "$old" | sed 's/^/-/')
$(printf '%s\n' "$new" | sed 's/^/+/')"
            fi
            rm -f "$_of" "$_nf"
            printf '%s\n' "$_out"
          }

          _tool_name_for_diff="$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""')"
          _proposed_diff=""
          # v1.7.0 round-6 F1: normalize the payload's file_path so
          # `./internal/m/x_test.go` and `/abs/proj/internal/m/x_test.go`
          # both compare equal to the project-relative TIER1_TESTS
          # entry `internal/m/x_test.go`. Without normalization, the
          # diff builder would silently produce an empty diff and the
          # validator would treat it as "no assertion change" → pass.
          _normalize_path() {
            local raw="$1" rel
            rel="$raw"
            # Strip leading "./".
            rel="${rel#./}"
            # If absolute and inside PROJECT_DIR, strip the prefix.
            case "$rel" in
              "$PROJECT_DIR"/*) rel="${rel#"$PROJECT_DIR"/}" ;;
              /*) ;;  # absolute outside project — leave as-is
            esac
            printf '%s' "$rel"
          }
          case "$_tool_name_for_diff" in
            Edit)
              _file_field_raw="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_input.path // ""')"
              _file_field="$(_normalize_path "$_file_field_raw")"
              if [[ "$_file_field" == "$_tf" ]]; then
                _old="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.old_string // ""')"
                _new="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.new_string // ""')"
                _proposed_diff="$(_build_real_diff "$_old" "$_new" "$_tf")"
              fi
              ;;
            Write)
              _file_field_raw="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_input.path // ""')"
              _file_field="$(_normalize_path "$_file_field_raw")"
              if [[ "$_file_field" == "$_tf" ]]; then
                _old=""
                [[ -e "$_abs_tf" ]] && _old="$(cat -- "$_abs_tf" 2>/dev/null || true)"
                _new="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.content // ""')"
                _proposed_diff="$(_build_real_diff "$_old" "$_new" "$_tf")"
              fi
              ;;
            MultiEdit)
              _file_field_raw="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_input.path // ""')"
              _file_field="$(_normalize_path "$_file_field_raw")"
              # Two MultiEdit shapes: top-level file_path + edits[]
              # (canonical; same target file for all edits) OR each
              # edit carries its own file_path.
              if [[ "$_file_field" == "$_tf" ]]; then
                # Concatenate per-edit unified diffs.
                _multi_diff=""
                _n="$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.edits // []) | length')"
                for _i in $(seq 0 $((_n - 1))); do
                  _o="$(printf '%s' "$PAYLOAD" | jq -r --argjson i "$_i" '.tool_input.edits[$i].old_string // ""')"
                  _nstr="$(printf '%s' "$PAYLOAD" | jq -r --argjson i "$_i" '.tool_input.edits[$i].new_string // ""')"
                  _multi_diff+="$(_build_real_diff "$_o" "$_nstr" "$_tf")"$'\n'
                done
                _proposed_diff="$_multi_diff"
              else
                _multi_diff=""
                _n="$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.edits // []) | length')"
                for _i in $(seq 0 $((_n - 1))); do
                  _ef_raw="$(printf '%s' "$PAYLOAD" | jq -r --argjson i "$_i" '.tool_input.edits[$i].file_path // ""')"
                  _ef="$(_normalize_path "$_ef_raw")"
                  [[ "$_ef" != "$_tf" ]] && continue
                  _o="$(printf '%s' "$PAYLOAD" | jq -r --argjson i "$_i" '.tool_input.edits[$i].old_string // ""')"
                  _nstr="$(printf '%s' "$PAYLOAD" | jq -r --argjson i "$_i" '.tool_input.edits[$i].new_string // ""')"
                  _multi_diff+="$(_build_real_diff "$_o" "$_nstr" "$_tf")"$'\n'
                done
                _proposed_diff="$_multi_diff"
              fi
              ;;
          esac

          # v1.7.0 round-6 F1: empty proposed_diff for an
          # edit_existing_tests covered file means the hook could not
          # reconstruct what was being changed (path normalization
          # missed, unknown tool shape, etc.). Fail CLOSED so the
          # validator never sees an empty diff and silently approves.
          _strip_diff="$(printf '%s\n' "$_proposed_diff" \
            | grep -E '^[+-][^+-]' \
            | grep -vE '^---|^\+\+\+' \
            | head -1 || true)"
          if [[ -z "$_strip_diff" ]]; then
            _validator_failed=true
            _validator_stderr+="$_abs_tf: failed (empty_proposed_diff: hook could not reconstruct an Edit/Write/MultiEdit diff for this file from PAYLOAD; refusing to validate empty diff under typed-exception path)"$'\n'
            continue
          fi

          # v1.7.0 round-4 F1: infer the requested operation and verify
          # it is in the matched exception's operations list. Without
          # this check, an edit_existing_tests-only exception would
          # silently approve a Write to a non-existent test file
          # (validator's edit_existing_tests branch only runs when the
          # file exists, and create_new_tests check would never fire).
          _tool_name="$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""')"
          _file_exists_for_op=true
          [[ ! -e "$_abs_tf" ]] && _file_exists_for_op=false
          _inferred_op=""
          case "$_tool_name" in
            Write)
              if [[ "$_file_exists_for_op" == "false" ]]; then
                _inferred_op="create_new_tests"
              else
                _inferred_op="edit_existing_tests"
              fi
              ;;
            Edit|MultiEdit)
              if [[ "$_file_exists_for_op" == "false" ]]; then
                _inferred_op="create_new_tests"
              else
                _inferred_op="edit_existing_tests"
              fi
              ;;
          esac
          _exc_ops_str="$(printf '%s' "$_exc_for_file" | jq -r '(.operations // []) | join(",")')"
          if [[ -n "$_inferred_op" ]] && [[ ",$_exc_ops_str," != *",$_inferred_op,"* ]]; then
            _validator_failed=true
            _validator_stderr+="$_abs_tf: failed (operation_not_permitted: tool_name=$_tool_name on $( [[ "$_file_exists_for_op" == "true" ]] && echo "existing" || echo "non-existent" ) test file requires '$_inferred_op' in operations; exception authorizes only [$_exc_ops_str])"$'\n'
            continue
          fi

          # v1.7.0 round-3 F2: for create_new_tests operation, the
          # validator needs to read the PROPOSED content (Write payload
          # or applied MultiEdit), not whatever's on disk (file may
          # not exist yet OR has stale pre-Write content). Materialize
          # the proposed file content to a temp path and pass that to
          # the validator instead of the on-disk path.
          _validator_path="$_abs_tf"
          _ops_str="$(printf '%s' "$_exc_for_file" | jq -r '(.operations // []) | join(",")')"
          if [[ ",$_ops_str," == *",create_new_tests,"* ]]; then
            _proposed_content="$(printf '%s' "$PAYLOAD" | jq -r --arg f "$_tf" '
              if .tool_input.file_path == $f or .tool_input.path == $f then
                if .tool_input.content then .tool_input.content
                elif (.tool_input.edits // []) | length > 0 then
                  # Build content by applying edits to empty seed (best-effort).
                  [.tool_input.edits[] | .new_string // ""] | join("\n")
                else "" end
              else "" end
            ' 2>/dev/null || true)"
            if [[ -n "$_proposed_content" ]]; then
              _validator_path="$(mktemp "${TMPDIR:-/tmp}/v17.XXXXXX.go")"
              printf '%s' "$_proposed_content" > "$_validator_path"
            fi
          fi

          _file_stderr="$( {
            printf '%s' "$_proposed_diff" \
              | validate_exception_diff "$_exc_for_file" "$_validator_path" 2>&1 >/dev/null
            echo "EXIT:$?" >&2
          } 2>&1)"
          # Clean up tmp file if created.
          [[ "$_validator_path" != "$_abs_tf" ]] && rm -f "$_validator_path"
          if printf '%s' "$_file_stderr" | grep -qE 'EXIT:[12]'; then
            _validator_failed=true
            _validator_stderr+="$_file_stderr"$'\n'
          fi
        done
        if [[ "$_validator_failed" != "true" ]]; then
          ALLOW_AFTER_RED=true
        else
          # v1.7.0 round-2 F5: surface validator's per-file report on
          # stderr so the operator sees WHY the exception was rejected.
          echo "[require-tdd-state] VALIDATOR REPORT (typed-exception attempt failed):" >&2
          printf '%s\n' "$_validator_stderr" >&2
        fi
      fi
    fi
  fi

  if [[ "$M2_SET" == "true" && "$ALLOW_AFTER_RED" != "true" ]]; then
    # v1.7.0: emit deprecation warning each time the boolean is consulted.
    # Rate-limited via per-invocation guard variable so cycles with many
    # test edits don't drown stderr.
    if [[ "${_V17_DEPRECATION_WARNED:-0}" != "1" ]]; then
      _V17_DEPRECATION_WARNED=1
      echo "[require-tdd-state] DEPRECATED: test_file_policy.allow_after_red_confirmed is a global post-red test-edit bypass. Use post_red_mechanical_update typed exceptions instead (.tdd/tdd-config.json post_red_mechanical_update.enabled: true; see .claude/rules/go-tdd.md 'Typed test-edit exceptions'). This boolean will be removed in v2.0.0." >&2
    fi
    f6_warn_and_exit_if_softened "edit to Tier 1 test file(s) after red phase confirmed"
    test_list="$(fmt_paths "${TIER1_TESTS[@]}")"
    cat >&2 <<HOOK_MSG
[require-tdd-state] BLOCKED edit to Tier 1 test file(s) after red phase confirmed:
$test_list

<claude-directive>
This is an AUTOMATED TDD GATE. Editing tests after the red phase has been
confirmed is forbidden by default — that would let you change the test to
match the implementation, defeating the point of red-before-green. The
documented rule is: "If tests need changes, the spec was incomplete. STOP,
return to red."

You MUST do one of:
  1. STOP and tell the operator that the spec was incomplete. Ask whether
     to revert "Red phase confirmed: yes" to "no" and rewrite the spec
     and red proof. The operator must explicitly authorize a return to
     red phase.
  2. If the operator has already authorized return to red, set
     "Red phase confirmed: no" in .tdd/current-plan.md FIRST, then make
     the test edits, then re-capture .tdd/red-proof.md.
  3. EMERGENCY ONLY: the operator may flip
     test_file_policy.allow_after_red_confirmed: true in
     .tdd/tdd-config.json. Document the reason in the commit message.
     This is not for routine use.

Do NOT proceed with the edit without operator authorization.
</claude-directive>
HOOK_MSG
    exit 2
  fi

  if [[ "$M1_SET" == "false" && "$ALLOW_BEFORE_SPEC" != "true" ]]; then
    f6_warn_and_exit_if_softened "edit to Tier 1 test file(s) before spec approved"
    test_list="$(fmt_paths "${TIER1_TESTS[@]}")"
    cat >&2 <<HOOK_MSG
[require-tdd-state] BLOCKED edit to Tier 1 test file(s) before spec approved:
$test_list

<claude-directive>
This project's test_file_policy.allow_before_spec_approved is false. Test
edits require an approved spec first. Run the go-tdd-feature or
go-tdd-bugfix skill, draft the spec, and ask for APPROVED SPEC at gate 1
before writing tests.
</claude-directive>
HOOK_MSG
    exit 2
  fi

  # Otherwise: in spec or red phase, test edits are allowed by default.
fi

# ---- Production-file gate -------------------------------------------------
[[ ${#TIER1_PROD[@]} -eq 0 ]] && exit 0
PROD_LIST="$(fmt_paths "${TIER1_PROD[@]}")"

if [[ ! -f "$PLAN" ]]; then
  f6_warn_and_exit_if_softened "edit to Tier 1 high-stakes path(s) without .tdd/current-plan.md"
  cat >&2 <<HOOK_MSG
[require-tdd-state] BLOCKED edit to Tier 1 high-stakes path(s):
$PROD_LIST

<claude-directive>
This is an AUTOMATED TDD GATE, not a user denial. No .tdd/current-plan.md
exists. Production edits to Tier 1 paths require the go-tdd-feature or
go-tdd-bugfix skill workflow.

You MUST do the following autonomously, in order:
  1. Invoke the go-tdd-feature skill (for new functionality) or
     go-tdd-bugfix skill (for bug fixes / regressions).
  2. Copy .tdd/templates/{feature,bugfix}-plan.md to .tdd/current-plan.md.
  3. Fill in the spec sections.
  4. STOP and ask the human for explicit APPROVED SPEC at gate 1.

Do NOT proceed with the edit. Do NOT self-approve. Do NOT bypass the hook
by editing markers without an APPROVED reply from the human.
</claude-directive>
HOOK_MSG
  exit 2
fi

# Plan exists. Resolve the edit-time required markers (prefer the new field
# name; fall back to legacy required_markers for older configs).
EDIT_TIME_MARKERS_RAW="$(jq -r '
  if (.required_markers_edit_time | type) == "array"
  then .required_markers_edit_time[]?
  else .required_markers[]? // empty
  end
' "$CONFIG")"

# Build the alias map (new -> old). For each required marker, if the new
# name is missing but the alias is present, accept with deprecation warning.
ALIAS_PAIRS="$(jq -r '
  .marker_aliases // {} | to_entries[] | "\(.key)\t\(.value)"
' "$CONFIG")"

# Walk required markers. Track missing (with no acceptable alias) for the deny
# message; emit a single deprecation summary if any alias was used.
MISSING=()
ALIAS_USED=()
while IFS= read -r marker; do
  [[ -z "$marker" ]] && continue
  if grep -qF "$marker" "$PLAN"; then
    continue
  fi
  # Look up alias for this marker.
  alias=""
  while IFS=$'\t' read -r k v; do
    [[ "$k" == "$marker" ]] && alias="$v"
  done <<< "$ALIAS_PAIRS"
  if [[ -n "$alias" ]] && grep -qF "$alias" "$PLAN"; then
    ALIAS_USED+=("$alias -> $marker")
    continue
  fi
  MISSING+=("$marker")
done <<< "$EDIT_TIME_MARKERS_RAW"

if [[ ${#ALIAS_USED[@]} -gt 0 ]]; then
  echo "[require-tdd-state] DEPRECATION: plan uses old marker name(s):" >&2
  for a in "${ALIAS_USED[@]}"; do echo "  $a" >&2; done
  echo "[require-tdd-state] Run scripts/migrate-tdd-markers.sh to update the plan. The alias will be removed in the next major version." >&2
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  f6_warn_and_exit_if_softened "edit to Tier 1 high-stakes path(s) with missing TDD markers"
  cat >&2 <<HOOK_MSG
[require-tdd-state] BLOCKED edit to Tier 1 high-stakes path(s):
$PROD_LIST
The plan at .tdd/current-plan.md is missing required markers:
HOOK_MSG
  for m in "${MISSING[@]}"; do echo "  - $m" >&2; done
  cat >&2 <<HOOK_MSG

<claude-directive>
This is an AUTOMATED TDD GATE, not a user denial. The plan exists but
the required APPROVED markers are not all set.

You MUST:
  1. STOP. Do not edit any Tier 1 production file.
  2. Identify which gate is missing approval:
     - "Human approved spec: yes" missing       -> gate 1 not approved.
       Ask operator: "APPROVED SPEC for <cycle-id>?"
     - "Red phase confirmed: yes" missing       -> red proof not done.
       Write failing tests; capture verbatim output to .tdd/red-proof.md;
       set the marker yourself once the artifact exists.
     - "Green phase authorized: yes" missing    -> gate 2 not approved.
       Ask operator: "APPROVED GREEN for <cycle-id>?" The operator's
       APPROVED GREEN authorizes you to begin writing the implementation.
  3. The operator approves with the literal word APPROVED (or
     APPROVED SPEC / APPROVED GREEN for clarity). Any other reply is
     not an approval. NEVER self-approve by setting a marker without
     an explicit human reply.

Note: M4 "Implementation reviewed: yes" is NOT required at edit time.
That marker is checked at commit time by gate-tier1-commit.sh after the
operator says APPROVED IMPLEMENTATION at gate 3.
</claude-directive>
HOOK_MSG
  exit 2
fi

exit 0
