#!/usr/bin/env bash
# hooks/inject-findings.sh
#
# v2.0 sync hook (PostToolUse + UserPromptSubmit). Reads .tdd/reviews/state.json
# and emits additionalContext as a system reminder if findings are pending.
#
# Two firing points for defense-in-depth against anthropics/claude-code#18427
# (PostToolUse additionalContext may not inject reliably on Edit/Write in some
# Claude Code builds):
#   - PostToolUse: immediate next turn — preferred path
#   - UserPromptSubmit: surfaces findings on the user's next prompt — fallback

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
STATE="${PROJECT_DIR}/.tdd/reviews/state.json"

# Honor disable.
if [[ "${PRILIVE_REVIEW_DISABLE:-0}" == "1" ]]; then
  exit 0
fi

# No state file = no active cycle = nothing to inject.
if [[ ! -f "${STATE}" ]]; then
  exit 0
fi

# Need jq to parse state.
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

STATUS=$(jq -r '.status // empty' "${STATE}" 2>/dev/null)
CYCLE_ID=$(jq -r '.cycle_id // empty' "${STATE}" 2>/dev/null)
ROUND=$(jq -r '.round // 1' "${STATE}" 2>/dev/null)

if [[ -z "${STATUS}" ]] || [[ -z "${CYCLE_ID}" ]]; then
  exit 0
fi

CYCLE_DIR="${PROJECT_DIR}/.tdd/reviews/${CYCLE_ID}"

# --- helper: emit additionalContext JSON ---
emit_context() {
  local ctx="$1"
  local event="${2:-PostToolUse}"
  # Cap at 49500 chars to stay under additionalContext 50KB ceiling
  # (Claude Code platform limit). Earlier 9800 cap was overly conservative
  # and silently dropped the majority of findings when Codex returned a
  # long list. Quality-tuned higher cap preserves the full signal.
  ctx="${ctx:0:49500}"
  jq -nc \
    --arg event "${event}" \
    --arg ctx "${ctx}" \
    '{hookSpecificOutput: {hookEventName: $event, additionalContext: $ctx}}'
}

# --- behavior by cycle status ---
case "${STATUS}" in
  reviewing)
    # Cycle is in flight. Nothing to inject yet.
    exit 0
    ;;
  converged|abandoned|resolved_by_user_claude|resolved_by_user_codex)
    # Cycle is done cleanly. Nothing to inject.
    exit 0
    ;;
  failed)
    # Cycle failed (codex crash, auth expiry, no-git workdir, etc.).
    # Surface ONCE per failed cycle so the adopter knows to look at
    # .tdd/runner.log. Avoid spamming every turn — write a marker file
    # under the cycle dir so subsequent invocations stay silent.
    MARKER="${CYCLE_DIR}/.failure-surfaced"
    if [[ ! -f "${MARKER}" ]]; then
      DETAIL=""
      if [[ -f "${CYCLE_DIR}/.status" ]]; then
        DETAIL=$(head -1 "${CYCLE_DIR}/.status" 2>/dev/null)
      fi
      HINT=""
      case "${DETAIL}" in
        *codex_exec_nonzero*|*codex_resume_nonzero*)
          HINT="Likely cause: Codex CLI error. Common: expired ChatGPT auth (run \`codex login\` to refresh), API quota, or network. Check \`.tdd/runner.log\` for the raw Codex stderr."
          ;;
        *invalid_json*|*missing_fields*)
          HINT="Codex returned unexpected output. Schema validation failed. Check \`.tdd/reviews/${CYCLE_ID}/round-1.json\` and \`.tdd/runner.log\`."
          ;;
        *no_session*|*no_response*|*no_round1*)
          HINT="Internal state inconsistency. Check \`.tdd/reviews/${CYCLE_ID}/\` for missing artifacts."
          ;;
        *)
          HINT="Check \`.tdd/runner.log\` for runner stderr."
          ;;
      esac
      emit_context "[Codex review failed — cycle ${CYCLE_ID}, round ${ROUND}, detail: ${DETAIL:-unknown}]

${HINT}

The runner is fail-open: subsequent edits will start fresh cycles. To
suppress this notice and move on, run /abandon-review."
      touch "${MARKER}" 2>/dev/null
    fi
    exit 0
    ;;
  request_changes)
    # Codex returned findings. Inject for Claude's next turn.
    ;;
  escalated)
    # v2.0 Phase 2: delegate to runner/escalate.sh, which renders the
    # full A/B/V message with Claude's + Codex's final positions.
    ESCALATE="${PROJECT_DIR}/runner/escalate.sh"
    if [[ -x "${ESCALATE}" ]]; then
      "${ESCALATE}" "${CYCLE_ID}" "${PROJECT_DIR}"
    else
      # Fallback if escalate.sh is missing.
      emit_context "[Codex review escalation — cycle ${CYCLE_ID}, round ${ROUND}] Claude and Codex did not converge. Tell me how to proceed."
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac

