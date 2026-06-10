#!/usr/bin/env bash
# runner/lib/resolve-model.sh — resolve the `[codex] model` TOML value
# to the slug actually passed to `codex exec -m <slug>`.
#
# v2.3 slice 1 — STUB implementation (`auto` returned fallback).
# v2.3 slice 2 — REAL implementation: reads ~/.codex/models_cache.json,
#                applies role-suitability filter, sorts by priority,
#                returns the winner. Auth-mode detection via env vars
#                (auth.json parsing is a slice 3 refinement).
#
# API contract (locked in slice 1, unchanged here):
#
#   . "${PROJECT_DIR}/runner/lib/resolve-model.sh"
#   MODEL=$(resolve_codex_model "$(cfg_get .. codex.model auto)")
#   resolve_codex_model_describe "${MODEL_RAW}" "${MODEL}" >&2
#
# Fallback default (when `auto` cannot resolve from cache and when
# tests need to inject a known value):
#
#   PRILIVE_MODEL_FALLBACK env var (override)
#   else "gpt-5.5" (the v2.1.1 pin — single source of truth)
#
# Cache location override (for testing):
#
#   PRILIVE_MODELS_CACHE env var (override)
#   else "${CODEX_HOME:-$HOME/.codex}/models_cache.json"
#
# Auth-mode signals (in precedence order):
#
#   1. Explicit second arg to resolve_codex_model.
#   2. CODEX_API_KEY env var set → "api_key".
#   3. OPENAI_API_KEY env var set → "api_key".
#   4. Default → "subscription".
#
# Per PROPOSAL-model-auto-select.md addendum MINOR finding: the v2
# scope wanted ~/.codex/auth.json parsing as PRIMARY signal. Slice 2
# defers that to slice 3 — empirical format verification against
# multiple auth states is out of scope here.

if [[ -z "${__PRILIVE_RESOLVE_MODEL_LIB_LOADED:-}" ]]; then
  __PRILIVE_RESOLVE_MODEL_LIB_LOADED=1
fi

# resolve_codex_model_fallback [<auth_mode>] → echoes the fallback slug,
# or empty string ("") to defer to Codex CLI's own --model default.
#
# v2.3.2 design — STOP PINNING. v2.1.1 / v2.3.0 / v2.3.1 each tried
# to pin a specific slug as the fallback (gpt-5.5, then gpt-5.2-codex
# under api_key). Every pin goes stale the moment OpenAI ships a new
# minor — operators end up running yesterday's model.
#
# Per OpenAI's June-2026 Codex docs (developers.openai.com/codex/models),
# gpt-5.5 IS the current default for both ChatGPT-auth and API-key
# auth, AND Codex CLI's --model default also resolves to gpt-5.5.
# So returning empty here ⇒ runner omits the --model flag ⇒ Codex CLI
# applies its own default ⇒ when OpenAI updates the default, we
# auto-track with ZERO repo edits.
#
# The v2.1.1 incident (Codex CLI 0.130 shifted default to a paid-only
# model) is on OpenAI to fix going forward. We refuse to keep
# patching pins.
#
# Precedence:
#   1. PRILIVE_MODEL_FALLBACK env var → echo it. Operators who want
#      to pin in their own environment (testing, regulatory
#      determinism) keep doing exactly that. Not a shipped default.
#   2. else → echo "" (let Codex CLI's --model default apply).
#
# auth_mode arg is preserved for back-compat with v2.3.1 callers but
# is no longer consulted.
resolve_codex_model_fallback() {
  if [[ -n "${PRILIVE_MODEL_FALLBACK:-}" ]]; then
    echo "${PRILIVE_MODEL_FALLBACK}"
    return 0
  fi
  # No pin. Runner sees empty → omits --model → CLI default applies.
  echo ""
}

# _resolve_codex_cache_path → echoes the path to models_cache.json.
_resolve_codex_cache_path() {
  if [[ -n "${PRILIVE_MODELS_CACHE:-}" ]]; then
    echo "${PRILIVE_MODELS_CACHE}"
  else
    echo "${CODEX_HOME:-$HOME/.codex}/models_cache.json"
  fi
}

# _resolve_codex_auth_mode <explicit_arg?> → echoes "subscription" or
# "api_key". Precedence: explicit arg > env vars > default.
_resolve_codex_auth_mode() {
  local explicit="${1-}"
  case "${explicit}" in
    api_key|subscription)
      echo "${explicit}"
      return 0
      ;;
  esac
  if [[ -n "${CODEX_API_KEY:-}" || -n "${OPENAI_API_KEY:-}" ]]; then
    echo "api_key"
  else
    echo "subscription"
  fi
}

