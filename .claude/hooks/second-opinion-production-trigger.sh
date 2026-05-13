#!/usr/bin/env bash
# .claude/hooks/second-opinion-production-trigger.sh
#
# v1.9.0 — PreToolUse hook. Fires on Edit/Write/MultiEdit of any
# production .go file (outside test files, governance/docs/scripts/
# vendor dirs). Per-cycle-per-base_git_sha scope: one completion
# covers all production edits in the cycle until base_git_sha
# advances (next commit). Includes file-list drift detection
# (PRODUCTION_SCOPE_DRIFT).
#
# Stable error codes:
#   PRODUCTION_EDIT_REVIEW_REQUIRED  — no matching completion at base_sha.
#   PRODUCTION_SCOPE_DRIFT           — completion's recorded file list
#                                      doesn't include the new file.
#   REVIEW_COMPLETION_EXPIRED        — completion at older base_sha.

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "[second-opinion-production-trigger] BLOCKED: jq required." >&2
  exit 2
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CONFIG="$PROJECT_DIR/.tdd/tdd-config.json"
PLAN="$PROJECT_DIR/.tdd/current-plan.md"
ARTIFACT="$PROJECT_DIR/.tdd/exceptions/post-red-test-edits.json"
HASH_SCOPE="$(dirname -- "${BASH_SOURCE[0]}")/../../scripts/tdd/hash-review-scope.sh"

[[ ! -f "$CONFIG" ]] && exit 0
enabled="$(jq -r '.second_opinion.no_discretion.enabled // false' "$CONFIG" 2>/dev/null || echo false)"
prod_required="$(jq -r '.second_opinion.no_discretion.required_for.production_edits // false' "$CONFIG" 2>/dev/null || echo false)"
[[ "$enabled" != "true" ]] && exit 0
[[ "$prod_required" != "true" ]] && exit 0

PAYLOAD="$(cat)"
if ! printf '%s' "$PAYLOAD" | jq -e . >/dev/null 2>&1; then
  echo "[second-opinion-production-trigger] BLOCKED: malformed JSON input — fail closed." >&2
  exit 2
fi
tool_name="$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""')"
case "$tool_name" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

file_path="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_input.path // ""' 2>/dev/null || echo "")"
[[ -z "$file_path" ]] && exit 0

# Path filter — production .go files only.
case "$file_path" in
  *_test.go) exit 0 ;;
  .claude/*|*/.claude/*) exit 0 ;;
  .tdd/*|*/.tdd/*) exit 0 ;;
  docs/*|*/docs/*) exit 0 ;;
  specs/*|*/specs/*) exit 0 ;;
  scripts/*|*/scripts/*) exit 0 ;;
  archive/*|*/archive/*) exit 0 ;;
  vendor/*|*/vendor/*) exit 0 ;;
esac
case "$file_path" in
  *.go) ;;
  *) exit 0 ;;
esac

# Tier classification.
tier_level="tier2"
while IFS= read -r pattern; do
  [[ -z "$pattern" ]] && continue
  if printf '%s' "$file_path" | grep -qE "$pattern" 2>/dev/null; then
    tier_level="tier1"
    break
  fi
done < <(jq -r '.tier1_path_regexes[]? // empty' "$CONFIG" 2>/dev/null || true)

# Cycle ID + base_git_sha.
cycle_id="$( { grep -E '^Cycle ID:' "$PLAN" 2>/dev/null || true; } | head -1 | sed -E 's/^Cycle ID:[[:space:]]*//')"
[[ -z "$cycle_id" ]] && cycle_id="unknown-cycle"
base_git_sha=""
if command -v git >/dev/null 2>&1 && [[ -d "$PROJECT_DIR/.git" ]]; then
  base_git_sha="$( cd "$PROJECT_DIR" && git rev-parse HEAD 2>/dev/null || echo "" )"
fi
[[ -z "$base_git_sha" ]] && base_git_sha="no-git"