# --- compose findings injection (request_changes branch) ---
ROUND1_JSON="${CYCLE_DIR}/round-1.json"
if [[ ! -f "${ROUND1_JSON}" ]]; then
  # Findings file missing — shouldn't happen but be defensive.
  exit 0
fi

VERDICT_SUMMARY=$(jq -r '.summary_one_sentence // "review requested"' "${ROUND1_JSON}" 2>/dev/null)

# Filter knobs from tdd-pack.toml:
#   [severity] min_surface       — minimum severity surfaced to Claude
#   [severity] must_address      — severity that drives a blocking finding
#   [severity] confidence_floor  — confidence floor for blocking findings (v2.1)
# Severity numeric order: blocker=4, major=3, minor=2, nit=1.
# Confidence numeric order: 5=verified, 4=high static, 3=likely, 2=plausible, 1=guess.
# shellcheck source=../runner/lib/config.sh
. "${PROJECT_DIR}/runner/lib/config.sh"
MIN_SURFACE=$(cfg_get "${PROJECT_DIR}/tdd-pack.toml" "severity.min_surface" "nit")
CONFIDENCE_FLOOR=$(cfg_get "${PROJECT_DIR}/tdd-pack.toml" "severity.confidence_floor" "4")

# --- v2.1 rails: four layered demotion filters -----------------------------
#
# Rail A — tool-grounding (spec §5.1):
#   A finding with `contradicts_grounding: true` is one Codex flagged as
#   falling in a category a deterministic tool covers (gofmt, golangci-lint,
#   staticcheck, go vet, gosec, govulncheck, race) where the tool passed
#   clean on the cited line and Codex has no reproducible failure to cite.
#
# Rail B — confidence floor (spec §5.2):
#   A finding only drives must-address when severity ≥ must_address AND
#   confidence ≥ confidence_floor. Below the floor → speculative.
#
# Rail C — line scope (spec §6):
#   A finding with `line_scope: "pre_existing_unrelated"` is on a CONTEXT
#   line that the author did NOT touch or trigger. The author is not on
#   the hook for pre-existing tech debt — these findings are demoted
#   regardless of severity, category, or carve-out. Rail C overrides
#   the never-demote category list (different rule, different reason).
#
# Rail D — perspective-diverse consensus (spec §6, PR 9 infra):
#   When Tier-1 round 1 ran in parallel through multiple angles
#   (security/correctness/architecture, PR 9b producer), each angle
#   tags its findings with raised_by_angle. The engine groups by
#   file:line and keeps consensus findings (≥2 angles raised it);
#   singletons are demoted to display-only — the whole point of
#   multi-angle review IS the consensus signal, so a singleton is by
#   definition the marginal-confidence case.
#   Findings with raised_by_angle absent or "default" are from the
#   single-reviewer path and bypass this rail entirely.
#   The Rail A carve-out does NOT apply here — singletons demote
#   regardless of category. Rationale: the consensus IS the protection
#   against false positives in semantic categories too.
#
# Any of the four rails can demote a finding to the speculative section.
# The reasons are tracked separately so adopters can tell why a finding
# wasn't surfaced as blocking.
#
# DEFENSIVE CARVE-OUT — load-bearing for Rail A.
# These categories catch what tools cannot judge: silent nil dereferences
# in semantic paths, missing invariants, broken contracts. Tool silence
# does NOT mean these concerns are unfounded. Even if Codex set
# contradicts_grounding=true on a finding in one of these categories
# (it shouldn't per the prompt, but might), the engine refuses to demote
# it. The list is intentionally short — widening it would weaken the
# tool's genuine strength.
#
# NOTE: the carve-out applies to Rail A only. Rail B (confidence floor)
# does apply to every category — a low-confidence semantic finding is
# still speculative until corroborated.
NEVER_DEMOTE_CATEGORIES='correctness|design|test_quality|security|safety|data_loss|blast_radius'

# Split findings via jq:
#   promoted = passes both rails (drives the must-address list)
#   demoted  = at least one rail demoted it (informational, not blocking)
#
# Tagging the demoted findings with a `demotion_reason` field lets the
# rendering show why each was demoted.

