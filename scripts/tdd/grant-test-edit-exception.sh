#!/usr/bin/env bash
# scripts/tdd/grant-test-edit-exception.sh
#
# v1.7.0 typed test-edit exception grant helper. Two modes:
#
# 1. Create pending entry (agent invocation):
#      grant-test-edit-exception.sh \
#        --type mechanical_signature_propagation \
#        --paths "internal/modules/capital/**/*_test.go" \
#        --symbol ReconcileWithExchange \
#        --operations edit_existing_tests,create_new_tests \
#        --reason "PR4 widens ReconcileWithExchange ..." \
#        --cycle-id <cycle-id>
#
# 2. Approve pending entry (after operator says "APPROVED EXCEPTION E-NNN"):
#      grant-test-edit-exception.sh --approve E-001
#      grant-test-edit-exception.sh --approve E-001,E-002
#      grant-test-edit-exception.sh --approve "E-001 through E-003"
#
# Writes / updates `.tdd/exceptions/post-red-test-edits.json`.
# Appends a `granted` event to `.tdd/audit/<cycle-id>.jsonl` when a
# pending entry is approved (status: pending → approved).

set -uo pipefail

ARTIFACT=".tdd/exceptions/post-red-test-edits.json"
PLAN=".tdd/current-plan.md"
RED_PROOF=".tdd/red-proof.md"

if ! command -v jq >/dev/null 2>&1; then
  echo "[grant-test-edit-exception] BLOCKED: jq required." >&2
  exit 2
fi

sha256() {
  if   command -v sha256sum >/dev/null 2>&1; then sha256sum
  elif command -v shasum    >/dev/null 2>&1; then shasum -a 256
  else return 127
  fi
}

mkdir -p "$(dirname -- "$ARTIFACT")" 2>/dev/null
mkdir -p .tdd/audit 2>/dev/null

if [[ ! -f "$ARTIFACT" ]]; then
  echo '{"version":1,"cycle_id":"","phase":"red_confirmed","expires":"next_green_commit","exceptions":[]}' > "$ARTIFACT"
fi

# Mode dispatch.
mode="create"
approve_arg=""
type=""
paths=""
symbol=""
operations="edit_existing_tests"
reason=""
cycle_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --approve)        mode="approve"; approve_arg="${2:-}"; shift 2 ;;
    --type)           type="${2:-}"; shift 2 ;;
    --paths)          paths="${2:-}"; shift 2 ;;
    --symbol)         symbol="${2:-}"; shift 2 ;;
    --operations)     operations="${2:-}"; shift 2 ;;
    --reason)         reason="${2:-}"; shift 2 ;;
    --cycle-id)       cycle_id="${2:-}"; shift 2 ;;
    *)                shift ;;
  esac
done

if [[ "$mode" == "create" ]]; then
  if [[ -z "$type" || -z "$paths" || -z "$reason" ]]; then
    echo "[grant-test-edit-exception] BLOCKED: --type, --paths, --reason are required." >&2
    exit 2
  fi
  if [[ -z "$cycle_id" ]] && [[ -f "$PLAN" ]]; then
    cycle_id="$(grep -E '^Cycle ID:' "$PLAN" 2>/dev/null | head -1 | sed -E 's/^Cycle ID:[[:space:]]*//')"
  fi
  [[ -z "$cycle_id" ]] && cycle_id="unknown-cycle"

  # Set artifact's cycle_id if not yet set.
  current_cycle="$(jq -r '.cycle_id // ""' "$ARTIFACT")"
  if [[ -z "$current_cycle" ]]; then
    jq --arg c "$cycle_id" '.cycle_id = $c' "$ARTIFACT" > "$ARTIFACT.tmp" && mv "$ARTIFACT.tmp" "$ARTIFACT"
  fi

  # Generate next id (E-NNN).
  next_n=$(jq -r '[.exceptions[]?.id // empty | capture("E-(?<n>[0-9]+)").n | tonumber] + [0] | max + 1' "$ARTIFACT")
  new_id=$(printf 'E-%03d' "$next_n")

  # Convert paths/operations to JSON arrays.
  paths_json=$(printf '%s' "$paths" | jq -R 'split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))')
  ops_json=$(printf '%s' "$operations" | jq -R 'split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))')
  symbols_json=$(if [[ -n "$symbol" ]]; then printf '%s' "$symbol" | jq -R 'split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))'; else echo '[]'; fi)

  # Stub binding hashes — filled at approve time.
  jq --arg id "$new_id" \
     --arg type "$type" \
     --arg cycle "$cycle_id" \
     --arg reason "$reason" \
     --argjson paths "$paths_json" \
     --argjson symbols "$symbols_json" \
     --argjson ops "$ops_json" \
     '.exceptions += [{
        "id": $id,
        "type": $type,
        "status": "pending",
        "approved_by": "",
        "approved_at": "",
        "operations": $ops,
        "scope": {"paths": $paths, "symbols": $symbols},
        "reason": $reason,
        "binding": {"cycle_id": $cycle, "plan_hash": "", "red_proof_hash": "", "change_intent_hash": ""}
      }]' "$ARTIFACT" > "$ARTIFACT.tmp" && mv "$ARTIFACT.tmp" "$ARTIFACT"

  echo "[grant-test-edit-exception] Created pending exception $new_id (type=$type)." >&2
  echo "Operator: reply with 'APPROVED EXCEPTION $new_id' to grant." >&2
  exit 0
