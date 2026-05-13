#!/usr/bin/env bash
# .claude/hooks/second-opinion-plan-trigger.sh
#
# v1.9.0 — PreToolUse hook on Edit|Write|MultiEdit. Fires when the
# tool input's file_path matches a plan-write path. Blocks (denies)
# unless a matching `plan_review_completion` exists in the
# typed-exception artifact.
#
# Trigger paths:
#   .tdd/current-plan.md
#   .tdd/plans/**
#   docs/specs/*.md
#
# Stable error code: PLAN_REVIEW_REQUIRED.
# Hook contract: exit 0 always; decision in JSON on stdout.

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  cat >&2 <<'MSG'
[second-opinion-plan-trigger] BLOCKED: jq required.
MSG
  exit 2
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CONFIG="$PROJECT_DIR/.tdd/tdd-config.json"
PLAN="$PROJECT_DIR/.tdd/current-plan.md"
ARTIFACT="$PROJECT_DIR/.tdd/exceptions/post-red-test-edits.json"
HASH_SCOPE="$(dirname -- "${BASH_SOURCE[0]}")/../../scripts/tdd/hash-review-scope.sh"

# Bail when no config / not enabled (preserves backwards compat).
[[ ! -f "$CONFIG" ]] && exit 0
enabled="$(jq -r '.second_opinion.no_discretion.enabled // false' "$CONFIG" 2>/dev/null || echo false)"
plan_required="$(jq -r '.second_opinion.no_discretion.required_for.plan_writes // false' "$CONFIG" 2>/dev/null || echo false)"
[[ "$enabled" != "true" ]] && exit 0
[[ "$plan_required" != "true" ]] && exit 0

PAYLOAD="$(cat)"
if ! printf '%s' "$PAYLOAD" | jq -e . >/dev/null 2>&1; then
  echo "[second-opinion-plan-trigger] BLOCKED: malformed JSON input — fail closed." >&2
  exit 2
fi
tool_name="$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""')"
# Only fire on writeful tools.
case "$tool_name" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

file_path="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_input.path // ""' 2>/dev/null || echo "")"
[[ -z "$file_path" ]] && exit 0

# Path filter.
case "$file_path" in
  .tdd/current-plan.md|*/.tdd/current-plan.md) ;;
  .tdd/plans/*|*/.tdd/plans/*) ;;
  docs/specs/*.md|*/docs/specs/*.md) ;;
  *) exit 0 ;;
esac

# Proposed content for the scope binding. v1.9.0 round-5 F3: include
# BOTH old_string and new_string (and ALL MultiEdit edits) so the
# same replacement-text can't be reused against a different context.
proposed_content="$(printf '%s' "$PAYLOAD" | jq -r '
  if .tool_input.content then .tool_input.content
  elif .tool_input.new_string then (.tool_input.old_string // "") + "\n---REPLACED_BY---\n" + (.tool_input.new_string // "")
  elif (.tool_input.edits // []) | length > 0 then
    [.tool_input.edits[] | (.old_string // "") + "\n---REPLACED_BY---\n" + (.new_string // "")] | join("\n---NEXT_EDIT---\n")
  else "" end
' 2>/dev/null || echo "")"

# Cycle ID from plan.
cycle_id="$( { grep -E '^Cycle ID:' "$PLAN" 2>/dev/null || true; } | head -1 | sed -E 's/^Cycle ID:[[:space:]]*//')"
[[ -z "$cycle_id" ]] && cycle_id="unknown-cycle"

# proposed_plan_content_hash.
if command -v sha256sum >/dev/null 2>&1; then
  content_hash="$(printf '%s' "$proposed_content" | sha256sum | awk '{print $1}')"
else
  content_hash="$(printf '%s' "$proposed_content" | shasum -a 256 | awk '{print $1}')"
fi

# scope_hash = sha256(plan_review|cycle_id|plan_path|content_hash).
if [[ -x "$HASH_SCOPE" ]]; then
  scope_hash="$(bash "$HASH_SCOPE" plan_review "$cycle_id" "$file_path" "$content_hash" 2>/dev/null || echo "")"
