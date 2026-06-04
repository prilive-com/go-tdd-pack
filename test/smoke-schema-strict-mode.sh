#!/usr/bin/env bash
# test/smoke-schema-strict-mode.sh
#
# v2.1.1 release guard. v2.1.0 shipped with a fatal schema bug:
# `findings-round1.schema.json` declared `raised_by_angle` under
# `properties` but did not list it in `required`, while
# `additionalProperties: false` was set. OpenAI strict mode rejects
# this combination with HTTP 400 `invalid_json_schema` on the first
# `codex exec --output-schema` call, so every fresh adopter crashed
# on their first runner cycle.
#
# OpenAI strict-mode rule (Structured Outputs): when
# `additionalProperties: false`, every property MUST appear in
# `required`. This smoke asserts that invariant for every schema in
# `schemas/` that uses additionalProperties: false. Prevents the same
# class of bug from shipping again.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEMA_DIR="${PROJECT_ROOT}/schemas"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
PASS_COUNT=0

command -v jq >/dev/null 2>&1 || fail "jq required"
[[ -d "${SCHEMA_DIR}" ]] || fail "schemas/ directory missing"

# Walk every object node in every schema. If the node has
# additionalProperties: false AND has a properties block, then every
# key in properties MUST be in required.
#
# Uses jq's recursive descent (..) so it catches nested object schemas
# (items.properties.foo.properties, etc.) — the v2.1.0 bug was nested
# under properties.findings.items.
check_one() {
  local schema="$1"
  local rel="${schema#${PROJECT_ROOT}/}"
  info "[check] ${rel}"

  jq empty "${schema}" 2>/dev/null || fail "${rel}: invalid JSON"

  # Emit "path: missing prop1, prop2" for every offending node.
  # Strategy: collect every path to an object node whose shape qualifies
  # (additionalProperties=false AND has properties), then check the
  # required-vs-properties invariant on each. Two-phase keeps jq's
  # evaluation order safe (no .properties access on non-matching nodes).
  local violations
  violations=$(jq -r '
    [ paths as $p
      | getpath($p) as $node
      | select($node | type == "object")
      | select($node | has("additionalProperties") and .additionalProperties == false)
      | select($node | has("properties"))
      | ($node.properties | keys) as $props
      | (($node.required // []) | map(.)) as $req
      | ($props - $req) as $missing
      | select($missing | length > 0)
      | {path: ($p | map(tostring) | join(".")), missing: $missing}
    ]
    | .[]
    | "  - at \(.path): missing from required: \(.missing | join(", "))"
  ' "${schema}")

  if [[ -n "${violations}" ]]; then
    echo "${violations}" >&2
    fail "${rel}: strict-mode invariant violated (properties not in required while additionalProperties: false)"
  fi

  pass "${rel}: strict-mode invariant holds"
  PASS_COUNT=$((PASS_COUNT+1))
}

while IFS= read -r f; do
  check_one "$f"
done < <(find "${SCHEMA_DIR}" -maxdepth 2 -type f -name '*.schema.json' | sort)

echo ""
echo "================================================================"
echo "  SCHEMA STRICT-MODE SMOKE — PASS (${PASS_COUNT} schemas)"
echo "================================================================"
