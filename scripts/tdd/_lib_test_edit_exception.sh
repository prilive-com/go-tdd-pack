#!/usr/bin/env bash
# scripts/tdd/_lib_test_edit_exception.sh
#
# v1.7.0 typed test-edit exception validator library.
#
# Sourced by .claude/hooks/require-tdd-state.sh and invoked
# directly by the smoke suite + grant helper. Validates that a
# diff against approved exception files matches the exception
# type's contract (no assertion changes for edit_existing_tests;
# assertion presence for create_new_tests).
#
# CONTRACT
#
# CLI form (called from smoke + diagnostic tools):
#   bash _lib_test_edit_exception.sh validate_exception_diff \
#     <exception-json> <file1> [<file2> ...]
#   <stdin: unified diff hunks (lines starting with + or -)>
#
#   Exit 0: all files pass validation.
#   Exit 1: at least one file failed; diagnostic on stderr names
#     each offending file with reason + evidence line.
#   Exit 2: hard schema error (malformed exception JSON, missing
#     required fields, etc.).
#
# Sourced form (from require-tdd-state.sh):
#   . _lib_test_edit_exception.sh
#   validate_exception_diff '<json>' file1 [file2 ...] <<<"$diff"
#
# DESIGN PHILOSOPHY (honest)
#
# Regex-based validator. Catches the testify family cleanly
# (require.X / assert.X / Expect()), gomega (with profile opt-in),
# and stdlib t.Errorf / t.Fatal patterns. Does NOT reliably catch
# weakening expressed via custom helpers without operator-declared
# `assertion_helper_patterns`. Does NOT do AST-level analysis
# (deferred to v1.8.0).
#
# Conservative-by-design: false negatives (validator misses a
# weakening) are recoverable (the agent's review catches it; the
# operator's APPROVED EXCEPTION is the ceremony floor). False
# positives (validator rejects a legitimate mechanical update)
# block the operator's intended workflow — preferred over the
# converse.
#
# PROFILES
#
# Profiles declare which assertion patterns to look for. Operators
# select via tdd-config.json
# `test_file_policy.post_red_mechanical_update.validators.active_profiles`.
#
#   stdlib  — t.Error*, t.Fatal*, t.Skip*, t.Fail*, plus
#             `if (got|cond) ... t\.(Error|Fatal)` patterns.
#   testify — require.X(...) + assert.X(...).
#   gomega  — Expect(...).To(...) / Ω(...).Should(...).
#
# CHANGED CONTRACT — extended via `assertion_helper_patterns` so
# project-specific helpers (e.g. `mustEqual`) can be declared.

set -uo pipefail

# Profile pattern definitions. Each profile is a regex matching
# assertion-related lines. An "assertion change" is a + or - line
# where the regex matches.
_v17_profile_pattern() {
  case "$1" in
    stdlib)
      printf '%s' '\bt\.(Error|Errorf|Fatal|Fatalf|Fail|FailNow|Skip|Skipf|SkipNow)\b|\bif[[:space:]]+[^{]+[[:space:]]*\{[[:space:]]*t\.(Error|Fatal)'
      ;;
    testify)
      printf '%s' '\b(require|assert)\.[A-Z]\w*\b'
      ;;
    gomega)
      printf '%s' '\bExpect\s*\(|\bΩ\s*\('
      ;;
    *)
      printf ''
      ;;
  esac
}