# Precompute the multi-angle consensus map ONCE: a JSON array of
# "file|line" keys that have ≥2 distinct non-default raised_by_angle
# values among the findings. This lets jq decide Rail D per finding
# with a simple lookup. The map is empty for single-reviewer cycles
# (no findings have a non-default angle).
CONSENSUS_KEYS=$(jq -c '
  [.findings[]?
    | select((.raised_by_angle // "default") != "default")
    | {key: ((.file // "") + "|" + ((.line // 0) | tostring)),
       angle: .raised_by_angle}]
  | group_by(.key)
  | map({key: .[0].key, angles: (map(.angle) | unique)})
  | map(select(.angles | length >= 2) | .key)
' "${ROUND1_JSON}" 2>/dev/null)
[[ -z "${CONSENSUS_KEYS}" ]] && CONSENSUS_KEYS='[]'

PROMOTED=$(jq -r --arg ms "${MIN_SURFACE}" --arg cf "${CONFIDENCE_FLOOR}" --arg nd "${NEVER_DEMOTE_CATEGORIES}" --argjson consensus "${CONSENSUS_KEYS}" '
  def sn($s): {"blocker":4, "major":3, "minor":2, "nit":1}[$s] // 0;
  def is_never_demote: (.category | test("^(" + $nd + ")$"));
  def demoted_by_grounding:  (.contradicts_grounding == true) and (is_never_demote | not);
  def demoted_by_confidence: ((.confidence // 5) < ($cf | tonumber));
  def demoted_by_scope:      ((.line_scope // "changed_line") == "pre_existing_unrelated");
  def angle: (.raised_by_angle // "default");
  def fkey:  ((.file // "") + "|" + ((.line // 0) | tostring));
  def demoted_by_singleton: (angle != "default") and (([fkey] | inside($consensus)) | not);
  [.findings[]?
    | select(demoted_by_grounding  | not)
    | select(demoted_by_confidence | not)
    | select(demoted_by_scope      | not)
    | select(demoted_by_singleton  | not)
    | select(sn(.severity) >= sn($ms))]
  | if length == 0 then "(no findings at or above min_surface=\($ms) with confidence ≥ \($cf))"
    else (
      map(
        "- [\(.severity)/\(.category) c=\(.confidence // "?")] \(.title)\n  \(.body)"
        + (if .file != "" then "\n  at \(.file):\(.line // 0)" else "" end)
      ) | join("\n")
    )
    end
' "${ROUND1_JSON}" 2>/dev/null)

DEMOTED=$(jq -r --arg ms "${MIN_SURFACE}" --arg cf "${CONFIDENCE_FLOOR}" --arg nd "${NEVER_DEMOTE_CATEGORIES}" --argjson consensus "${CONSENSUS_KEYS}" '
  def sn($s): {"blocker":4, "major":3, "minor":2, "nit":1}[$s] // 0;
  def is_never_demote: (.category | test("^(" + $nd + ")$"));
  def demoted_by_grounding:  (.contradicts_grounding == true) and (is_never_demote | not);
  def demoted_by_confidence: ((.confidence // 5) < ($cf | tonumber));
  def demoted_by_scope:      ((.line_scope // "changed_line") == "pre_existing_unrelated");
  def angle: (.raised_by_angle // "default");
  def fkey:  ((.file // "") + "|" + ((.line // 0) | tostring));
  def demoted_by_singleton: (angle != "default") and (([fkey] | inside($consensus)) | not);
  [.findings[]?
    | select(sn(.severity) >= sn($ms))
    | select(demoted_by_grounding or demoted_by_confidence or demoted_by_scope or demoted_by_singleton)]
  | if length == 0 then ""
    else (
      "\n\nSpeculative (demoted; informational only, does NOT block):\n" + (
        map(
          # Build compound demotion reason from each fired rail.
          ([
            (if demoted_by_scope      then "pre-existing unrelated" else empty end),
            (if demoted_by_grounding  then "tool-clean" else empty end),
            (if demoted_by_confidence then "low-confidence c=\(.confidence // "?") < floor \($cf)" else empty end),
            (if demoted_by_singleton  then "single-angle (" + angle + ", no consensus)" else empty end)
          ] | join(" + ")) as $reason
          | "- [" + $reason + "] [\(.severity)/\(.category) c=\(.confidence // "?")] \(.title)\n  \(.body)"
          + (if .file != "" then "\n  at \(.file):\(.line // 0)" else "" end)
        ) | join("\n")
      )
    )
    end
' "${ROUND1_JSON}" 2>/dev/null)

CONTEXT="[Codex review — cycle ${CYCLE_ID}, round ${ROUND}, status: changes requested]

Summary: ${VERDICT_SUMMARY}

Findings:
${PROMOTED}${DEMOTED}

What to do next:
- If you agree with a finding, fix the code silently. The runner will re-review.
- If you disagree, write a one-line rationale in a code comment or in your next response.
- Speculative (demoted) findings are informational — address them if obvious, ignore otherwise.
- Do NOT ask the user about review issues. Continue working.
- Your next response will be captured and sent to Codex for re-review (Phase 2).
- For MVP, you may continue iterating; the runner will not auto-re-fire until Phase 2 ships."

emit_context "${CONTEXT}" "PostToolUse"
