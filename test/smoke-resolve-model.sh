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

info "[4] auto + missing cache + subscription auth → fallback to gpt-5.5"
OUT=$(env -i HOME="${HOME}" PATH="${PATH}" bash -c "
  . '${LIB}'
  PRILIVE_MODELS_CACHE=/nonexistent/cache.json resolve_codex_model 'auto'
" 2>/dev/null)
ERR=$(env -i HOME="${HOME}" PATH="${PATH}" bash -c "
  . '${LIB}'
  PRILIVE_MODELS_CACHE=/nonexistent/cache.json resolve_codex_model 'auto'
" 2>&1 >/dev/null)
[[ "${OUT}" == "gpt-5.5" ]] || fail "case 4: expected subscription fallback gpt-5.5, got: '${OUT}'"
echo "${ERR}" | grep -qE 'absent|missing|cache' || fail "case 4: expected absent-cache warning, got: ${ERR}"
pass "auto: missing cache + subscription → gpt-5.5 + absent-cache warning"
PASS_COUNT=$((PASS_COUNT+1))

info "[4-aa] v2.3.1 — auto + missing cache + api_key auth → fallback to gpt-5.2-codex"
OUT=$(CODEX_API_KEY=test PRILIVE_MODELS_CACHE=/nonexistent/cache.json resolve_codex_model "auto" 2>/dev/null)
[[ "${OUT}" == "gpt-5.2-codex" ]] || fail "case 4-aa: api_key fallback should be gpt-5.2-codex (NOT gpt-5.5 — that 400s under api_key per OpenAI June-2026); got: '${OUT}'"
pass "auto: missing cache + api_key → gpt-5.2-codex (closes the v2.1.1-class api_key fallback bug)"
PASS_COUNT=$((PASS_COUNT+1))

info "[4-ab] counterfactual — subscription fallback is NOT gpt-5.2-codex"
OUT=$(env -i HOME="${HOME}" PATH="${PATH}" bash -c "
  . '${LIB}'
  PRILIVE_MODELS_CACHE=/nonexistent resolve_codex_model 'auto'
" 2>/dev/null)
[[ "${OUT}" != "gpt-5.2-codex" ]] || fail "case 4-ab: subscription should NOT get api_key default; got: '${OUT}'"
pass "counterfactual: subscription path does NOT cross over to api_key default"
PASS_COUNT=$((PASS_COUNT+1))

info "[4b] auto honors PRILIVE_MODEL_FALLBACK override on fallback path (subscription)"
OUT=$(env -i HOME="${HOME}" PATH="${PATH}" bash -c "
  . '${LIB}'
  PRILIVE_MODELS_CACHE=/nonexistent PRILIVE_MODEL_FALLBACK=gpt-4.9 resolve_codex_model 'auto'
" 2>/dev/null)
[[ "${OUT}" == "gpt-4.9" ]] || fail "case 4b: env override ignored under subscription; got '${OUT}'"
pass "auto: PRILIVE_MODEL_FALLBACK=gpt-4.9 → gpt-4.9 on subscription fallback"
PASS_COUNT=$((PASS_COUNT+1))

info "[4b-aa] v2.3.1 — PRILIVE_MODEL_FALLBACK override wins over api_key default"
OUT=$(CODEX_API_KEY=test PRILIVE_MODELS_CACHE=/nonexistent PRILIVE_MODEL_FALLBACK=gpt-4.9 resolve_codex_model "auto" 2>/dev/null)
[[ "${OUT}" == "gpt-4.9" ]] || fail "case 4b-aa: explicit fallback should beat api_key default; got: '${OUT}'"
pass "auto: PRILIVE_MODEL_FALLBACK wins over api_key auth-aware default"
PASS_COUNT=$((PASS_COUNT+1))

info "[4b-ab] v2.3.1 — fallback function directly, both auth modes"
SUB=$(resolve_codex_model_fallback subscription 2>/dev/null)
API=$(resolve_codex_model_fallback api_key 2>/dev/null)
UNSET=$(env -i HOME="${HOME}" PATH="${PATH}" bash -c ". '${LIB}'; resolve_codex_model_fallback" 2>/dev/null)
[[ "${SUB}" == "gpt-5.5" ]]       || fail "case 4b-ab: subscription should be gpt-5.5; got '${SUB}'"
[[ "${API}" == "gpt-5.2-codex" ]] || fail "case 4b-ab: api_key should be gpt-5.2-codex; got '${API}'"
[[ "${UNSET}" == "gpt-5.5" ]]     || fail "case 4b-ab: missing auth_mode should default to subscription/gpt-5.5; got '${UNSET}'"
pass "resolve_codex_model_fallback: subscription=gpt-5.5, api_key=gpt-5.2-codex, unset=gpt-5.5 (back-compat)"
PASS_COUNT=$((PASS_COUNT+1))

info "[4c] auto with valid-typical fixture → resolves to gpt-5.5 (top priority)"
OUT=$(PRILIVE_MODELS_CACHE="${FIXTURE_DIR}/valid-typical.json" resolve_codex_model "auto" 2>/dev/null)
[[ "${OUT}" == "gpt-5.5" ]] || fail "case 4c: expected gpt-5.5 from cache, got: '${OUT}'"
pass "auto + valid-typical cache → gpt-5.5 (priority 9, list-visible)"
PASS_COUNT=$((PASS_COUNT+1))

info "[4d] auto with valid-role-filter-edge → filters role-inappropriate, returns gpt-5.5"
OUT=$(PRILIVE_MODELS_CACHE="${FIXTURE_DIR}/valid-role-filter-edge.json" resolve_codex_model "auto" 2>/dev/null)
[[ "${OUT}" == "gpt-5.5" ]] || fail "case 4d: expected gpt-5.5 after role filter, got: '${OUT}' (filter must drop codex-auto-review/-spark/-mini)"
pass "auto: role-suitability filter drops *-auto-review, *-spark, *-mini → gpt-5.5 (closes BLOCKER 1/MAJOR M1)"
PASS_COUNT=$((PASS_COUNT+1))

info "[4e] auto with valid-hide-edge → skips visibility=hide, returns gpt-5.5"
OUT=$(PRILIVE_MODELS_CACHE="${FIXTURE_DIR}/valid-hide-edge.json" resolve_codex_model "auto" 2>/dev/null)
[[ "${OUT}" == "gpt-5.5" ]] || fail "case 4e: expected gpt-5.5 after hide-filter, got: '${OUT}'"
pass "auto: visibility=hide filtered → gpt-5.5"
PASS_COUNT=$((PASS_COUNT+1))

info "[4f] auto + api-only-edge + subscription → returns subscription-only top entry"
OUT=$(PRILIVE_MODELS_CACHE="${FIXTURE_DIR}/valid-api-only-edge.json" resolve_codex_model "auto" "subscription" 2>/dev/null)
[[ "${OUT}" == "gpt-5.5-subscription-only" ]] || fail "case 4f: subscription should keep supported_in_api=false top model; got '${OUT}'"
pass "auto: subscription auth keeps supported_in_api=false top entry"
PASS_COUNT=$((PASS_COUNT+1))

info "[4g] auto + api-only-edge + api_key → skips subscription-only, returns next"
OUT=$(PRILIVE_MODELS_CACHE="${FIXTURE_DIR}/valid-api-only-edge.json" resolve_codex_model "auto" "api_key" 2>/dev/null)
[[ "${OUT}" == "gpt-5.4" ]] || fail "case 4g: api_key should skip supported_in_api=false; got '${OUT}'"
pass "auto: api_key auth filters supported_in_api=false, returns next-priority"
PASS_COUNT=$((PASS_COUNT+1))

info "[4h] auto + missing-priority → drops broken entry, returns next"
OUT=$(PRILIVE_MODELS_CACHE="${FIXTURE_DIR}/missing-priority.json" resolve_codex_model "auto" 2>/dev/null)
[[ "${OUT}" == "gpt-5.5" ]] || fail "case 4h: expected gpt-5.5 after dropping no-priority entry; got '${OUT}'"
pass "auto: missing priority → entry dropped → gpt-5.5"
PASS_COUNT=$((PASS_COUNT+1))

info "[4i] auto + string-priority → drops type-mismatch entry, returns next"
OUT=$(PRILIVE_MODELS_CACHE="${FIXTURE_DIR}/string-priority.json" resolve_codex_model "auto" 2>/dev/null)
[[ "${OUT}" == "gpt-5.5" ]] || fail "case 4i: expected gpt-5.5 after dropping string-priority entry; got '${OUT}'"
pass "auto: string-typed priority → entry dropped → gpt-5.5"
PASS_COUNT=$((PASS_COUNT+1))

info "[4j] auto + duplicate-priority → deterministic slug-asc tiebreaker"
OUT=$(PRILIVE_MODELS_CACHE="${FIXTURE_DIR}/duplicate-priority.json" resolve_codex_model "auto" 2>/dev/null)
# Both have priority 9; slug-asc: gpt-5.5 < gpt-5.5-beta
[[ "${OUT}" == "gpt-5.5" ]] || fail "case 4j: tiebreaker should pick lexicographically-first slug; got '${OUT}'"
pass "auto: tied priority → slug-asc tiebreaker picks gpt-5.5"
PASS_COUNT=$((PASS_COUNT+1))

info "[4k] auto + null-fields → tolerates nulls on optional fields"
OUT=$(PRILIVE_MODELS_CACHE="${FIXTURE_DIR}/null-fields.json" resolve_codex_model "auto" 2>/dev/null)
[[ "${OUT}" == "gpt-5.5" ]] || fail "case 4k: should tolerate null display_name/description; got '${OUT}'"
pass "auto: null on optional fields tolerated → gpt-5.5"
PASS_COUNT=$((PASS_COUNT+1))

info "[4l] auto + empty-models → fallback + warning"
OUT=$(PRILIVE_MODELS_CACHE="${FIXTURE_DIR}/empty-models.json" resolve_codex_model "auto" 2>/dev/null)
ERR=$(PRILIVE_MODELS_CACHE="${FIXTURE_DIR}/empty-models.json" resolve_codex_model "auto" 2>&1 >/dev/null)
[[ "${OUT}" == "gpt-5.5" ]] || fail "case 4l: expected fallback gpt-5.5 on empty list, got '${OUT}'"
echo "${ERR}" | grep -qE 'no candidates|filter' || fail "case 4l: expected no-candidates warning, got: ${ERR}"
pass "auto: empty models list → fallback + no-candidates warning"
PASS_COUNT=$((PASS_COUNT+1))

info "[4m] auto + not-json → fallback + parse-error warning"
OUT=$(PRILIVE_MODELS_CACHE="${FIXTURE_DIR}/not-json.txt" resolve_codex_model "auto" 2>/dev/null)
ERR=$(PRILIVE_MODELS_CACHE="${FIXTURE_DIR}/not-json.txt" resolve_codex_model "auto" 2>&1 >/dev/null)
[[ "${OUT}" == "gpt-5.5" ]] || fail "case 4m: expected fallback gpt-5.5 on parse error, got '${OUT}'"
echo "${ERR}" | grep -qE 'not valid JSON|JSON' || fail "case 4m: expected JSON-error warning, got: ${ERR}"
pass "auto: corrupt cache → fallback + JSON-error warning"
PASS_COUNT=$((PASS_COUNT+1))

info "[4n] auto + missing-required → fallback + missing-fields warning"
OUT=$(PRILIVE_MODELS_CACHE="${FIXTURE_DIR}/missing-required.json" resolve_codex_model "auto" 2>/dev/null)
ERR=$(PRILIVE_MODELS_CACHE="${FIXTURE_DIR}/missing-required.json" resolve_codex_model "auto" 2>&1 >/dev/null)
# missing-required has .models (which is the field we actually require for slice 2);
# it lacks client_version + fetched_at but the resolver tolerates that and uses .models.
# So this fixture should succeed and return the slug. The fixture is documented as
# "fallback in slice 2" but the resolver design (per addendum: tolerant of unknown
# fields; only fail on REQUIRED fields the resolver depends on) accepts it.
[[ "${OUT}" == "gpt-5.5" ]] || fail "case 4n: expected gpt-5.5 (resolver only requires .models[]); got '${OUT}'"
pass "auto: missing top-level metadata (client_version/fetched_at) tolerated (resolver only depends on .models[])"
PASS_COUNT=$((PASS_COUNT+1))

info "[4o] auto with stale cache → slug returned, stale warning emitted"
STALE_CACHE=$(mktemp)
jq '.fetched_at = "2020-01-01T00:00:00Z"' "${FIXTURE_DIR}/valid-typical.json" > "${STALE_CACHE}"
OUT=$(PRILIVE_MODELS_CACHE="${STALE_CACHE}" resolve_codex_model "auto" 2>/dev/null)
ERR=$(PRILIVE_MODELS_CACHE="${STALE_CACHE}" resolve_codex_model "auto" 2>&1 >/dev/null)
rm -f "${STALE_CACHE}"
[[ "${OUT}" == "gpt-5.5" ]] || fail "case 4o: stale cache should still return slug, got '${OUT}'"
echo "${ERR}" | grep -qE 'days old|stale|refresh' || fail "case 4o: expected stale-cache warning, got: ${ERR}"
pass "auto: stale cache (>14 days) → slug returned + stale warning (warns, does NOT fall back per addendum MINOR)"
PASS_COUNT=$((PASS_COUNT+1))

info "[4p] counterfactual — fresh cache (today) → NO stale warning"
FRESH_CACHE=$(mktemp)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg ts "${NOW_ISO}" '.fetched_at = $ts' "${FIXTURE_DIR}/valid-typical.json" > "${FRESH_CACHE}"
ERR=$(PRILIVE_MODELS_CACHE="${FRESH_CACHE}" resolve_codex_model "auto" 2>&1 >/dev/null)
rm -f "${FRESH_CACHE}"
echo "${ERR}" | grep -qE 'days old' && fail "case 4p: fresh cache must NOT emit stale warning, got: ${ERR}"
pass "auto: fresh cache → no stale warning (counterfactual)"
PASS_COUNT=$((PASS_COUNT+1))

info "[4q] env-var auth detection: CODEX_API_KEY set → api_key mode"
ERR=$(CODEX_API_KEY=test PRILIVE_MODELS_CACHE="${FIXTURE_DIR}/valid-api-only-edge.json" resolve_codex_model "auto" 2>&1 >/dev/null)
echo "${ERR}" | grep -qF 'api_key' || fail "case 4q: CODEX_API_KEY should switch to api_key mode, got: ${ERR}"
pass "auto: CODEX_API_KEY env var → api_key auth-mode detection"
PASS_COUNT=$((PASS_COUNT+1))

info "[4r] env-var auth detection: OPENAI_API_KEY set → api_key mode"
ERR=$(OPENAI_API_KEY=test PRILIVE_MODELS_CACHE="${FIXTURE_DIR}/valid-api-only-edge.json" resolve_codex_model "auto" 2>&1 >/dev/null)
echo "${ERR}" | grep -qF 'api_key' || fail "case 4r: OPENAI_API_KEY should switch to api_key mode, got: ${ERR}"
pass "auto: OPENAI_API_KEY env var → api_key auth-mode detection"
PASS_COUNT=$((PASS_COUNT+1))

info "[4s] counterfactual: no env vars + no explicit arg → subscription mode"
ERR=$(env -i HOME="${HOME}" PATH="${PATH}" bash -c "
  unset CODEX_API_KEY OPENAI_API_KEY
  . '${LIB}'
  PRILIVE_MODELS_CACHE='${FIXTURE_DIR}/valid-typical.json' resolve_codex_model 'auto'
" 2>&1 >/dev/null)
echo "${ERR}" | grep -qF 'subscription' || fail "case 4s: no env vars should default to subscription, got: ${ERR}"
pass "auto: no env vars → defaults to subscription auth-mode"
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

info "[6d] describe: auto → mentions cache resolution (slice 2 real impl)"
LINE=$(resolve_codex_model_describe "auto" "gpt-5.5")
echo "${LINE}" | grep -qF 'models_cache.json' || fail "case 6d: expected 'models_cache.json' in describe, got: ${LINE}"
echo "${LINE}" | grep -qF 'gpt-5.5' || fail "case 6d: expected resolved slug in describe, got: ${LINE}"
pass "describe(auto): mentions resolved slug + cache source (observability MVP per M5)"
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