# v1.8.0 AC2 + AC6: AST helper dispatch with graceful degradation.
#
# _v18_ast_check <subcommand> <ast-args...>
#   Stdin: unified diff (already consumed by caller and re-piped).
#   Exit 0: AST passed OR Go/AST is unavailable AND fell back gracefully.
#   Exit 1: AST rejected (caller AND-gates; this means deny).
#
# Honors:
#   - TDD_AST_VALIDATOR_DISABLE=1 — skips AST, warns, exits 0.
#   - Missing `go` binary — same as killswitch (warns, exits 0).
#   - Missing scripts/tdd/ast/validator.go — same as killswitch.
#
# Warnings go to stderr so operators see degradation; the validator
# library proceeds with regex-only enforcement when AST is absent.
_V18_AST_WARNED=0
_v18_ast_check() {
  local subcmd="$1"; shift
  local lib_dir
  lib_dir="$(dirname -- "${BASH_SOURCE[0]}")"
  local validator_go="$lib_dir/ast/validator.go"
  if [[ "${TDD_AST_VALIDATOR_DISABLE:-0}" == "1" ]]; then
    if [[ "$_V18_AST_WARNED" == "0" ]]; then
      echo "[lib_test_edit_exception] WARN: TDD_AST_VALIDATOR_DISABLE=1 — AST checks disabled; falling back to regex-only validation." >&2
      _V18_AST_WARNED=1
    fi
    return 0
  fi
  if ! command -v go >/dev/null 2>&1; then
    if [[ "$_V18_AST_WARNED" == "0" ]]; then
      echo "[lib_test_edit_exception] WARN: Go unavailable; falling back to regex-only validation. Install Go ≥1.26.2 for stricter governance." >&2
      _V18_AST_WARNED=1
    fi
    return 0
  fi
  if [[ ! -f "$validator_go" ]]; then
    if [[ "$_V18_AST_WARNED" == "0" ]]; then
      echo "[lib_test_edit_exception] WARN: AST validator file missing ($validator_go) — falling back to regex-only validation." >&2
      _V18_AST_WARNED=1
    fi
    return 0
  fi
  # Run the helper. It reads the diff from stdin (the caller pipes it).
  local _ast_out
  _ast_out="$(go run "$validator_go" "$subcmd" "$@" 2>&1)"
  local _ast_rc=$?
  if [[ "$_ast_rc" -eq 0 ]]; then
    return 0
  fi
  if [[ "$_ast_rc" -eq 1 ]]; then
    # Reject. Surface report on stderr.
    echo "[lib_test_edit_exception] AST REPORT (subcmd=$subcmd):" >&2
    printf '%s\n' "$_ast_out" >&2
    return 1
  fi
  # Hard error (exit 2) — fail closed.
  echo "[lib_test_edit_exception] AST hard error (subcmd=$subcmd): $_ast_out" >&2
  return 1
}

# Build the active assertion regex from profiles + helpers.
_v17_build_assertion_regex() {
  local config="${1:-.tdd/tdd-config.json}"
  local active="" pat
  if command -v jq >/dev/null 2>&1 && [[ -f "$config" ]]; then
    while IFS= read -r profile; do
      [[ -z "$profile" ]] && continue
      pat=$(_v17_profile_pattern "$profile")
      [[ -n "$pat" ]] && active="${active}${active:+|}${pat}"
    done < <(jq -r '.test_file_policy.post_red_mechanical_update.validators.active_profiles[]?' "$config" 2>/dev/null)
    while IFS= read -r helper; do
      [[ -z "$helper" ]] && continue
      active="${active}${active:+|}\\b${helper}\\b"
    done < <(jq -r '.test_file_policy.post_red_mechanical_update.validators.assertion_helper_patterns[]?' "$config" 2>/dev/null)
  fi
  if [[ -z "$active" ]]; then
    # Defaults: stdlib + testify if config unavailable.
    active="$(_v17_profile_pattern stdlib)|$(_v17_profile_pattern testify)"
  fi
  printf '%s' "$active"
}