# scope_hash = sha256(production_edit|cycle_id|base_git_sha|tier_level).
if [[ -x "$HASH_SCOPE" ]]; then
  scope_hash="$(bash "$HASH_SCOPE" production_edit "$cycle_id" "$base_git_sha" "$tier_level" 2>/dev/null || echo "")"
else
  scope_hash="$(printf 'production_edit|%s|%s|%s' "$cycle_id" "$base_git_sha" "$tier_level" | sha256sum | awk '{print $1}')"
fi

# Compute the drift scope_hash for the current file (F2 round-5: after
# the runner approves a drift_extension completion, the hook needs to
# match it for THIS specific file).
drift_scope_hash_for_file="$(printf 'production_edit_drift|%s|%s|%s|%s' "$cycle_id" "$base_git_sha" "$tier_level" "$file_path" | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | awk '{print $1}')"

# Look for matching completion AT THIS base_git_sha + tier_level.
# Accept either: (a) normal production scope_hash, OR (b) a drift
# scope_hash for THIS specific file (created when drift was detected
# and the runner approved it).
matched_entry=""
expired_at_old_sha=""
if [[ -f "$ARTIFACT" ]]; then
  # v1.9.0 round-9 F3: prefer the drift-scope completion for THIS
  # specific file when present; only fall back to the broad normal-
  # scope completion otherwise. Without this, retrying a drift-
  # approved edit kept selecting the original normal-scope entry and
  # re-denying with PRODUCTION_SCOPE_DRIFT (deadlock).
  matched_entry="$(jq -c --arg cid "$cycle_id" --arg dsh "$drift_scope_hash_for_file" '
    [.exceptions[]?
     | select(.type == "production_edit_review_completion")
     | select(.binding.cycle_id == $cid)
     | select(.binding.scope_hash == $dsh)
     | select(.status == "approved")] | .[0] // empty
  ' "$ARTIFACT" 2>/dev/null || echo "")"
  if [[ -z "$matched_entry" ]] || [[ "$matched_entry" == "null" ]]; then
    matched_entry="$(jq -c --arg cid "$cycle_id" --arg sh "$scope_hash" '
      [.exceptions[]?
       | select(.type == "production_edit_review_completion")
       | select(.binding.cycle_id == $cid)
       | select(.binding.scope_hash == $sh)
       | select(.status == "approved")] | .[0] // empty
    ' "$ARTIFACT" 2>/dev/null || echo "")"
  fi
  # Check whether a completion exists at a DIFFERENT base_git_sha
  # for the same cycle/tier (used to emit REVIEW_COMPLETION_EXPIRED).
  if [[ -z "$matched_entry" ]]; then
    expired_at_old_sha="$(jq -r --arg cid "$cycle_id" --arg tier "$tier_level" '
      [.exceptions[]?
       | select(.type == "production_edit_review_completion")
       | select(.binding.cycle_id == $cid)
       | select(.binding.tier_level == $tier // null)
       | select(.status == "approved")
      ] | length > 0
    ' "$ARTIFACT" 2>/dev/null || echo false)"
  fi
fi

if [[ -n "$matched_entry" ]] && [[ "$matched_entry" != "null" ]]; then
  # F3 (FIRST): empty scope = INVALID (not unlimited). Detect before
  # audit-chain check because empty scope is a stronger invariant.
  scope_glob_count=$(printf '%s' "$matched_entry" | jq -r '(.scope.allowed_file_globs // .scope.paths // []) | length')
  if [[ "$scope_glob_count" -eq 0 ]]; then
    jq -n --arg path "$file_path" --arg cid "$cycle_id" '
      {
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: ("PRODUCTION_SCOPE_DRIFT. Completion has empty allowed_file_globs — treated as INVALID (not unlimited scope). The completion must record the reviewed file set. Re-run: scripts/tdd/run-second-opinion.sh production_edit " + $cid)
        }
      }'
    exit 0
  fi

  # F2 + F4 (round-6): jq-parse audit lines and require a specific
  # `obligation_completed` event whose exception_id, cycle_id,
  # scope_hash, and review_type ALL match the candidate.
  AUDIT_LOG="$PROJECT_DIR/.tdd/audit/${cycle_id}.jsonl"
  stored_prev=$(printf '%s' "$matched_entry" | jq -r '.binding.prev_audit_sha // ""')
  completion_id=$(printf '%s' "$matched_entry" | jq -r '.id // ""')
  completion_scope_hash=$(printf '%s' "$matched_entry" | jq -r '.binding.scope_hash // ""')
  chain_ok=false
  if [[ -s "$AUDIT_LOG" ]] && [[ -n "$completion_id" ]]; then
    # Require audit line where exception_id+cycle_id match. Accept
    # both v1.9.0 runner-written events (event=obligation_completed)
    # and legacy v1.7.0-era events (event=granted) for backwards-
    # compatibility with mixed cycles.
    audit_match=$(jq -rs --arg id "$completion_id" --arg cid "$cycle_id" '
      [.[]?
       | select(.event == "obligation_completed" or .event == "granted")
       | select(.exception_id == $id)
       | select(.cycle_id == $cid)
      ] | length > 0
    ' < <(while IFS= read -r line; do printf '%s\n' "$line"; done < "$AUDIT_LOG") 2>/dev/null || echo false)
    if [[ "$audit_match" == "true" ]]; then
      # v1.9.0 round-8 F2: a v1.9 review-completion (production_edit_review_completion)
      # MUST have a non-empty prev_audit_sha that links to the chain.
      # Empty prev_audit_sha is only acceptable for v1.7-era typed
      # exceptions (which use event=granted and don't need v1.9
      # SHA-chain linkage). Distinguish by the audit event type.
      strict_v19_event=$(jq -rs --arg id "$completion_id" --arg cid "$cycle_id" '
        [.[]?
         | select(.event == "obligation_completed")
         | select(.exception_id == $id)
         | select(.cycle_id == $cid)
        ] | length > 0
      ' < <(while IFS= read -r line; do printf '%s\n' "$line"; done < "$AUDIT_LOG") 2>/dev/null || echo false)
      if [[ "$strict_v19_event" == "true" ]] && [[ -z "$stored_prev" ]]; then
        # v1.9 entry missing prev_audit_sha — forged.
        chain_ok=false
      elif [[ -z "$stored_prev" ]]; then
        # v1.7-era event, no chain required.
        chain_ok=true
      else
        while IFS= read -r aline; do
          [[ -z "$aline" ]] && continue
          if command -v sha256sum >/dev/null 2>&1; then
            line_sha=$(printf '%s' "$aline" | sha256sum | awk '{print $1}')
          else
            line_sha=$(printf '%s' "$aline" | shasum -a 256 | awk '{print $1}')
          fi
          if [[ "$line_sha" == "$stored_prev" ]]; then
            chain_ok=true
            break
          fi
        done < "$AUDIT_LOG"
      fi
    fi
  fi
  if [[ "$chain_ok" != "true" ]]; then
    jq -n --arg path "$file_path" --arg cid "$cycle_id" '
      {
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: ("PRODUCTION_EDIT_REVIEW_REQUIRED. Existing completion lacks valid audit-chain link (forged or stale). Re-run: scripts/tdd/run-second-opinion.sh production_edit " + $cid)
        }
      }'
    exit 0
  fi

  # Check file-list drift: is file_path within the recorded allowed_file_globs?
  drift=$(printf '%s' "$matched_entry" | jq -r --arg fp "$file_path" '
    (.scope.allowed_file_globs // .scope.paths // [])
    | any(.[];
        . as $g
        | $fp | test("^" + ($g
            | gsub("\\."; "\\.")
            | gsub("\\*\\*/"; "(.*/)?")
            | gsub("\\*\\*"; ".*")
            | gsub("\\*"; "[^/]*")) + "$"))
    | not
  ' 2>/dev/null || echo true)
  if [[ "$drift" == "true" ]]; then
    # v1.9.0 round-4 F4: drift creates a FRESH pending obligation
    # for THIS file so the operator can run the runner and unblock.
    # Otherwise the system deadlocks (drift denies; runner needs a
    # pending entry that doesn't exist).
    # Use a drift-specific scope_hash so the pending entry doesn't
    # collide with the existing approved completion.
    drift_scope_hash="$(printf 'production_edit_drift|%s|%s|%s|%s' "$cycle_id" "$base_git_sha" "$tier_level" "$file_path" | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | awk '{print $1}')"
    # Only write the pending entry if one doesn't already exist for this drift scope.
    drift_pending=$(jq -r --arg cid "$cycle_id" --arg sh "$drift_scope_hash" '
      [.exceptions[]?
       | select(.type == "production_edit_review_completion")
       | select(.binding.cycle_id == $cid)
       | select(.binding.scope_hash == $sh)
       | select(.status == "pending")] | length > 0
    ' "$ARTIFACT" 2>/dev/null || echo false)
    if [[ "$drift_pending" != "true" ]]; then
      drift_next_n=$(jq -r '[.exceptions[]?.id // empty | capture("R-(?<n>[0-9]+)").n | tonumber] + [0] | max + 1' "$ARTIFACT")
      drift_new_id=$(printf 'R-%03d' "$drift_next_n")
      drift_ts=$(date -u +%FT%TZ)
      drift_payload="$(printf '%s' "$PAYLOAD" | jq -c '{tool_name: .tool_name, file_path: (.tool_input.file_path // .tool_input.path), old_string: .tool_input.old_string, new_string: .tool_input.new_string, content: .tool_input.content, edits: .tool_input.edits}')"
      drift_b64="$(printf '%s' "$drift_payload" | base64 -w0 2>/dev/null || printf '%s' "$drift_payload" | base64 | tr -d '\n')"
      jq --arg id "$drift_new_id" --arg cycle "$cycle_id" --arg sha "$base_git_sha" \
         --arg tier "$tier_level" --arg sh "$drift_scope_hash" --arg fp "$file_path" --arg ts "$drift_ts" \
         --arg b64 "$drift_b64" \
         '.exceptions += [{
           "id": $id, "type": "production_edit_review_completion", "status": "pending",
           "created_by": "hook", "created_at": $ts,
           "scope": {"first_seen_file": $fp, "proposed_payload_base64": $b64, "drift_extension": true},
           "binding": {"cycle_id": $cycle, "base_git_sha": $sha, "tier_level": $tier, "scope_hash": $sh}
         }]' "$ARTIFACT" > "$ARTIFACT.tmp" && mv "$ARTIFACT.tmp" "$ARTIFACT"
    fi
    jq -n --arg path "$file_path" --arg cid "$cycle_id" '
      {
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: ("PRODUCTION_SCOPE_DRIFT. Edit at " + $path + " is outside the recorded scope of the existing completion for cycle " + $cid + ". A new pending obligation has been written for this drift scope; run: scripts/tdd/run-second-opinion.sh production_edit " + $cid + " — Codex will review this specific file against the existing approved set.")
        }
      }'
    exit 0
  fi
  # Match, chain ok, scope ok, no drift → allow.
  jq -n '{}'
  exit 0
fi

# No match. Differentiate REVIEW_COMPLETION_EXPIRED vs PRODUCTION_EDIT_REVIEW_REQUIRED.
if [[ "$expired_at_old_sha" == "true" ]]; then
  jq -n --arg path "$file_path" --arg cid "$cycle_id" --arg sha "$base_git_sha" '
    {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: ("REVIEW_COMPLETION_EXPIRED. Prior production_edit_review_completion for cycle " + $cid + " was bound to an older base_git_sha. HEAD has advanced to " + $sha + ". Run: scripts/tdd/run-second-opinion.sh production_edit " + $cid)
      }
    }'
  exit 0
