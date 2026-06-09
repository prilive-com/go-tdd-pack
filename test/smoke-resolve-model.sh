#!/usr/bin/env bash
# test/smoke-resolve-model.sh
#
# v2.3 slice 1 — exercises runner/lib/resolve-model.sh's full API
# surface (every non-cache branch is real, `auto` is a stub) +
# validates every fixture in test/fixtures/codex-models-cache/
# against schemas/codex-models-cache.schema.json.
#
# Slice 1 acceptance (PROPOSAL-model-auto-select.md addendum §11):
#   - Pin passthrough preserves the literal slug.
#   - Empty string passes through unchanged (v2.1.x semantics).
#   - "cli-default" → "" + deprecation warning.
#   - "auto" → fallback + slice-1-stub warning.
#   - Invalid input (whitespace/control chars) → exit 2.
#   - Fallback default is configurable via PRILIVE_MODEL_FALLBACK.
#   - resolve_codex_model_describe emits operator-readable lines.
#   - Every valid-* fixture parses as JSON.
#   - Every failure-mode fixture is invalid in the documented way.
#
# Slice 2 will extend this smoke with end-to-end "auto resolves to
# the cached slug" assertions; slice 1 ships the contract proof.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="${PROJECT_ROOT}/runner/lib/resolve-model.sh"
SCHEMA="${PROJECT_ROOT}/schemas/codex-models-cache.schema.json"
FIXTURE_DIR="${PROJECT_ROOT}/test/fixtures/codex-models-cache"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
PASS_COUNT=0

[[ -f "${LIB}" ]] || fail "resolver lib not found: ${LIB}"
[[ -f "${SCHEMA}" ]] || fail "schema not found: ${SCHEMA}"
[[ -d "${FIXTURE_DIR}" ]] || fail "fixture dir not found: ${FIXTURE_DIR}"
command -v jq >/dev/null 2>&1 || fail "jq required (declared dep per MAJOR M2)"

# shellcheck source=../runner/lib/resolve-model.sh
. "${LIB}"

# ============================================================
# Resolver API — non-cache branches (real)
# ============================================================

info "[1] pin passthrough — concrete slug echoes verbatim"
OUT=$(resolve_codex_model "gpt-5.5" 2>/dev/null)
[[ "${OUT}" == "gpt-5.5" ]] || fail "case 1: expected gpt-5.5, got: ${OUT}"
pass "pin passthrough: gpt-5.5 → gpt-5.5"
PASS_COUNT=$((PASS_COUNT+1))

info "[1b] pin passthrough — alternate slug echoes verbatim"
OUT=$(resolve_codex_model "gpt-5.4-mini" 2>/dev/null)
[[ "${OUT}" == "gpt-5.4-mini" ]] || fail "case 1b: expected gpt-5.4-mini, got: ${OUT}"
pass "pin passthrough: gpt-5.4-mini → gpt-5.4-mini"
PASS_COUNT=$((PASS_COUNT+1))

info "[2] empty string preserves v2.1.x semantics (MAJOR M3)"
OUT=$(resolve_codex_model "" 2>/dev/null)
[[ "${OUT}" == "" ]] || fail "case 2: expected empty, got: '${OUT}'"
pass "empty: '' → '' (defer to Codex CLI default; v2.1.x preserved)"
PASS_COUNT=$((PASS_COUNT+1))

info "[2b] empty string does NOT emit deprecation warning"
ERR=$(resolve_codex_model "" 2>&1 >/dev/null)
[[ -z "${ERR}" ]] || fail "case 2b: expected no stderr for empty, got: ${ERR}"
pass "empty: no warning (literal v2.1.x behavior; addendum MAJOR M3)"
PASS_COUNT=$((PASS_COUNT+1))

info "[3] cli-default → empty + deprecation warning to stderr"
OUT=$(resolve_codex_model "cli-default" 2>/dev/null)
ERR=$(resolve_codex_model "cli-default" 2>&1 >/dev/null)
[[ "${OUT}" == "" ]] || fail "case 3: cli-default should echo empty, got: '${OUT}'"
echo "${ERR}" | grep -qE 'cli-default|v2.1.1|defers' || fail "case 3: expected deprecation warning, got: ${ERR}"
pass "cli-default: '' + deprecation note on stderr (MAJOR M3 closure)"
PASS_COUNT=$((PASS_COUNT+1))