# validate_exception_diff <exception-json> <file1> [<file2> ...]
#   reads diff hunks from stdin
validate_exception_diff() {
  local exception_json="${1:-}"
  shift || true
  local files=("$@")

  if ! command -v jq >/dev/null 2>&1; then
    echo "[lib_test_edit_exception] BLOCKED: jq required for validator." >&2
    return 2
  fi
  if ! printf '%s' "$exception_json" | jq -e . >/dev/null 2>&1; then
    echo "[lib_test_edit_exception] BLOCKED: exception payload is not valid JSON." >&2
    return 2
  fi
  local etype
  etype="$(printf '%s' "$exception_json" | jq -r '.type // ""')"
  if [[ -z "$etype" ]]; then
    echo "[lib_test_edit_exception] BLOCKED: exception missing .type field." >&2
    return 2
  fi
  # v1.7.0 round-3 F4: whitelist exception types. Unknown types must
  # be rejected so a forged or future-version artifact can't bypass
  # via "operations: [noop]" or similar.
  case "$etype" in
    mechanical_signature_propagation|compile_fix_only|import_only|schema_predicate_correction) ;;
    *)
      echo "[lib_test_edit_exception] BLOCKED: unknown exception type '$etype'. Allowed: mechanical_signature_propagation, compile_fix_only, import_only, schema_predicate_correction." >&2
      return 2
      ;;
  esac
  local operations
  operations="$(printf '%s' "$exception_json" | jq -r '(.operations // ["edit_existing_tests"]) | join(",")')"
  # v1.7.0 round-3 F4: whitelist operations. Each comma-separated op
  # must be in the known set.
  local _op
  for _op in ${operations//,/ }; do
    case "$_op" in
      edit_existing_tests|create_new_tests) ;;
      *)
        echo "[lib_test_edit_exception] BLOCKED: unknown operation '$_op'. Allowed: edit_existing_tests, create_new_tests." >&2
        return 2
        ;;
    esac
  done

  local diff_input
  diff_input="$(cat 2>/dev/null || true)"

  local assertion_regex
  assertion_regex="$(_v17_build_assertion_regex)"

  # Per-file validation. Build a JSON report incrementally as a jq
  # array of file objects (avoids hand-rolled JSON which choked on
  # empty-string fields — round-1 F5 follow-up).
  local any_failed=false
  local exception_id
  exception_id="$(printf '%s' "$exception_json" | jq -r '.id // "?"')"
  local files_json="[]"
  local f
  for f in "${files[@]}"; do
    local file_status="passed"
    local reason=""
    local evidence=""

    # v1.7.0 round-2 F3: type-specific pre-check. import_only must
    # ONLY change import lines (closing `)` of import block also OK).
    # compile_fix_only must NOT include assertion changes (assertion
    # bodies are not "compile fixes").
    local _file_diff_for_type
    _file_diff_for_type="$(printf '%s\n' "$diff_input" | awk -v base="$(basename "$f")" '
      /^(\+\+\+|---) / {
        if ($0 ~ ("(/|^)" base "$") || $0 ~ ("(/|^)" base "[[:space:]]")) {
          in_block = 1; next
        } else if (in_block) {
          in_block = 0
        }
      }
      in_block { print }
    ')"
    if [[ "$etype" == "import_only" ]] && [[ -n "$_file_diff_for_type" ]]; then
      # v1.7.0 round-5 F4: accept the four canonical Go import forms
      # inside parenthesised blocks: bare ("pkg"), aliased (name "pkg"),
      # blank (_ "pkg"), and dot (. "pkg"). Single-line `import "pkg"`
      # also accepted. The closing `)` of the block, blank lines, and
      # comment lines pass.
      local _bad_nonimport
      _bad_nonimport="$(printf '%s\n' "$_file_diff_for_type" \
        | grep -E '^[+-][^+-]' \
        | grep -vE '^[+-][[:space:]]*import[[:space:]]|^[+-][[:space:]]*[)][[:space:]]*$|^[+-][[:space:]]*[(][[:space:]]*$|^[+-][[:space:]]*("|[._]|[A-Za-z_][A-Za-z0-9_]*)[[:space:]]*("[^"]*")?[[:space:]]*$|^[+-][[:space:]]*$|^[+-][[:space:]]*//.*$' \
        | head -3 || true)"
      if [[ -n "$_bad_nonimport" ]]; then
        file_status="failed"
        reason="import_only: forbid_non_import_hunk — exception type 'import_only' rejects non-import diff lines"
        evidence="$(printf '%s' "$_bad_nonimport" | tr '\n' ';' | sed 's/;$//')"
      fi
      # v1.8.0 AC2.4: AND-gate with AST import-block-check. Catches
      # `+    import "math"` indented inside a function body that the
      # regex import-line filter would let through.
      if [[ "$file_status" == "passed" ]] && [[ -e "$f" ]]; then
        if ! printf '%s' "$diff_input" | _v18_ast_check import-block-check --paths "$f"; then
          file_status="failed"
          reason="import_only: ast_outside_import_block — AST helper rejected change outside import block"
          evidence="(see AST REPORT on stderr)"
        fi
      fi
    fi

    # v1.8.0 AC3 + round-2 F1: schema_predicate_correction — pure
    # rename of scope.old_name to scope.new_name, AST-validated.
    # This type has NO regex fallback, so AST availability is
    # MANDATORY. Killswitch / missing Go / missing validator file
    # → fail closed (operator must either install Go OR pick a
    # different exception type).
    if [[ "$file_status" == "passed" ]] && [[ "$etype" == "schema_predicate_correction" ]]; then
      local _old_name _new_name
      _old_name="$(printf '%s' "$exception_json" | jq -r '.scope.old_name // ""')"
      _new_name="$(printf '%s' "$exception_json" | jq -r '.scope.new_name // ""')"
      if [[ -z "$_old_name" ]] || [[ -z "$_new_name" ]]; then
        file_status="failed"
        reason="schema_predicate_correction: scope.old_name and scope.new_name are required"
        evidence="(missing rename pair)"
      else
        # Hard precondition: AST must be available.
        local _spc_lib_dir _spc_validator_go
        _spc_lib_dir="$(dirname -- "${BASH_SOURCE[0]}")"
        _spc_validator_go="$_spc_lib_dir/ast/validator.go"
        if [[ "${TDD_AST_VALIDATOR_DISABLE:-0}" == "1" ]] \
           || ! command -v go >/dev/null 2>&1 \
           || [[ ! -f "$_spc_validator_go" ]]; then
          file_status="failed"
          reason="schema_predicate_correction: ast_required — this exception type has no regex fallback and the AST helper is unavailable (Go missing, killswitch set, or validator.go absent). Install Go ≥1.26.2 OR pick a different exception type."
          evidence="(AST unavailable — fail closed)"
        elif ! printf '%s' "$diff_input" \
          | _v18_ast_check schema-predicate-check \
              --old-name "$_old_name" --new-name "$_new_name" --paths "$f"; then
          file_status="failed"
          reason="schema_predicate_correction: ast_non_rename_change — AST rejected change (not a pure rename of $_old_name to $_new_name)"
          evidence="(see AST REPORT on stderr)"
        fi
      fi
    fi

    # v1.7.0 round-5 F3: compile_fix_only must restrict every changed
    # line to touch at least one declared symbol from scope.symbols.
    # Without this, compile_fix_only would silently allow any non-
    # assertion edit (e.g., refactoring an unrelated helper).
    if [[ "$file_status" == "passed" ]] && [[ "$etype" == "compile_fix_only" ]] && [[ -n "$_file_diff_for_type" ]]; then
      local _scope_syms
      _scope_syms="$(printf '%s' "$exception_json" | jq -r '(.scope.symbols // []) | join("|")')"
      if [[ -z "$_scope_syms" ]]; then
        file_status="failed"
        reason="compile_fix_only: scope.symbols is empty — type compile_fix_only requires at least one declared symbol"
        evidence="(no scope.symbols)"
      else
        # Build a regex that matches any declared symbol as a word.
        local _sym_regex='\b('"$_scope_syms"')\b'
        local _bad_off_scope
        _bad_off_scope="$(printf '%s\n' "$_file_diff_for_type" \
          | grep -E '^[+-][^+-]' \
          | grep -vE '^[+-][[:space:]]*$|^[+-][[:space:]]*//.*$' \
          | grep -vE "$_sym_regex" \
          | head -3 || true)"
        if [[ -n "$_bad_off_scope" ]]; then
          file_status="failed"
          reason="compile_fix_only: forbid_off_scope_change — line touches no declared symbol from scope.symbols=[$_scope_syms]"
          evidence="$(printf '%s' "$_bad_off_scope" | tr '\n' ';' | sed 's/;$//')"
        fi
      fi
      # v1.8.0 AC2.3: AND-gate with AST compile-fix-scope-check. AST
      # uses identifier matching so `XHelper` is NOT counted as `X`.
      if [[ "$file_status" == "passed" ]] && [[ -n "$_scope_syms" ]]; then
        local _csv_syms="${_scope_syms//|/,}"
        if ! printf '%s' "$diff_input" | _v18_ast_check compile-fix-scope-check --symbols "$_csv_syms" --paths "$f"; then
          file_status="failed"
          reason="compile_fix_only: ast_scope_symbol_not_used — AST rejected change (identifier-level mismatch)"
          evidence="(see AST REPORT on stderr)"
        fi
      fi
    fi

    # Operation: edit_existing_tests — forbid assertion changes.
    # v1.7.0 round-1 F5: extract the per-file hunks from the unified
    # diff (lines between this file's `--- a/<path>`/`+++ b/<path>`
    # header and the next file's header). Without this, an assertion
    # change in a_test.go marked b_test.go as failed too.
    # v1.7.0 round-6 F2: for type=mechanical_signature_propagation,
    # ALLOW assertion-line changes when EVERY changed line touches a
    # declared scope.symbols symbol (call-site widening inside an
    # assertion is the canonical use case for this exception type).
    # v1.7.0 round-6 F4: also enforce no_test_deletion (removed
    # `func TestXxx(...)` lines) and no_empty_t_run (added
    # `t.Run(...) { }` with empty body).
    if [[ "$file_status" == "passed" ]] && [[ ",$operations," == *",edit_existing_tests,"* ]] && [[ -e "$f" ]]; then
      local fbase
      fbase="$(basename "$f")"
      local file_diff
      file_diff="$(printf '%s\n' "$diff_input" | awk -v base="$fbase" '
        /^(\+\+\+|---) / {
          if ($0 ~ ("(/|^)" base "$") || $0 ~ ("(/|^)" base "[[:space:]]")) {
            in_block = 1; next
          } else if (in_block) {
            in_block = 0
          }
        }
        in_block { print }
      ')"
      # v1.7.0 round-6 F4a: no_test_deletion — reject `-func TestX(`
      # lines that have NO matching `+func TestX(` (a true removal, not
      # a same-name modification).
      local _removed_names _added_names _orphan
      _removed_names="$(printf '%s\n' "$file_diff" \
        | grep -E '^-[[:space:]]*func[[:space:]]+Test[A-Z][A-Za-z0-9_]*[[:space:]]*\(' \
        | sed -E 's/^-[[:space:]]*func[[:space:]]+(Test[A-Z][A-Za-z0-9_]*).*/\1/' \
        | sort -u || true)"
      _added_names="$(printf '%s\n' "$file_diff" \
        | grep -E '^\+[[:space:]]*func[[:space:]]+Test[A-Z][A-Za-z0-9_]*[[:space:]]*\(' \
        | sed -E 's/^\+[[:space:]]*func[[:space:]]+(Test[A-Z][A-Za-z0-9_]*).*/\1/' \
        | sort -u || true)"
      if [[ -n "$_removed_names" ]]; then
        _orphan="$(comm -23 <(printf '%s\n' "$_removed_names") <(printf '%s\n' "$_added_names") | head -1)"
        if [[ -n "$_orphan" ]]; then
          file_status="failed"
          reason="no_test_deletion: removed Test function '$_orphan' has no matching addition (deletion of TestXxx is forbidden)"
          evidence="$_orphan"
        fi
      fi
      # v1.7.0 round-6 F4b: no_empty_t_run — reject `+t.Run(..., func(...) {})`
      # with empty body (single-line empty subtest).
      if [[ "$file_status" == "passed" ]]; then
        local _empty_run
        _empty_run="$(printf '%s\n' "$file_diff" \
          | grep -E '^\+[[:space:]]*t\.Run[[:space:]]*\([^)]*,[[:space:]]*func[[:space:]]*\([^)]*\)[[:space:]]*\{[[:space:]]*\}' \
          | head -1 || true)"
        if [[ -n "$_empty_run" ]]; then
          file_status="failed"
          reason="no_empty_t_run: empty t.Run subtest added (subtest must contain assertions)"
          evidence="$_empty_run"
        fi
      fi
      if [[ "$file_status" == "passed" ]]; then
        local bad_lines
        bad_lines="$(printf '%s' "$file_diff" \
                      | grep -E "^[+-]" \
                      | grep -vE '^---|^\+\+\+' \
                      | grep -E "$assertion_regex" \
                      || true)"
        if [[ -n "$bad_lines" ]]; then
          # v1.7.0 round-6 F2: for mechanical_signature_propagation,
          # accept the change if EVERY +/- assertion-line change
          # touches at least one declared scope.symbols symbol.
          # v1.7.0 round-7 F1: ALSO require the assertion-helper
          # tokens (require.X / assert.X / t.Errorf / Expect) to be
          # the SAME set on - and + sides — operator/comparator must
          # not change. This prevents require.Equal -> require.NoError
          # from passing just because Do is on both sides.
          local _symbol_safe=false
          if [[ "$etype" == "mechanical_signature_propagation" ]]; then
            local _scope_syms_for_assert
            _scope_syms_for_assert="$(printf '%s' "$exception_json" | jq -r '(.scope.symbols // []) | join("|")')"
            if [[ -n "$_scope_syms_for_assert" ]]; then
              local _sym_assert_regex='\b('"$_scope_syms_for_assert"')\b'
              local _bad_off_sym
              _bad_off_sym="$(printf '%s' "$bad_lines" \
                | grep -vE "$_sym_assert_regex" \
                | head -1 || true)"
              if [[ -z "$_bad_off_sym" ]]; then
                # Symbols present on every line. Now check helper
                # shape: extract the set of assertion-helper tokens
                # from the - lines and from the + lines; they must
                # be identical (same multiset of helpers).
                local _minus_helpers _plus_helpers
                _minus_helpers="$(printf '%s\n' "$bad_lines" \
                  | grep -E '^-' \
                  | grep -oE "$assertion_regex" \
                  | sort | uniq -c || true)"
                _plus_helpers="$(printf '%s\n' "$bad_lines" \
                  | grep -E '^\+' \
                  | grep -oE "$assertion_regex" \
                  | sort | uniq -c || true)"
                if [[ "$_minus_helpers" == "$_plus_helpers" ]]; then
                  _symbol_safe=true
                else
                  file_status="failed"
                  reason="forbid_assertion_helper_change: assertion helper/comparator changed (mechanical_signature_propagation requires unchanged assertion shape; only call-site arguments may change)"
                  evidence="minus=$(printf '%s' "$_minus_helpers" | tr '\n' ',' | sed 's/,$//');plus=$(printf '%s' "$_plus_helpers" | tr '\n' ',' | sed 's/,$//')"
                fi
              fi
            fi
          fi
          if [[ "$_symbol_safe" != "true" ]] && [[ "$file_status" == "passed" ]]; then
            file_status="failed"
            reason="forbid_assertion_changes_for_existing_tests: assertion change detected"
            evidence="$(printf '%s' "$bad_lines" | head -2 | tr '\n' ';' | sed 's/;$//')"
          fi
        fi
      fi
      # v1.7.0 round-7 F2: for mechanical_signature_propagation,
      # ALSO require every NON-assertion +/- line (excluding blank,
      # comment, import shape) to touch a declared scope.symbols
      # symbol. Without this, a broad approved exception would
      # silently allow setup-data, helper, or table-case edits.
      if [[ "$file_status" == "passed" ]] && [[ "$etype" == "mechanical_signature_propagation" ]]; then
        local _scope_syms_all
        _scope_syms_all="$(printf '%s' "$exception_json" | jq -r '(.scope.symbols // []) | join("|")')"
        if [[ -n "$_scope_syms_all" ]]; then
          local _sym_all_regex='\b('"$_scope_syms_all"')\b'
          local _off_scope_nonassert
          _off_scope_nonassert="$(printf '%s\n' "$file_diff" \
            | grep -E '^[+-][^+-]' \
            | grep -vE '^---|^\+\+\+' \
            | grep -vE '^[+-][[:space:]]*$' \
            | grep -vE '^[+-][[:space:]]*//.*$' \
            | grep -vE '^[+-][[:space:]]*import[[:space:]]' \
            | grep -vE "$assertion_regex" \
            | grep -vE "$_sym_all_regex" \
            | head -1 || true)"
          if [[ -n "$_off_scope_nonassert" ]]; then
            file_status="failed"
            reason="mech_sig_prop_off_scope: non-assertion change touches no declared symbol from scope.symbols=[$_scope_syms_all]"
            evidence="$_off_scope_nonassert"
          fi
        fi
      fi
      # v1.8.0 AC2.2: AND-gate with AST mech-sig-prop-check for assertion
      # helper-shape preservation. Catches cases where the regex multiset
      # check might be fooled by similar tokens.
      if [[ "$file_status" == "passed" ]] && [[ "$etype" == "mechanical_signature_propagation" ]]; then
        if ! printf '%s' "$diff_input" | _v18_ast_check mech-sig-prop-check --paths "$f"; then
          file_status="failed"
          reason="mechanical_signature_propagation: ast_helper_shape_changed — AST rejected helper/comparator change"
          evidence="(see AST REPORT on stderr)"
        fi
      fi
    fi

    # v1.7.0 round-5 F2: create_new_tests must fail closed when the
    # target path doesn't exist (caller failed to materialize proposed
    # content). Previously this branch was guarded by `[[ -e "$f" ]]`
    # which silently allowed unverifiable Writes.
    if [[ ",$operations," == *",create_new_tests,"* ]] && [[ ! -e "$f" ]]; then
      file_status="failed"
      reason="create_new_tests: cannot validate content — file does not exist at validator path '$f' (hook failed to materialize proposed Write/MultiEdit content)"
      evidence="(no file at $f)"
    fi

    # Operation: create_new_tests — require assertions in new file.
    if [[ "$file_status" == "passed" ]] && [[ ",$operations," == *",create_new_tests,"* ]] && [[ -e "$f" ]]; then
      local has_test_func has_assertion has_skip
      # `grep -c` returns 0 lines when nothing matches; on bsd-grep
      # without GNU coreutils it sometimes still emits "0\n". Use
      # explicit grep + wc to get a clean integer.
      has_test_func=$(grep -cE 'func[[:space:]]+Test[A-Z][A-Za-z0-9_]*[[:space:]]*\(' "$f" 2>/dev/null | head -1)
      has_assertion=$(grep -cE "$assertion_regex" "$f" 2>/dev/null | head -1)
      has_skip=$(grep -cE '\bt\.Skip(f|Now)?\b' "$f" 2>/dev/null | head -1)
      [[ -z "$has_test_func" ]] && has_test_func=0
      [[ -z "$has_assertion" ]] && has_assertion=0
      [[ -z "$has_skip" ]] && has_skip=0
      if [[ "$has_test_func" -lt 1 ]] || [[ "$has_assertion" -lt 1 ]]; then
        file_status="failed"
        reason="require_assertions_for_new_tests: missing assertion (no $assertion_regex matches in file)"
        evidence="found $has_test_func TestXxx, $has_assertion assertions"
      elif [[ "$has_skip" -gt 0 ]]; then
        file_status="failed"
        reason="no_skip_added: file contains t.Skip"
        evidence="$(grep -nE '\bt\.Skip(f|Now)?\b' "$f" 2>/dev/null | head -1)"
      fi
    fi

    if [[ "$file_status" == "failed" ]]; then
      any_failed=true
    fi
    files_json="$(jq -c \
      --arg path "$f" \
      --arg status "$file_status" \
      --arg reason "$reason" \
      --arg evidence "$evidence" \
      '. + [{path: $path, status: $status, reason: $reason, evidence: $evidence}]' \
      <<<"$files_json")"
  done
  local report
  report="$(jq -c -n --arg id "$exception_id" --argjson files "$files_json" \
    '{exception_id: $id, files: $files}')"

  if [[ "$any_failed" == "true" ]]; then
    printf '%s\n' "$report" >&2
    # Per-file failure message (the smoke test greps for filename + 'fail').
    printf '%s' "$report" | jq -r '.files[] | select(.status == "failed") | .path + ": failed (" + .reason + ")"' >&2
    return 1
  fi
  return 0
}

# CLI dispatch when invoked directly (not sourced).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    validate_exception_diff)
      validate_exception_diff "$@"
      ;;
    *)
      echo "usage: $0 validate_exception_diff <exception-json> <file1> [<file2> ...]" >&2
      exit 2
      ;;
  esac
fi