fi

# F1+F5: record pending obligation before denying.
ARTIFACT="$PROJECT_DIR/.tdd/exceptions/post-red-test-edits.json"
AUDIT_LOG_DIR="$PROJECT_DIR/.tdd/audit"
mkdir -p "$(dirname "$ARTIFACT")" "$AUDIT_LOG_DIR"
[[ -f "$ARTIFACT" ]] || printf '%s\n' "{\"version\":1,\"cycle_id\":\"$cycle_id\",\"phase\":\"red_confirmed\",\"expires\":\"next_green_commit\",\"exceptions\":[]}" > "$ARTIFACT"
already_pending=$(jq -r --arg cid "$cycle_id" --arg sh "$scope_hash" '
  [.exceptions[]?
   | select(.type == "production_edit_review_completion")
   | select(.binding.cycle_id == $cid)
   | select(.binding.scope_hash == $sh)
   | select(.status == "pending")] | length > 0
' "$ARTIFACT" 2>/dev/null || echo false)
# Always (re)compute proposed_payload so it reflects the LATEST
# denied attempt (v1.9.0 round-9 F4: revised production edits must
# update the pending payload so the runner reviews the current
# proposal, not the first one).
proposed_payload="$(printf '%s' "$PAYLOAD" | jq -c '{tool_name: .tool_name, file_path: (.tool_input.file_path // .tool_input.path), old_string: .tool_input.old_string, new_string: .tool_input.new_string, content: .tool_input.content, edits: .tool_input.edits}')"
proposed_b64="$(printf '%s' "$proposed_payload" | base64 -w0 2>/dev/null || printf '%s' "$proposed_payload" | base64 | tr -d '\n')"
ts=$(date -u +%FT%TZ)

if [[ "$already_pending" == "true" ]]; then
  # Update existing pending entry's proposed_payload (round-9 F4).
  jq --arg cycle "$cycle_id" --arg sh "$scope_hash" --arg b64 "$proposed_b64" --arg ts "$ts" --arg fp "$file_path" '
    .exceptions = (.exceptions | map(
      if .type == "production_edit_review_completion"
         and .binding.cycle_id == $cycle
         and .binding.scope_hash == $sh
         and .status == "pending"
      then
        .scope.proposed_payload_base64 = $b64
        | .scope.last_attempt_at = $ts
        | .scope.last_attempt_file = $fp
      else . end
    ))
  ' "$ARTIFACT" > "$ARTIFACT.tmp" && mv "$ARTIFACT.tmp" "$ARTIFACT"
else
  next_n=$(jq -r '[.exceptions[]?.id // empty | capture("R-(?<n>[0-9]+)").n | tonumber] + [0] | max + 1' "$ARTIFACT")
  new_id=$(printf 'R-%03d' "$next_n")
  jq --arg id "$new_id" --arg cycle "$cycle_id" --arg sha "$base_git_sha" \
     --arg tier "$tier_level" --arg sh "$scope_hash" --arg fp "$file_path" --arg ts "$ts" \
     --arg b64 "$proposed_b64" \
     '.exceptions += [{
       "id": $id, "type": "production_edit_review_completion", "status": "pending",
       "created_by": "hook", "created_at": $ts,
       "scope": {"first_seen_file": $fp, "proposed_payload_base64": $b64},
       "binding": {"cycle_id": $cycle, "base_git_sha": $sha, "tier_level": $tier, "scope_hash": $sh}
     }]' "$ARTIFACT" > "$ARTIFACT.tmp" && mv "$ARTIFACT.tmp" "$ARTIFACT"
fi

jq -n --arg path "$file_path" --arg cid "$cycle_id" --arg sh "$scope_hash" --arg tier "$tier_level" --arg sha "$base_git_sha" '
  {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("PRODUCTION_EDIT_REVIEW_REQUIRED. Production .go edit at " + $path + " requires /second-opinion review for this commit boundary. Run: scripts/tdd/run-second-opinion.sh production_edit " + $cid + ". Expected scope_hash: " + $sh + " (tier_level=" + $tier + ", base_git_sha=" + $sha + "). One completion covers all production edits in this cycle until the next commit advances base_git_sha.")
    }
  }'
exit 0