# _resolve_codex_role_suitability_pattern → echoes a regex that matches
# slugs the resolver MUST filter out before priority sort. Closes
# MAJOR M1 from the addendum: high-priority but role-inappropriate
# models (auto-review variants, spark variants, mini variants) must
# not win the code-review role just because of UI priority.
_resolve_codex_role_suitability_pattern() {
  # Each alternation is a documented exclusion rule. Maintain
  # explicit alternation (not a list file) to keep slugs auditable
  # in code review.
  #
  # - *-auto-review  — internal "promote auto-review" model class
  # - *-spark        — Codex Spark variants (TUI-only / specialized)
  # - *-mini         — smaller, faster variants — wrong tier for
  #                    code review
  echo '(-auto-review$|-spark$|-mini$)'
}

# _resolve_codex_cache_age_days <cache_file> → echoes the integer day-
# delta between $(date -u) and the cache's `fetched_at`. Returns 1 if
# the cache is unreadable or the field is missing/malformed.
_resolve_codex_cache_age_days() {
  local cache="$1"
  command -v jq >/dev/null 2>&1 || return 1
  [[ -r "${cache}" ]] || return 1
  local fetched
  fetched=$(jq -r '.fetched_at // empty' "${cache}" 2>/dev/null) || return 1
  [[ -n "${fetched}" ]] || return 1
  # GNU date and busybox date both accept ISO timestamps with -d.
  # On macOS / BSD date the syntax differs — use python3 as a
  # portable fallback (already required by the second-opinion skill).
  if date -u -d "${fetched}" +%s >/dev/null 2>&1; then
    local then_s now_s
    then_s=$(date -u -d "${fetched}" +%s)
    now_s=$(date -u +%s)
    echo $(( (now_s - then_s) / 86400 ))
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "
import sys, datetime
try:
  ts = '${fetched}'.replace('Z','+00:00')
  then = datetime.datetime.fromisoformat(ts)
  now = datetime.datetime.now(datetime.timezone.utc)
  print(int((now - then).total_seconds() // 86400))
except Exception:
  sys.exit(1)
" 2>/dev/null || return 1
  else
    return 1
  fi
}

# resolve_codex_model <toml_value> [<auth_mode>] → echoes slug.
#
# Args:
#   toml_value  the literal string from [codex] model in tdd-pack.toml.
#               Valid forms:
#                 "auto"          read cache + filter + sort + return
#                                 the winner; fallback on any failure.
#                 "<slug>"        echo verbatim (pin passthrough).
#                 ""              echo "" (preserves v2.1.x defer-to-CLI;
#                                 Codex CLI's default applies).
#                 "cli-default"   echo "" + deprecation warning to
#                                 stderr (explicit opt-in to defer).
#   auth_mode   optional; "subscription" (default), "api_key". If
#               omitted, the helper sniffs env vars. Affects only the
#               auto branch.
#
# Exit:
#   0   resolved (stdout has the slug)
#   2   invalid input (whitespace, control chars in toml_value)
#
# stderr: warnings + diagnostic notes. Callers should display these
#         to the operator.
resolve_codex_model() {
  local toml_value="${1-}"
  local auth_explicit="${2-}"
  local auth_mode fallback
  # v2.3.1: resolve auth_mode FIRST so the fallback can be auth-aware.
  auth_mode=$(_resolve_codex_auth_mode "${auth_explicit}")
  fallback=$(resolve_codex_model_fallback "${auth_mode}")

  # Input validation — reject control characters or embedded whitespace.
  # Empty string is VALID (preserves v2.1.x defer-to-CLI).
  if [[ -n "${toml_value}" ]]; then
    if [[ "${toml_value}" =~ [[:space:][:cntrl:]] ]]; then
      echo "resolve-model: invalid toml value (whitespace / control char): '${toml_value}'" >&2
      return 2
    fi
  fi

  case "${toml_value}" in
    "")
      # Preserved v2.1.x semantics.
      echo ""
      ;;

    "cli-default")
      echo "resolve-model: WARNING — cli-default defers the model choice to Codex CLI's --model default, which v2.1.1 documented as unsafe (default may shift to a paid-only model). Prefer model = \"auto\" or a pinned slug." >&2
      echo ""
      ;;

    "auto")
      _resolve_codex_model_auto "${auth_mode}" "${fallback}"
      ;;

    *)
      # Pin passthrough.
      echo "${toml_value}"
      ;;
  esac

  return 0
}

