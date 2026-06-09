#!/usr/bin/env bash
# runner/lib/resolve-model.sh — resolve the `[codex] model` TOML value
# to the slug actually passed to `codex exec -m <slug>`.
#
# v2.3 slice 1 — SLICE 1 STUB. The non-cache branches (pin
# passthrough, "" preservation, "cli-default" deprecation, input
# validation) are real. The `auto` branch is STUBBED to fall back
# to the pinned default with a clear stderr warning. Slice 2 will
# implement the real cache-reading logic.
#
# Why stub? PROPOSAL-model-auto-select.md addendum MAJOR M5: slices
# must be vertical-shippable. Slice 1 locks the resolver's API + the
# JSON Schema for the cache + the fixture set + the fallback paths.
# Slice 2 swaps the stub's `auto` body for the real implementation
# without re-touching slice 1's contract.
#
# Source this from any runner script that calls `codex exec`:
#
#   . "${PROJECT_DIR}/runner/lib/resolve-model.sh"
#   MODEL=$(resolve_codex_model "$(cfg_get .. codex.model auto)")
#
# Fallback default (used when `auto` falls back, when "" passes
# through, and when invalid cache forces fallback in slice 2+):
#
#   PRILIVE_MODEL_FALLBACK env var (override)
#   else "gpt-5.5" (the v2.1.1 pin)

if [[ -z "${__PRILIVE_RESOLVE_MODEL_LIB_LOADED:-}" ]]; then
  __PRILIVE_RESOLVE_MODEL_LIB_LOADED=1
fi

# resolve_codex_model_fallback → echoes the pinned-fallback slug.
# Single source of truth for "what slug do we use when auto can't
# resolve / cli-default is requested / cache is broken in slice 2+".
resolve_codex_model_fallback() {
  echo "${PRILIVE_MODEL_FALLBACK:-gpt-5.5}"
}

# resolve_codex_model <toml_value> [<auth_mode>] → echoes slug.
#
# Args:
#   toml_value  the literal string from [codex] model in tdd-pack.toml.
#               Valid forms:
#                 "auto"          slice 1: stub returns fallback
#                                 slice 2: read cache, filter, sort, pick
#                 "<slug>"        echo verbatim (pin passthrough)
#                 ""              echo "" (preserves v2.1.x defer-to-CLI;
#                                 Codex CLI's default applies)
#                 "cli-default"   echo "" + deprecation warning to stderr
#                                 (explicit v2.1.0-style opt-in)
#   auth_mode   optional; "subscription" (default) or "api_key".
#               Slice 1 stub: ignored. Slice 2: filters models with
#               supported_in_api=false under api_key.
#
# Exit:
#   0   resolved (stdout has the slug)
#   2   invalid input (whitespace, control chars in toml_value)
#
# stderr: warnings + diagnostic notes (cache stub note, deprecation,
#         etc.). Callers should display these to the operator.
resolve_codex_model() {
  local toml_value="${1-}"
  local auth_mode="${2:-subscription}"
  local fallback
  fallback=$(resolve_codex_model_fallback)

  # Input validation — reject control characters or embedded whitespace.
  # Empty string is VALID (preserves v2.1.x defer-to-CLI).
  if [[ -n "${toml_value}" ]]; then
    # Reject whitespace inside the value (newlines, tabs, embedded space).
    # A legitimate slug like "gpt-5.5-codex" has no whitespace.
    if [[ "${toml_value}" =~ [[:space:][:cntrl:]] ]]; then
      echo "resolve-model: invalid toml value (whitespace / control char): '${toml_value}'" >&2
      return 2
    fi
  fi

  case "${toml_value}" in
    "")
      # PRESERVED v2.1.x SEMANTICS — pass empty through to Codex CLI's
      # --model default. Documented unsafe (v2.1.1 incident) but kept
      # for adopters who explicitly depend on it. MAJOR M3 closure.
      echo ""
      ;;

    "cli-default")
      # EXPLICIT opt-in to defer-to-CLI-default. Same behavior as ""
      # but the name announces the trade-off. Deprecation warning makes
      # the v2.1.1 trap discoverable. MAJOR M3 closure.
      echo "resolve-model: WARNING — cli-default defers the model choice to Codex CLI's --model default, which v2.1.1 documented as unsafe (default may shift to a paid-only model). Prefer model = \"auto\" (slice 2+) or a pinned slug." >&2
      echo ""
      ;;

    "auto")
      # SLICE 1 STUB. Slice 2 replaces this body with: read the cache,
      # validate against schemas/codex-models-cache.schema.json, apply
      # role-suitability filter (drop *-auto-review, *-spark, *-mini),
      # filter by visibility=list AND (subscription OR supported_in_api),
      # sort by priority ascending, echo .slug of the first entry. The
      # stub keeps slice 1 shippable.
      echo "resolve-model: WARNING — model = \"auto\" is implemented in slice 2. Slice 1 falls back to '${fallback}'. (Auth-mode detected: ${auth_mode}.)" >&2
      echo "${fallback}"
      ;;

    *)
      # PIN PASSTHROUGH. Any non-special string is a literal slug.
      # No cache read. Operator gets exactly what they asked for.
      echo "${toml_value}"
      ;;
  esac

  return 0
}

# resolve_codex_model_describe <toml_value> → human-readable line for
# session-start logging. Used by the runner to surface the resolution
# decision in operator-visible output (NOT optional per MAJOR M5).
#
# Echoes a single line like:
#   "model: gpt-5.5 (pinned via tdd-pack.toml)"
#   "model: gpt-5.5 (auto → slice 1 stub fallback)"
#   "model: (empty — Codex CLI default applies)"
resolve_codex_model_describe() {
  local toml_value="${1-}"
  local resolved="${2-}"
  case "${toml_value}" in
    "")          echo "model: (empty — Codex CLI default applies; v2.1.x semantics)" ;;
    "cli-default") echo "model: (empty — explicit cli-default; deprecated)" ;;
    "auto")      echo "model: ${resolved} (auto → slice 1 stub fallback; slice 2 will read ~/.codex/models_cache.json)" ;;
    *)           echo "model: ${resolved} (pinned via tdd-pack.toml)" ;;
  esac
}