else
  scope_hash="$(printf 'plan_review|%s|%s|%s' "$cycle_id" "$file_path" "$content_hash" | sha256sum | awk '{print $1}')"
fi

# Compute audit-log tail sha (used for F2 chain check + F1 pending entry).
AUDIT_LOG="$PROJECT_DIR/.tdd/audit/${cycle_id}.jsonl"
audit_tail_sha=""
if [[ -s "$AUDIT_LOG" ]]; then
  if command -v sha256sum >/dev/null 2>&1; then
    audit_tail_sha="$(tail -1 "$AUDIT_LOG" | sha256sum | awk '{print $1}')"
  else
    audit_tail_sha="$(tail -1 "$AUDIT_LOG" | shasum -a 256 | awk '{print $1}')"
  fi
fi

# Lookup matching completion (F2: validate audit-chain continuity).
matched=false
if [[ -f "$ARTIFACT" ]]; then
  # Find candidates first, then verify chain on each.
  candidates=$(jq -c --arg cid "$cycle_id" --arg sh "$scope_hash" '
    [.exceptions[]?
     | select(.type == "plan_review_completion")
     | select(.binding.cycle_id == $cid)
     | select(.binding.scope_hash == $sh)
     | select(.status == "approved")
    ]
  ' "$ARTIFACT" 2>/dev/null || echo "[]")
  n=$(printf '%s' "$candidates" | jq 'length' 2>/dev/null || echo 0)
  if [[ "$n" -gt 0 ]]; then
    # F2 + F4: each candidate must have a matching runner-written
    # audit event (event=obligation_completed referencing the
    # exception's id) AND prev_audit_sha must appear in the chain.
    # F4: forged direct edit with empty prev_audit_sha and no audit
    # log is NOT valid — runner-written audit entry is required.
    # v1.9.0 round-4 F1: invoke verify-audit-chain.sh for full chain
    # integrity before accepting a completion. Plus require an audit
    # entry referencing the candidate id (proves the runner — not a
    # forged direct edit — wrote the completion).
    chain_script="$(dirname -- "${BASH_SOURCE[0]}")/../../scripts/tdd/verify-audit-chain.sh"
    chain_ok=true
    if [[ -x "$chain_script" ]] && [[ -s "$AUDIT_LOG" ]]; then
      if ! ( cd "$PROJECT_DIR" && bash "$chain_script" "$cycle_id" >/dev/null 2>&1 ); then
        chain_ok=false
      fi
    fi
    if [[ "$chain_ok" == "true" ]]; then
      for i in $(seq 0 $((n - 1))); do
        candidate_id=$(printf '%s' "$candidates" | jq -r --argjson i "$i" '.[$i].id // ""')
        candidate_scope=$(printf '%s' "$candidates" | jq -r --argjson i "$i" '.[$i].binding.scope_hash // ""')
        stored_prev=$(printf '%s' "$candidates" | jq -r --argjson i "$i" '.[$i].binding.prev_audit_sha // ""')
        # v1.9.0 round-9 F2: NO legacy fallback for review-completion
        # types. They're a v1.9 invention; runner ALWAYS writes
        # obligation_completed with full binding. Empty prev_audit_sha
        # or missing scope_hash/review_type → forged.
        [[ ! -s "$AUDIT_LOG" ]] && continue
        audit_strict=$(jq -rs --arg id "$candidate_id" --arg cid "$cycle_id" --arg sh "$candidate_scope" '
          [.[]?
           | select(.event == "obligation_completed")
           | select(.exception_id == $id)
           | select(.cycle_id == $cid)
           | select(.scope_hash == $sh)
           | select(.review_type == "plan_review")
          ] | length > 0
        ' < <(while IFS= read -r line; do printf '%s\n' "$line"; done < "$AUDIT_LOG") 2>/dev/null || echo false)
        if [[ "$audit_strict" != "true" ]]; then
          continue
        fi
        # v1.9.0 round-10 F1: allow chain-head case. The FIRST
        # completion in a fresh cycle's audit log has empty
        # prev_audit_sha (it's the first line). Accept that ONLY
        # when verify-audit-chain.sh confirms the log is valid.
        if [[ -z "$stored_prev" ]]; then
          first_line=$(head -1 "$AUDIT_LOG" 2>/dev/null || echo "")
          # Check that the matching audit row IS the first line
          # (chain-head). Otherwise empty prev_sha is forged.
          first_line_ok=false
          if printf '%s' "$first_line" | jq -e --arg id "$candidate_id" '
            .event == "obligation_completed" and .exception_id == $id and (.prev_sha // "") == ""
          ' >/dev/null 2>&1; then
            first_line_ok=true
          fi
          if [[ "$first_line_ok" != "true" ]]; then
            continue
          fi
        fi
        # If stored_prev is non-empty it must appear in chain.
        if [[ -n "$stored_prev" ]]; then
          chain_link_ok=false
          while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if command -v sha256sum >/dev/null 2>&1; then
              line_sha=$(printf '%s' "$line" | sha256sum | awk '{print $1}')
            else
              line_sha=$(printf '%s' "$line" | shasum -a 256 | awk '{print $1}')
            fi
            if [[ "$line_sha" == "$stored_prev" ]]; then
              chain_link_ok=true
              break
            fi
          done < "$AUDIT_LOG"
          if [[ "$chain_link_ok" != "true" ]]; then
            continue
          fi
        fi
        matched=true
        break
      done
    fi
  fi
fi

if [[ "$matched" == "true" ]]; then
  jq -n '{}'
  exit 0
fi

# F1+F5: Record pending obligation before denying. The runner reads
# this pending entry to know the scope/files to bind.
mkdir -p "$(dirname "$ARTIFACT")" "$(dirname "$AUDIT_LOG")"
[[ -f "$ARTIFACT" ]] || cat > "$ARTIFACT" <<EOF
{"version":1,"cycle_id":"$cycle_id","phase":"red_confirmed","expires":"next_green_commit","exceptions":[]}
EOF
# Avoid duplicate pending entries for the same scope_hash.
already_pending=$(jq -r --arg cid "$cycle_id" --arg sh "$scope_hash" '
  [.exceptions[]?
   | select(.type == "plan_review_completion")
   | select(.binding.cycle_id == $cid)
   | select(.binding.scope_hash == $sh)
   | select(.status == "pending")] | length > 0
' "$ARTIFACT" 2>/dev/null || echo false)
if [[ "$already_pending" != "true" ]]; then
  next_n=$(jq -r '[.exceptions[]?.id // empty | capture("R-(?<n>[0-9]+)").n | tonumber] + [0] | max + 1' "$ARTIFACT")
  new_id=$(printf 'R-%03d' "$next_n")
  ts=$(date -u +%FT%TZ)
  # F1 (round-3): persist proposed content so the runner can review
  # what the AI is about to write (not git diff HEAD which is empty
  # since the edit hasn't landed).
  proposed_b64="$(printf '%s' "$proposed_content" | base64 -w0 2>/dev/null || printf '%s' "$proposed_content" | base64 | tr -d '\n')"
  jq --arg id "$new_id" \
     --arg cycle "$cycle_id" \
     --arg path "$file_path" \
     --arg ch "$content_hash" \
     --arg sh "$scope_hash" \
     --arg ts "$ts" \
     --arg b64 "$proposed_b64" \
     '.exceptions += [{
       "id": $id,
       "type": "plan_review_completion",
       "status": "pending",
       "created_by": "hook",
       "created_at": $ts,
       "scope": {"plan_path": $path, "plan_content_hash": $ch, "proposed_content_base64": $b64},
       "binding": {
         "cycle_id": $cycle,
         "plan_path": $path,
         "plan_content_hash": $ch,
         "scope_hash": $sh
       }
     }]' "$ARTIFACT" > "$ARTIFACT.tmp" && mv "$ARTIFACT.tmp" "$ARTIFACT"
fi

# Deny with stable error code.
jq -n --arg path "$file_path" --arg cid "$cycle_id" --arg sh "$scope_hash" '
  {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("PLAN_REVIEW_REQUIRED. Plan write at " + $path + " requires /second-opinion review before it lands. Run: scripts/tdd/run-second-opinion.sh plan_review " + $cid + ". Expected scope_hash: " + $sh + ". After completion is recorded, retry the edit. The AI does not decide to skip this.")
    }
  }'
exit 0