# _resolve_codex_model_auto <auth_explicit> <fallback> → implements
# the `auto` branch: read cache, validate, filter, sort, echo winner.
# Falls back to ${fallback} with stderr warning on any failure.
#
# This is the slice 2 implementation. Slice 1 had a stub here.
_resolve_codex_model_auto() {
  local auth_explicit="$1"
  local fallback="$2"
  local cache auth_mode
  cache=$(_resolve_codex_cache_path)
  auth_mode=$(_resolve_codex_auth_mode "${auth_explicit}")

  # 1. Cache absent → fallback.
  if [[ ! -f "${cache}" ]]; then
    echo "resolve-model: WARNING — cache absent (${cache}); using fallback '${fallback}'. (auth-mode: ${auth_mode})" >&2
    echo "${fallback}"
    return 0
  fi

  # 2. jq required.
  if ! command -v jq >/dev/null 2>&1; then
    echo "resolve-model: WARNING — jq not on PATH; cannot parse cache; using fallback '${fallback}'." >&2
    echo "${fallback}"
    return 0
  fi

  # 3. Cache not valid JSON → fallback.
  if ! jq empty "${cache}" >/dev/null 2>&1; then
    echo "resolve-model: WARNING — cache is not valid JSON (${cache}); using fallback '${fallback}'. (auth-mode: ${auth_mode})" >&2
    echo "${fallback}"
    return 0
  fi

  # 4. Required top-level fields present → otherwise fallback.
  local has_models
  has_models=$(jq 'has("models") and (.models | type == "array")' "${cache}" 2>/dev/null)
  if [[ "${has_models}" != "true" ]]; then
    echo "resolve-model: WARNING — cache missing required .models[] (${cache}); using fallback '${fallback}'. (auth-mode: ${auth_mode})" >&2
    echo "${fallback}"
    return 0
  fi

  # 5. Build filtered/sorted candidate list.
  #
  # Filter pipeline (in this order):
  #   a. priority is an integer (drop missing/string/null)
  #   b. visibility == "list" (drop hide / missing)
  #   c. slug present + string (drop malformed entries)
  #   d. if auth_mode == "api_key": supported_in_api == true
  #   e. role-suitability: drop slugs matching the exclusion regex
  # Sort: priority asc, slug asc (tiebreaker)
  # Echo: first .slug
  local role_pat
  role_pat=$(_resolve_codex_role_suitability_pattern)

  local winner
  if [[ "${auth_mode}" == "api_key" ]]; then
    winner=$(jq -r --arg pat "${role_pat}" '
      .models
      | map(select(
          (.priority | type) == "number"
          and (.visibility == "list")
          and ((.slug | type) == "string")
          and (.slug | length > 0)
          and ((.supported_in_api // false) == true)
          and (.slug | test($pat) | not)
        ))
      | sort_by(.priority, .slug)
      | .[0].slug // ""
    ' "${cache}" 2>/dev/null)
  else
    winner=$(jq -r --arg pat "${role_pat}" '
      .models
      | map(select(
          (.priority | type) == "number"
          and (.visibility == "list")
          and ((.slug | type) == "string")
          and (.slug | length > 0)
          and (.slug | test($pat) | not)
        ))
      | sort_by(.priority, .slug)
      | .[0].slug // ""
    ' "${cache}" 2>/dev/null)
  fi

  # 6. Empty filtered list → fallback.
  if [[ -z "${winner}" ]]; then
    echo "resolve-model: WARNING — no candidates after filter+sort (cache=${cache}, auth=${auth_mode}); using fallback '${fallback}'." >&2
    echo "${fallback}"
    return 0
  fi

  # 7. Stale-cache warning (>14 days). Warns but does NOT fall back
  # — per addendum MINOR closure: stale warns, never falls back.
  local age
  if age=$(_resolve_codex_cache_age_days "${cache}" 2>/dev/null); then
    if [[ -n "${age}" && "${age}" -gt 14 ]]; then
      echo "resolve-model: NOTE — cache is ${age} days old (>14); consider refreshing by running 'codex' once. (Still using cached value '${winner}'.)" >&2
    fi
  fi

  # 8. Success.
  echo "resolve-model: resolved '${winner}' from cache (auth-mode: ${auth_mode})" >&2
  echo "${winner}"
  return 0
}

# resolve_codex_model_describe <toml_value> [<resolved_slug>] → echoes
# a one-line operator-visible description of the resolver decision.
# Required (NOT optional) per addendum MAJOR M5 closure.
resolve_codex_model_describe() {
  local toml_value="${1-}"
  local resolved="${2-}"
  case "${toml_value}" in
    "")            echo "model: (empty — Codex CLI default applies; v2.1.x semantics)" ;;
    "cli-default") echo "model: (empty — explicit cli-default; deprecated)" ;;
    "auto")        echo "model: ${resolved} (auto → resolved from ~/.codex/models_cache.json)" ;;
    *)             echo "model: ${resolved} (pinned via tdd-pack.toml)" ;;
  esac
}