info "[4] auto (stub) → fallback + slice-1 stub warning"
OUT=$(resolve_codex_model "auto" 2>/dev/null)
ERR=$(resolve_codex_model "auto" 2>&1 >/dev/null)
[[ "${OUT}" == "gpt-5.5" ]] || fail "case 4: expected default fallback gpt-5.5, got: '${OUT}'"
echo "${ERR}" | grep -qE 'slice 1|stub|auto' || fail "case 4: expected stub warning, got: ${ERR}"
pass "auto (stub): → gpt-5.5 with stub-warning on stderr (slice 2 will read cache)"
PASS_COUNT=$((PASS_COUNT+1))

info "[4b] auto (stub) honors PRILIVE_MODEL_FALLBACK override"
OUT=$(PRILIVE_MODEL_FALLBACK=gpt-4.9 resolve_codex_model "auto" 2>/dev/null)
[[ "${OUT}" == "gpt-4.9" ]] || fail "case 4b: env override ignored; got '${OUT}'"
pass "auto: PRILIVE_MODEL_FALLBACK=gpt-4.9 → gpt-4.9 (env overrides fallback)"
PASS_COUNT=$((PASS_COUNT+1))

info "[4c] auto stub warning includes auth_mode hint (default = subscription)"
ERR=$(resolve_codex_model "auto" 2>&1 >/dev/null)
echo "${ERR}" | grep -qF 'subscription' || fail "case 4c: expected 'subscription' in stub warning, got: ${ERR}"
pass "auto: default auth_mode=subscription surfaces in warning"
PASS_COUNT=$((PASS_COUNT+1))

info "[4d] auto stub honors explicit auth_mode arg"
ERR=$(resolve_codex_model "auto" "api_key" 2>&1 >/dev/null)
echo "${ERR}" | grep -qF 'api_key' || fail "case 4d: expected 'api_key' in stub warning, got: ${ERR}"
pass "auto: explicit auth_mode=api_key threads through to warning"
PASS_COUNT=$((PASS_COUNT+1))

info "[5] invalid input — whitespace in slug → exit 2"
set +e
resolve_codex_model "gpt 5.5" 2>/dev/null
RC=$?
set -e
[[ ${RC} -eq 2 ]] || fail "case 5: expected exit 2, got: ${RC}"
pass "invalid: 'gpt 5.5' (embedded space) → exit 2"
PASS_COUNT=$((PASS_COUNT+1))

info "[5b] invalid input — tab character → exit 2"
set +e
resolve_codex_model $'gpt-5.5\t' 2>/dev/null
RC=$?
set -e
[[ ${RC} -eq 2 ]] || fail "case 5b: expected exit 2 for tab, got: ${RC}"
pass "invalid: trailing tab → exit 2"
PASS_COUNT=$((PASS_COUNT+1))

info "[5c] counterfactual — empty string is NOT rejected as invalid"
set +e
resolve_codex_model "" 2>/dev/null
RC=$?
set -e
[[ ${RC} -eq 0 ]] || fail "case 5c: empty must NOT be rejected; got rc=${RC}"
pass "counterfactual: '' is valid (preserves v2.1.x)"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# resolve_codex_model_describe — operator-visible logging
# ============================================================

info "[6] describe: pin → 'pinned via tdd-pack.toml'"
LINE=$(resolve_codex_model_describe "gpt-5.5" "gpt-5.5")
echo "${LINE}" | grep -qF 'pinned' || fail "case 6: expected 'pinned' in describe, got: ${LINE}"
pass "describe(pin): mentions 'pinned'"
PASS_COUNT=$((PASS_COUNT+1))

info "[6b] describe: empty → mentions Codex CLI default"
LINE=$(resolve_codex_model_describe "" "")
echo "${LINE}" | grep -qF 'Codex CLI default' || fail "case 6b: expected Codex-CLI-default mention, got: ${LINE}"
pass "describe(empty): mentions Codex CLI default"
PASS_COUNT=$((PASS_COUNT+1))

info "[6c] describe: cli-default → mentions deprecated"
LINE=$(resolve_codex_model_describe "cli-default" "")
echo "${LINE}" | grep -qF 'deprecated' || fail "case 6c: expected 'deprecated' in describe, got: ${LINE}"
pass "describe(cli-default): mentions deprecated"
PASS_COUNT=$((PASS_COUNT+1))

