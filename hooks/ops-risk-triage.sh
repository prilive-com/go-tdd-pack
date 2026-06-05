#!/usr/bin/env bash
# hooks/ops-risk-triage.sh
#
# v2.2 — Ops Risk Triage (slice 1: Layer 1 deterministic parser + Layer 1b
# catastrophic denylist + observe-mode logging only).
#
# DESIGN — see docs/PROPOSAL-ops-risk-triage.md for the full architecture.
#
# Slice 1 ships:
#   - Layer 1   deterministic syntax parser (safe NAME on user allowlist
#               AND safe SHAPE: no redirection/chain/substitution/sudo/
#               secret-paths) → fast-path allow with no log
#   - Layer 1b  user-owned catastrophic denylist (extended regex patterns)
#               → in observe mode: LOG the match, allow anyway (never
#               interrupts per slice 1 scope)
#   - Fall-through (would-be-Layer-2 LLM classifier): LOG "would_classify"
#               with the command, allow. Slice 2 wires this to Haiku.
#   - Logs to .tdd/ops-triage/observe.log (JSONL, one verdict per line).
#
# Slice 1 NEVER emits permissionDecision: ask or deny. Observe-only.
# The hook silently allows everything; the log is the entire deliverable.
# Adopters review the log to see what their workload looks like, then
# advance to slice 2-3 to actually gate.
#
# Disabled-safe: PRILIVE_REVIEW_DISABLE=1 or [ops_triage] enabled=false →
# exit 0 immediately, no log entry. The pack-as-before invariant.
#
# Config (tdd-pack.toml [ops_triage]):
#   enabled = false       # opt-in; default off per v2.1.1 lesson
#   mode    = "observe"   # slice 1 only supports observe; ask/governed are
#                         #   slices 3 + 5. The hook degrades to observe
#                         #   for ask/governed in slice 1 with a warning
#                         #   log entry (never deny).
#
# Override (one-shell): PRILIVE_OPS_TRIAGE=1 forces enabled=true.

set -uo pipefail

# ---------------------------------------------------------------------------
# 0. Disabled-safe gates
# ---------------------------------------------------------------------------
[[ "${PRILIVE_REVIEW_DISABLE:-}" == "1" ]] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
TOML="${PROJECT_DIR}/tdd-pack.toml"
LIB="${CLAUDE_PLUGIN_ROOT:-${PROJECT_DIR}}/runner/lib"

# cfg_get <file> <dotted.key> <default> — provided by runner/lib/config.sh
if [[ -f "${LIB}/config.sh" ]]; then
  # shellcheck source=../runner/lib/config.sh
  . "${LIB}/config.sh"
else
  cfg_get() { echo "$3"; }
fi

ENABLED=$(cfg_get "${TOML}" "ops_triage.enabled" "false")
[[ "${ENABLED}" != "true" && "${PRILIVE_OPS_TRIAGE:-}" != "1" ]] && exit 0

MODE=$(cfg_get "${TOML}" "ops_triage.mode" "observe")
[[ "${MODE}" == "off" ]] && exit 0

# ---------------------------------------------------------------------------
# 1. Tool gating + command extraction
# ---------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || exit 0   # no jq → silent allow (slice 1 is observe)

INPUT=$(cat 2>/dev/null || true)
[[ -z "${INPUT}" ]] && exit 0

TOOL=$(printf '%s' "${INPUT}" | jq -r '.tool_name // empty' 2>/dev/null)
[[ "${TOOL}" != "Bash" ]] && exit 0

CMD=$(printf '%s' "${INPUT}" | jq -r '.tool_input.command // empty' 2>/dev/null)
[[ -z "${CMD}" ]] && exit 0

# ---------------------------------------------------------------------------
# Logging helper — appends one JSONL verdict line. Atomic up to PIPE_BUF.
# ---------------------------------------------------------------------------
LOG_DIR="${PROJECT_DIR}/.tdd/ops-triage"
LOG_FILE="${LOG_DIR}/observe.log"
mkdir -p "${LOG_DIR}" 2>/dev/null

