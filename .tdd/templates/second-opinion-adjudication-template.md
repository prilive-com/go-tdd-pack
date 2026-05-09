# Second opinion adjudication
date: <YYYY-MM-DDTHH:MM:SSZ>
scope: <Tier 1 | non-Tier-1>
model: <model name from the chat header you printed in Step 5>
diff_sha256: <64-hex; see SKILL.md Step 6a sha256() helper (portable across Linux sha256sum and macOS shasum -a 256)>
plan_sha256: <64-hex; same helper, applied to .tdd/current-plan.md>
files_in_scope:
  - <one path per line, every file the review touched>
findings_total: <N — must equal the count of `findings:` blocks below>
adjudication_summary: |
  <one paragraph summarizing your stance — accepts vs rejects vs
   pushbacks, what changed in the plan/code as a result>
findings:
  # One block per finding. Required keys: id, severity, stance.
  #
  # PARTIAL stance ALSO requires: accepted, rejected, why_split. Each
  # must be substantive — "nothing"/"n/a"/"none"/blank/<10 chars are
  # rejected by the require-second-opinion.sh PARTIAL discipline check
  # because that's the historical sycophancy-theatre failure mode.
  #
  # P0 ACCEPT ALSO requires: why_correct (≥3 sentences explaining the
  # underlying technical claim, not "Codex flagged X").
  - id: F1
    severity: <P0|P1|P2|P3>
    stance: <ACCEPT|REJECT|PARTIAL|PUSHBACK>
    # For PARTIAL only:
    # accepted: <what you are taking from the finding>
    # rejected: <what you disagree with — substantive, not "nothing">
    # why_split: <≥2 sentences>
    # For P0 ACCEPT only:
    # why_correct: <≥3 sentences explaining the technical claim>
adjudicated_by: claude

# ---
# Hash binding (F5 cycle): the require-second-opinion.sh hook compares
# diff_sha256 and plan_sha256 against current content when
# second_opinion.require_hash_binding_tier1=true (Tier 1 only). Compute
# both BEFORE writing this file so the hashes are stable. Empty stream
# still produces a 64-hex sha; an empty diff_sha256 string is treated
# as "field missing" and the hook denies — both fields must be present
# and non-empty hex.
#
# Killswitch (emergency unblock; document in commit message if used):
#   SECOND_OPINION_HASH_DISABLE=1 git ...