fi

if [[ "$mode" == "approve" ]]; then
  # Parse batch syntax: "E-001", "E-001,E-002", "E-001 through E-003".
  ids=()
  if [[ "$approve_arg" =~ E-([0-9]+)[[:space:]]+through[[:space:]]+E-([0-9]+) ]]; then
    a=$((10#${BASH_REMATCH[1]}))
    b=$((10#${BASH_REMATCH[2]}))
    for n in $(seq "$a" "$b"); do
      ids+=("$(printf 'E-%03d' "$n")")
    done
  else
    IFS=',' read -ra parts <<< "$approve_arg"
    for p in "${parts[@]}"; do
      p="${p# }"; p="${p% }"
      [[ -n "$p" ]] && ids+=("$p")
    done
  fi
  if [[ ${#ids[@]} -eq 0 ]]; then
    echo "[grant-test-edit-exception] BLOCKED: --approve needs an ID list." >&2
    exit 2
  fi

  cycle_id="$(jq -r '.cycle_id // "unknown-cycle"' "$ARTIFACT")"
  audit_log=".tdd/audit/${cycle_id}.jsonl"
  ts=$(date -u +%FT%TZ)

  plan_hash=""
  [[ -f "$PLAN" ]] && plan_hash="$(sha256 < "$PLAN" | awk '{print $1}')"
  red_proof_hash=""
  [[ -f "$RED_PROOF" ]] && red_proof_hash="$(sha256 < "$RED_PROOF" | awk '{print $1}')"
  # v1.7.0 round-7 F4: capture git HEAD so the hook can detect
  # next_green_commit expiry via HEAD advance (mutable mtime is not
  # a sound lifecycle authority).
  head_at_approval=""
  if command -v git >/dev/null 2>&1 && [[ -d .git ]]; then
    head_at_approval="$(git rev-parse HEAD 2>/dev/null || echo "")"
  fi

  # v1.7.0 round-1 F3: preflight all IDs. Every ID must exist exactly
  # once and have status == "pending". Reject the whole batch if any
  # ID fails the check (no partial mutations; no audit log spam).
  for id in "${ids[@]}"; do
    cur_status="$(jq -r --arg id "$id" '
      [.exceptions[]? | select(.id == $id) | .status] | first // "missing"
    ' "$ARTIFACT")"
    cur_count="$(jq -r --arg id "$id" '[.exceptions[]? | select(.id == $id)] | length' "$ARTIFACT")"
    if [[ "$cur_count" != "1" ]]; then
      echo "[grant-test-edit-exception] BLOCKED: exception $id not found exactly once (count: $cur_count). Approve aborted; no changes written." >&2
      exit 2
    fi
    if [[ "$cur_status" != "pending" ]]; then
      echo "[grant-test-edit-exception] BLOCKED: exception $id has status '$cur_status', not 'pending'. Approve aborted; no changes written." >&2
      exit 2
    fi
  done

  for id in "${ids[@]}"; do
    # v1.7.0 round-4 F3: bind scope.paths and operations into the
    # hash so post-approval mutation of either field invalidates it.
    # Format: cycle|symbols|type|reason|paths|operations.
    intent_input="$(jq -r --arg id "$id" '
      .exceptions[]
      | select(.id == $id)
      | (.binding.cycle_id // "") + "|"
        + ((.scope.symbols // []) | join(",")) + "|"
        + .type + "|" + .reason + "|"
        + ((.scope.paths // []) | join(",")) + "|"
        + ((.operations // []) | join(","))
    ' "$ARTIFACT")"
    change_intent_hash="$(printf '%s' "$intent_input" | sha256 | awk '{print $1}')"

    jq --arg id "$id" --arg by "operator" --arg at "$ts" \
       --arg ph "$plan_hash" --arg rh "$red_proof_hash" --arg ch "$change_intent_hash" \
       --arg hh "$head_at_approval" '
      .exceptions = (.exceptions | map(
        if .id == $id then
          .status = "approved"
          | .approved_by = $by
          | .approved_at = $at
          | .binding.plan_hash = $ph
          | .binding.red_proof_hash = $rh
          | .binding.change_intent_hash = $ch
          | .binding.head_at_approval = $hh
        else . end
      ))
    ' "$ARTIFACT" > "$ARTIFACT.tmp" && mv "$ARTIFACT.tmp" "$ARTIFACT"

    # Append granted event to audit log.
    entry_json="$(jq -c -n \
      --arg ts "$ts" --arg event "granted" --arg id "$id" \
      --arg cycle "$cycle_id" \
      '{ts: $ts, event: $event, exception_id: $id, cycle_id: $cycle}')"
    printf '%s\n' "$entry_json" >> "$audit_log"
    echo "[grant-test-edit-exception] Approved $id; logged to $audit_log." >&2
  done
  exit 0
fi