info "[6d] describe: auto → mentions slice 1 stub + slice 2 reference"
LINE=$(resolve_codex_model_describe "auto" "gpt-5.5")
echo "${LINE}" | grep -qF 'slice 1 stub' || fail "case 6d: expected 'slice 1 stub' in describe, got: ${LINE}"
echo "${LINE}" | grep -qF 'slice 2' || fail "case 6d: expected 'slice 2' reference in describe, got: ${LINE}"
pass "describe(auto): mentions slice 1 stub + slice 2 plan (observability MVP, not optional per M5)"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# Fixture validation — JSON parse + schema-required field check
#
# Slice 1 locks the fixture contract for slice 2. We don't run a
# full JSON-Schema validator (no ajv in CI deps), but we DO check:
#   - every fixture parses as JSON (or is the documented not-json
#     case)
#   - valid-* fixtures have the schema's top-level required fields
#   - failure-mode fixtures lack those fields in the documented way
# ============================================================

info "[7] fixture: valid-typical.json parses + top-level required present"
jq empty "${FIXTURE_DIR}/valid-typical.json" 2>/dev/null || fail "case 7: valid-typical not JSON"
for k in client_version fetched_at models; do
  has=$(jq --arg k "$k" 'has($k)' "${FIXTURE_DIR}/valid-typical.json")
  [[ "${has}" == "true" ]] || fail "case 7: valid-typical missing required '$k'"
done
TOP=$(jq -r '.models | sort_by(.priority) | .[0].slug' "${FIXTURE_DIR}/valid-typical.json")
[[ "${TOP}" == "gpt-5.5" ]] || fail "case 7: valid-typical top-priority slug should be gpt-5.5, got: ${TOP}"
pass "valid-typical: parses, has client_version+fetched_at+models, top-priority = gpt-5.5"
PASS_COUNT=$((PASS_COUNT+1))

info "[7b] fixture: valid-role-filter-edge plants role-inappropriate top entries"
jq empty "${FIXTURE_DIR}/valid-role-filter-edge.json" 2>/dev/null || fail "case 7b: not JSON"
TOP_RAW=$(jq -r '.models | sort_by(.priority) | .[0].slug' "${FIXTURE_DIR}/valid-role-filter-edge.json")
[[ "${TOP_RAW}" == "codex-auto-review" ]] || fail "case 7b: top of cache should be codex-auto-review (pre-filter), got: ${TOP_RAW}"
# Sanity: the eventual winner (gpt-5.5) is present somewhere in the cache.
jq -e '.models[] | select(.slug == "gpt-5.5")' "${FIXTURE_DIR}/valid-role-filter-edge.json" > /dev/null \
  || fail "case 7b: gpt-5.5 missing from fixture"
pass "valid-role-filter-edge: pre-filter top = codex-auto-review (slice 2 must drop it)"
PASS_COUNT=$((PASS_COUNT+1))

info "[7c] fixture: valid-hide-edge has visibility=hide at top priority"
jq empty "${FIXTURE_DIR}/valid-hide-edge.json" 2>/dev/null || fail "case 7c: not JSON"
TOP_VIS=$(jq -r '.models | sort_by(.priority) | .[0].visibility' "${FIXTURE_DIR}/valid-hide-edge.json")
[[ "${TOP_VIS}" == "hide" ]] || fail "case 7c: top-priority entry should be visibility=hide, got: ${TOP_VIS}"
pass "valid-hide-edge: top entry is hide (slice 2 must skip)"
PASS_COUNT=$((PASS_COUNT+1))

info "[7d] fixture: valid-api-only-edge — top has supported_in_api=false"
TOP_API=$(jq -r '.models | sort_by(.priority) | .[0].supported_in_api' "${FIXTURE_DIR}/valid-api-only-edge.json")
[[ "${TOP_API}" == "false" ]] || fail "case 7d: top entry should be supported_in_api=false, got: ${TOP_API}"
pass "valid-api-only-edge: top entry supported_in_api=false (slice 2: api_key skips, subscription keeps)"
PASS_COUNT=$((PASS_COUNT+1))

info "[8] failure-mode fixtures — each is invalid in the documented way"