log_verdict() {
  # log_verdict <layer> <verdict> [extra_key=value ...]
  local layer="$1" verdict="$2"; shift 2
  local extra='{}'
  local kv
  for kv in "$@"; do
    local k="${kv%%=*}" v="${kv#*=}"
    extra=$(jq -nc --arg k "$k" --arg v "$v" --argjson cur "${extra}" \
              '$cur + {($k): $v}')
  done
  jq -nc --arg ts "$(date -u +%FT%TZ)" \
         --arg layer "${layer}" \
         --arg verdict "${verdict}" \
         --arg mode "${MODE}" \
         --arg cmd "${CMD}" \
         --arg cwd "${PWD}" \
         --argjson extra "${extra}" \
         '{ts:$ts, mode:$mode, layer:$layer, verdict:$verdict, command:$cmd, cwd:$cwd} + $extra' \
    >> "${LOG_FILE}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 2. Layer 1 deterministic parser
# ---------------------------------------------------------------------------
# shape_unsafe: returns 0 (true) if the command has a syntax feature that
# disqualifies it from the fast-path. This is intentionally over-broad:
# "unsafe shape" really means "not a trivial single command" — anything
# else falls through to Layer 1b / would-be-Layer-2.
shape_unsafe() {
  local c="$1"
  # output / input redirection (>, >>, <, here-string <<<, here-doc <<)
  grep -Eq '(^|[^0-9&])>>?|<<<?|(^|[^|&])\|[^|&]' <<<"$c" && return 0
  # shell chaining (&&, ||, ;)
  grep -Eq '&&|\|\||;' <<<"$c" && return 0
  # command / process substitution
  grep -Eq '\$\(|\$\{|`|<\(|>\(' <<<"$c" && return 0
  # privilege escalation
  grep -Eq '(^|[[:space:]])(sudo|doas|su)([[:space:]]|$)' <<<"$c" && return 0
  # secret-like paths
  grep -Eq '(\.env([[:space:]]|$|/)|\.pem|\.key([[:space:]]|$)|secret|credential|id_rsa|\.aws|\.kube/config)' <<<"$c" && return 0
  return 1
}

# Strip leading env-var assignments (FOO=bar cmd → cmd) for name lookup.
strip_env() {
  local c="$1"
  while [[ "$c" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+ ]]; do
    c=$(sed -E 's/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+//' <<<"$c")
  done
  printf '%s' "$c"
}

# name_safe: returns 0 (true) if the command's first one, two, or three
# tokens (in that priority order, longest match wins) appear in the user's
# safe allowlist. Literal-string match, not regex — adopter writes "git
# status" verbatim, we compare verbatim.
name_safe() {
  local allow="${PROJECT_DIR}/config/ops-safe-allowlist.txt"
  [[ -f "${allow}" ]] || return 1
  local stripped first second third one two three
  stripped=$(strip_env "${CMD}")
  first=$(awk '{print $1}' <<<"${stripped}")
  second=$(awk '{print $2}' <<<"${stripped}")
  third=$(awk '{print $3}' <<<"${stripped}")
  [[ -z "${first}" ]] && return 1
  one="${first}"
  two="${first} ${second}"
  three="${first} ${second} ${third}"
  # Walk the allowlist; ignore comments + blank lines; literal string match.
  while IFS= read -r entry; do
    [[ -z "${entry}" || "${entry}" == \#* ]] && continue
    [[ "${entry}" == "${one}" || "${entry}" == "${two}" || "${entry}" == "${three}" ]] && return 0
  done < "${allow}"
  return 1
}

if name_safe && ! shape_unsafe "${CMD}"; then
  # Fast-path: trivially safe. No log, no model, no prompt.
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Layer 1b: user-owned CATASTROPHIC denylist
# ---------------------------------------------------------------------------
DENY="${PROJECT_DIR}/config/ops-catastrophic-denylist.txt"
DENY_MATCHED=""
if [[ -f "${DENY}" ]]; then
  while IFS= read -r pat; do
    [[ -z "${pat}" || "${pat}" == \#* ]] && continue
    if grep -Eq -- "${pat}" <<<"${CMD}" 2>/dev/null; then
      DENY_MATCHED="${pat}"
      break
    fi
  done < "${DENY}"
fi

if [[ -n "${DENY_MATCHED}" ]]; then
  # Slice 1: LOG the match, do NOT deny (observe-only).
  # Slice 3 will convert this branch to emit permissionDecision:"deny".
  log_verdict "L1b" "denylist_match" "pattern=${DENY_MATCHED}"
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Fall-through: would-be-Layer-2 (LLM classifier — slice 2 will fill in)
# ---------------------------------------------------------------------------
log_verdict "L2" "would_classify_in_slice2"

# Slice 1: any mode other than off behaves as observe (never interrupt).
# In slice 3 the ask/governed modes will actually gate here. Until then,
# log a warning entry once per session for any non-observe mode so adopters
# know they're not getting the gate they configured.
case "${MODE}" in
  observe) ;;
  ask|governed)
    log_verdict "MODE" "degraded_to_observe" "configured=${MODE}" "note=slice1_observe_only"
    ;;
esac

exit 0