info "[8a] missing-priority: top entry has no priority field"
jq empty "${FIXTURE_DIR}/missing-priority.json" 2>/dev/null || fail "case 8a: not JSON"
HAS_PRI=$(jq '.models[0] | has("priority")' "${FIXTURE_DIR}/missing-priority.json")
[[ "${HAS_PRI}" == "false" ]] || fail "case 8a: top entry should be missing priority"
pass "missing-priority: top entry missing priority (slice 2 must drop)"
PASS_COUNT=$((PASS_COUNT+1))

info "[8b] string-priority: top entry has string priority"
TYPE=$(jq -r '.models[0].priority | type' "${FIXTURE_DIR}/string-priority.json")
[[ "${TYPE}" == "string" ]] || fail "case 8b: top priority should be string, got: ${TYPE}"
pass "string-priority: top priority is string (slice 2 must drop entry)"
PASS_COUNT=$((PASS_COUNT+1))

info "[8c] duplicate-priority: two entries share priority value"
DUPS=$(jq '[.models[].priority] | group_by(.) | map(select(length > 1)) | length' "${FIXTURE_DIR}/duplicate-priority.json")
[[ "${DUPS}" -gt 0 ]] || fail "case 8c: expected at least one duplicate priority"
pass "duplicate-priority: contains tied priorities (slice 2 must use slug-asc tiebreaker)"
PASS_COUNT=$((PASS_COUNT+1))

info "[8d] null-fields: optional fields are null but required present"
HAS_SLUG=$(jq '.models[0].slug != null' "${FIXTURE_DIR}/null-fields.json")
HAS_DISPLAY=$(jq '.models[0].display_name == null' "${FIXTURE_DIR}/null-fields.json")
[[ "${HAS_SLUG}" == "true" ]] || fail "case 8d: slug must be non-null"
[[ "${HAS_DISPLAY}" == "true" ]] || fail "case 8d: display_name should be null"
pass "null-fields: optional fields null, required present (slice 2 must tolerate)"
PASS_COUNT=$((PASS_COUNT+1))

info "[8e] empty-models: models is an empty array"
LEN=$(jq '.models | length' "${FIXTURE_DIR}/empty-models.json")
[[ "${LEN}" -eq 0 ]] || fail "case 8e: models should be empty, got length: ${LEN}"
pass "empty-models: models=[] (slice 2 must fall back with warning)"
PASS_COUNT=$((PASS_COUNT+1))

info "[8f] not-json.txt: present but not parseable as JSON"
[[ -f "${FIXTURE_DIR}/not-json.txt" ]] || fail "case 8f: not-json.txt missing"
jq empty "${FIXTURE_DIR}/not-json.txt" 2>/dev/null && fail "case 8f: not-json.txt should NOT parse as JSON"
pass "not-json.txt: present but invalid JSON (slice 2 must fall back with warning)"
PASS_COUNT=$((PASS_COUNT+1))

info "[8g] missing-required: top-level lacks client_version + fetched_at"
HAS_VER=$(jq 'has("client_version")' "${FIXTURE_DIR}/missing-required.json")
HAS_TS=$(jq 'has("fetched_at")' "${FIXTURE_DIR}/missing-required.json")
[[ "${HAS_VER}" == "false" ]] || fail "case 8g: should lack client_version"
[[ "${HAS_TS}" == "false" ]] || fail "case 8g: should lack fetched_at"
pass "missing-required: top-level missing client_version+fetched_at (slice 2 must fall back)"
PASS_COUNT=$((PASS_COUNT+1))

# ============================================================
# Schema sanity — the cache schema parses + declares its required set
# ============================================================

info "[9] cache schema parses + declares the resolver's required field set"
jq empty "${SCHEMA}" || fail "case 9: schema does not parse as JSON"
REQ=$(jq -r '.required | join(",")' "${SCHEMA}")
[[ "${REQ}" == "client_version,fetched_at,models" ]] || fail "case 9: top-level required mismatch: ${REQ}"
SLUG_REQ=$(jq -r '.properties.models.items.required | join(",")' "${SCHEMA}")
[[ "${SLUG_REQ}" == "slug,priority,visibility" ]] || fail "case 9: model-level required mismatch: ${SLUG_REQ}"
pass "schema: declares top-level [client_version,fetched_at,models] + model [slug,priority,visibility]"
PASS_COUNT=$((PASS_COUNT+1))

# ---- summary ----

echo ""
echo "================================================================"
echo "  RESOLVE-MODEL SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"
exit 0
