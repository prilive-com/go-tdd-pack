---
name: second-opinion
description: |
  Get a cross-model second opinion on a plan or code change before
  implementing it. Calls OpenAI Codex CLI (read-only) to review the
  current plan, the current diff, or a specific snippet. Returns
  honest findings — not blocking, advisory only. Use BEFORE any
  non-trivial code change (Tier 1 or not), or when the user says
  "second opinion", "ask codex", "what would another model think",
  or "/second-opinion".
when_to_use: |
  Auto-invoke before any non-trivial code change, regardless of Tier:
    - Implementing a new feature, function, type, or significant logic.
    - Fixing a bug whose root cause you are not 100% sure of.
    - Any cross-package or cross-file change.
    - Any architecture / API design decision.
    - Refactor that touches >30 lines or changes public API surface.
    - Any change on a Tier 1 path (always, regardless of size; uses a
      stronger model for these — see Step 3).
  Manually invoke when the user says:
    - "second opinion" / "ask codex" / "what would another model say"
    - "/second-opinion plan" / "/second-opinion diff" / "/second-opinion file <path>"
  Skip when (the truly trivial cases):
    - The change is a typo, formatting, or doc-only edit.
    - The change is a single-line bugfix with a mechanically obvious cause.
    - The change is to non-code project files (.gitignore, .editorconfig,
      CHANGELOG, README cosmetic edits) with no behavior impact.
    - You already have explicit user APPROVED on a Tier 1 plan and
      are mid-implementation (the spec gate already cleared it).
    - The user said "skip second opinion" or "/second-opinion off".
    - SECOND_OPINION_DISABLE=1 is set, OR `codex` is not installed.
license: MIT
version: 1.2.0
---

# Second Opinion (cross-model review via Codex CLI)

Sends a plan, diff, or snippet to OpenAI Codex CLI as a **read-only
external reviewer**. Returns structured findings. You stay the final
adjudicator — Codex is a peer reviewer, not authority.

This skill exists because two models from different families catch
different blind spots. Anthropic and OpenAI training corpora and
RLHF pipelines diverge enough that "what Codex notices" is a real
signal, not noise.

## Data flow (what gets sent to OpenAI)

When this skill runs, the following is sent to OpenAI's Codex
inference servers:

- The first 200 lines of `CLAUDE.md`, after redaction.
- The target (plan / diff / file / question), after redaction.
- The anti-sycophancy prompt template (no project data).

What stays local:

- The full `CLAUDE.md`, all rules files, all hooks.
- The full repo (sandbox is `read-only` AND `--cd "$PWD"`; Codex cannot
  exfiltrate files it was not handed in the prompt).
- Session rollout (`--ephemeral` skips local persistence). Server-side
  cache is also ephemeral per OpenAI Codex docs (no guarantee of
  session memory; not zero-retention).

What you can do once to harden the data path:

- **Redaction**: edit `.claude/redact-patterns.txt` (template at
  `.claude/redact-patterns.txt.example`) with project-specific
  patterns — internal hostnames, custom token formats, schema names.
  Universal patterns (cloud keys, DB DSNs, PEM, JWT, vendor-agnostic
  named-variable secrets, Telegram tokens) are already in the skill.
- **ChatGPT data setting**: in your ChatGPT account →
  Settings → Data Controls → "Improve the model for everyone: OFF".
  This disables training-on-your-data for Plus / Pro / Team.
  (Business / Enterprise / API are opt-out by default.)

## Pre-flight (one-time, per developer)

The user must already have:

- `codex` CLI installed (`make doctor` will report it)
- Logged in via `codex login` (their ChatGPT subscription) OR
  `CODEX_API_KEY` env var set

If `codex` is missing or not authenticated, surface the missing
piece and stop. Do NOT try to install or configure anything yourself.

## Workflow (this is what you, Claude, do)

### Step 1 — Resolve what to review

Pick the target based on the user's request or the current TDD state:

| Trigger | Target |
|---|---|
| `/second-opinion plan` or before Tier 1 implementation | `.tdd/current-plan.md` |
| `/second-opinion diff` or before final commit | `git diff HEAD` |
| `/second-opinion file <path>` | the file at `<path>` |
| `/second-opinion question "<text>"` | the literal text |
| Auto-fire before Tier 1 implementation | the relevant `.tdd/current-plan.md` section + the proposed code snippets if you have them |

### Step 2 — Build the prompt

Send the target + minimal context. **Include code snippets when you have them** — that is the highest-value input.

The prompt MUST tell Codex to be skeptical and honest, not agreeable. Use the template below verbatim (it's tuned for anti-sycophancy).

### Step 3 — Run the review

Execute via Bash:

```bash
# Resolve target. Examples below — pick one based on Step 1.

# Plan review:
target_text="$(cat .tdd/current-plan.md 2>/dev/null)"
target_kind="plan"

# OR diff review:
target_text="$(git diff HEAD 2>/dev/null)"
target_kind="diff"
[ -z "$target_text" ] && { echo "Nothing to review."; exit 0; }

# Diff filters. Skip cheaply before invoking Codex.
# Universal scope (any Tier) means we add 3 mechanical guards to keep
# review volume sensible:
#   1. skip_globs — paths never worth reviewing (docs, lockfiles, CI)
#   2. min_substantive_lines — whitespace / comment-only diffs skip
#   3. upper bound — diffs >2000 lines overwhelm the reviewer (per 2026
#      AI-review benchmarks; AI quality breaks down ~1000-2000 lines)
if [ "$target_kind" = "diff" ]; then
  # 1. Filter out files matching skip_globs. If nothing is left, skip.
  changed_files="$(git diff --name-only HEAD 2>/dev/null)"
  reviewable_files=()
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
      *.md|*.txt|CHANGELOG*|*/CHANGELOG*|README*|*/README*|LICENSE*|*/LICENSE*|.editorconfig|.gitignore|*/.gitignore|go.sum|*/go.sum|.github/*|*/.github/*|.gitlab-ci.yml)
        continue ;;
      *)
        reviewable_files+=("$f") ;;
    esac
  done <<< "$changed_files"

  if [ ${#reviewable_files[@]} -eq 0 ]; then
    echo "All changed files are in skip_globs (docs / lockfiles / CI); skipping second opinion."
    exit 0
  fi

  # Re-take the diff scoped to just the reviewable files.
  target_text="$(git diff HEAD -- "${reviewable_files[@]}" 2>/dev/null)"

  # 2. Total +/- lines.
  lines="$(printf '%s\n' "$target_text" | grep -cE '^[+-][^+-]' || true)"

  # 3. Substantive lines (drop blank-only and pure-comment +/- lines).
  substantive="$(printf '%s\n' "$target_text" | grep -E '^[+-][^+-]' | grep -vE '^[+-][[:space:]]*$|^[+-][[:space:]]*//|^[+-][[:space:]]*#' | wc -l | tr -d ' ')"

  [ "$lines" -lt 10 ]      && { echo "Diff too small ($lines lines); skipping second opinion."; exit 0; }
  [ "$lines" -gt 2000 ]    && { echo "Diff too large ($lines lines); split before reviewing (AI review quality drops above ~2000 lines)."; exit 0; }
  [ "$substantive" -lt 5 ] && { echo "Diff has only $substantive substantive lines (whitespace/comment-only); skipping."; exit 0; }
fi

# Redaction. Mirrors patterns from .claude/hooks/scan-for-secrets.sh plus
# universal credential-shape additions (DSN, vendor-agnostic named vars,
# Telegram, JWT, bearer). Multi-line PEM uses python3 if available; falls
# back to single-line awk match otherwise.
#
# Per-project patterns (internal hostnames, custom token formats, schema
# names) go in .claude/redact-patterns.txt — see
# .claude/redact-patterns.txt.example for the template.
#
# Trial-feedback hardening: load_redact_patterns() pre-filters the user file
# (drops comments + blanks) AND validates each remaining regex with
# grep -E before handing it to awk. Without this, a comment line like
# "# Universal patterns (cloud keys...)" with an unbalanced "(" was
# being parsed as regex and silently emptying the entire diff on
# bsd-awk (macOS default). Codex was then invoked with an empty
# TARGET and billed for nothing.

DEBUG_LOG="${SECOND_OPINION_DEBUG_LOG:-.tdd/second-opinion-debug.log}"
mkdir -p .tdd 2>/dev/null

load_redact_patterns() {
  # Read raw .claude/redact-patterns.txt; emit only non-comment,
  # non-blank, regex-validated lines into a mktemp file. Bad lines
  # are logged to DEBUG_LOG and skipped. Always returns 0 — a bad
  # patterns file never blocks the hook; the redactor falls back to
  # universal-only patterns.
  local raw="$1"
  [ -f "$raw" ] || return 0
  local validated; validated="$(mktemp 2>/dev/null || echo "/tmp/redact.$$")"
  local total=0 bad=0 rc=0
  while IFS= read -r p || [ -n "$p" ]; do
    # Skip blank lines and comments (allow leading whitespace).
    printf '%s\n' "$p" | grep -qE '^[[:space:]]*[^[:space:]#]' || continue
    total=$((total+1))
    # grep -E exits 0 (match) or 1 (no match) on valid regex; >=2 on
    # syntax error. Anything > 1 means the pattern is malformed.
    rc=0
    echo '' | grep -E -- "$p" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -le 1 ]; then
      printf '%s\n' "$p" >> "$validated"
    else
      bad=$((bad+1))
      printf '[redact-patterns] WARN: invalid regex skipped: %s\n' "$p" \
        >> "$DEBUG_LOG" 2>/dev/null || true
    fi
  done < "$raw"
  if [ "$bad" -gt 0 ]; then
    printf '[redact-patterns] %d/%d custom pattern(s) skipped as invalid; see %s.\n' \
      "$bad" "$total" "$DEBUG_LOG" >&2
  fi
  printf '%s\n' "$validated"
}

red_pem_multiline() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import sys, re
data = sys.stdin.read()
data = re.sub(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----",
              "[REDACTED-PEM-BLOCK]", data)
sys.stdout.write(data)
'
  else
    cat
  fi
}

red() {
  awk '
    BEGIN {
      patfile = ENVIRON["REDACT_FILE"]
      # Patterns are pre-validated by load_redact_patterns. Belt-and-
      # suspenders: still skip comment / blank lines here in case the
      # loader is bypassed or extended later.
      while (patfile != "" && (getline p < patfile) > 0) {
        if (p ~ /^[[:space:]]*$/) continue
        if (p ~ /^[[:space:]]*#/) continue
        pats[++n] = p
      }
      close(patfile)
    }
    {
      line = $0
      # Cloud-provider tokens
      gsub(/AKIA[0-9A-Z]{16}/, "[REDACTED]", line)
      gsub(/sk-[A-Za-z0-9]{32,}/, "[REDACTED]", line)
      gsub(/ghp_[A-Za-z0-9]{36}/, "[REDACTED]", line)
      gsub(/xox[abprs]-[A-Za-z0-9-]{10,}/, "[REDACTED]", line)
      gsub(/AIza[0-9A-Za-z_-]{35}/, "[REDACTED]", line)
      gsub(/sk-ant-[A-Za-z0-9_-]{40,}/, "[REDACTED]", line)
      # Single-line PEM (defense if multi-line scrub did not run)
      gsub(/-----BEGIN [A-Z ]*PRIVATE KEY-----[^-]*-----END [A-Z ]*PRIVATE KEY-----/, "[REDACTED-PEM]", line)
      # DSNs with embedded password (postgres / mysql / mongodb / redis / amqp / kafka)
      gsub(/(postgres(ql)?|mysql|mariadb|mongodb(\+srv)?|redis|amqps?|kafka):\/\/[^:[:space:]\/]+:[^@[:space:]\/]{4,}@[^[:space:]]*/, "[REDACTED-DSN]", line)
      # Vendor-agnostic named-variable rule: catches FOO_API_KEY=...,
      # MYCO_SECRET=..., ANY_PASSPHRASE=... regardless of vendor.
      gsub(/(^|[^A-Za-z0-9_])[A-Z][A-Z0-9_]{2,}_(SECRET|API_KEY|APIKEY|ACCESS_KEY|PRIVATE_KEY|PASSPHRASE|API_TOKEN|AUTH_TOKEN|REFRESH_TOKEN|API_SECRET)[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9+/=_.:-]{16,}["'"'"']?/, "[REDACTED-NAMED]", line)
      # Generic api_key= / password= (existing)
      gsub(/[Aa][Pp][Ii][_-]?[Kk][Ee][Yy][[:space:]]*[:=][[:space:]]*[A-Za-z0-9_.-]+/, "[REDACTED]", line)
      gsub(/[Pp]assword[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"'[:space:]]{6,}["'"'"']/, "[REDACTED]", line)
      # Telegram-shape bot tokens (NNN...:Abase64chars). Boundaries avoid
      # matching XML schema strings like clm12345:Foo.
      gsub(/(^|[^A-Za-z0-9_])[0-9]{5,16}:A[A-Za-z0-9_-]{34}([^A-Za-z0-9_-]|$)/, " [REDACTED-TG] ", line)
      # JWT (eyJ...eyJ...sig)
      gsub(/eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/, "[REDACTED-JWT]", line)
      # Inline bearer token
      gsub(/[Bb]earer[[:space:]]+[A-Za-z0-9._-]{20,}/, "Bearer [REDACTED]", line)
      # Project-specific extras from .claude/redact-patterns.txt (already
      # comment-filtered AND regex-validated by load_redact_patterns).
      for (i = 1; i <= n; i++) gsub(pats[i], "[REDACTED]", line)
      print line
    }'
}

# Pipeline: multi-line PEM scrub → line-oriented redaction.
red_full() { red_pem_multiline | red; }

# Build the validated patterns file (or empty if user has none).
REDACT_FILE="$(load_redact_patterns .claude/redact-patterns.txt)"
export REDACT_FILE

# Model selection.
# Default to the most powerful Codex model for both tiers. The repo's
# rationale (per user preference): never downgrade for cost or latency on
# code review — review quality dominates. The tier-aware variable kept
# below is for projects that want to opt-down to a cheaper model on
# non-Tier-1 paths; in that case set second_opinion.model_default in
# .tdd/tdd-config.json or export SECOND_OPINION_MODEL_DEFAULT.
#
# Resolution order (highest priority first):
#   1. Env var (SECOND_OPINION_MODEL_TIER1 / _DEFAULT / _FALLBACK)
#   2. Legacy single-knob env var SECOND_OPINION_MODEL (sets both tiers)
#   3. Per-project config: .tdd/tdd-config.json second_opinion.{...}
#   4. Hardcoded fallback in this file
#
# Note: gpt-5.5 requires ChatGPT-account auth via `codex login`. With
# API-key auth, run_codex falls back to fallback_model automatically.

cfg_tier1_model=""
cfg_default_model=""
cfg_fallback_model=""
if [ -f .tdd/tdd-config.json ] && command -v jq >/dev/null 2>&1; then
  cfg_tier1_model="$(jq -r '.second_opinion.model_tier1 // empty' .tdd/tdd-config.json 2>/dev/null)"
  cfg_default_model="$(jq -r '.second_opinion.model_default // empty' .tdd/tdd-config.json 2>/dev/null)"
  cfg_fallback_model="$(jq -r '.second_opinion.fallback_model // empty' .tdd/tdd-config.json 2>/dev/null)"
fi

tier1_model="${SECOND_OPINION_MODEL_TIER1:-${SECOND_OPINION_MODEL:-${cfg_tier1_model:-gpt-5.5}}}"
default_model="${SECOND_OPINION_MODEL_DEFAULT:-${SECOND_OPINION_MODEL:-${cfg_default_model:-gpt-5.5}}}"
fallback_model="${SECOND_OPINION_FALLBACK_MODEL:-${cfg_fallback_model:-gpt-5.4}}"

# Decide which model to use. Look at changed paths against the project's
# Tier 1 regexes (.tdd/tdd-config.json). If any matches, this is a Tier 1
# change and we use the deep model.
model="$default_model"
tier_label="non-Tier-1"
if [ -f .tdd/tdd-config.json ] && command -v jq >/dev/null 2>&1; then
  tier1_regexes="$(jq -r '.tier1_path_regexes[]? // empty' .tdd/tdd-config.json 2>/dev/null)"
  if [ -n "$tier1_regexes" ]; then
    # Use the same path source whether plan/diff/file mode.
    paths_to_check="${changed_files:-}"
    [ -z "$paths_to_check" ] && paths_to_check="$(git diff --name-only HEAD 2>/dev/null)"
    if [ -n "$paths_to_check" ]; then
      while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        if printf '%s\n' "$paths_to_check" | grep -qE "$pattern"; then
          model="$tier1_model"
          tier_label="Tier 1 (path matches /$pattern/)"
          break
        fi
      done <<< "$tier1_regexes"
    fi
  fi
fi

# Run redaction once and validate before invoking Codex. Without this
# guard, a malformed redact pattern or an over-broad regex can silently
# strip the diff to nothing — Codex is invoked with an empty TARGET,
# returns "no diff content provided", and the audit log records a
# "successful" review with zero findings. Both billing waste and audit
# corruption.
redacted_target="$(printf '%s' "$target_text" | red_full)"
target_len=${#target_text}
redacted_len=${#redacted_target}

# 50-byte minimum: a real plan/diff has at least a header line.
if [ "$redacted_len" -lt 50 ]; then
  echo "Redaction produced ${redacted_len} bytes from ${target_len} bytes input; skipping second opinion." >&2
  echo "Likely cause: malformed/over-broad pattern in .claude/redact-patterns.txt — see ${DEBUG_LOG}." >&2
  exit 0
fi

# Ratio check: any input >100 bytes should retain >10% post-redaction.
# Below that, a single overly broad pattern is probably eating everything.
if [ "$target_len" -gt 100 ]; then
  ratio_pct=$(( redacted_len * 100 / target_len ))
  if [ "$ratio_pct" -lt 10 ]; then
    echo "Redaction stripped ${ratio_pct}% of input (raw: ${target_len}B, redacted: ${redacted_len}B); skipping second opinion." >&2
    echo "Likely cause: over-broad pattern in .claude/redact-patterns.txt — see ${DEBUG_LOG}." >&2
    exit 0
  fi
fi

# v1.6.0 Pass A — blind independent design (Tier 1 only).
# Codex generates its OWN design before seeing Claude's plan. The
# resulting artifact (.tdd/codex/independent-design.md) is fed back as
# context for Pass B (the comparison review), so Codex's critique is
# anchored on its own thinking, not on Claude's framing.
#
# Skipped when: not Tier 1, killswitch SECOND_OPINION_PASS_A_DISABLE=1
# is set, target_kind != "plan" (only plans have the high-level problem
# statement Pass A needs), or .tdd/research-packet.md is missing (Pass A
# anchors against the same evidence the implementer consulted).
#
# Failure mode: Pass A is best-effort. If Codex returns nothing, the
# skill still proceeds with Pass B as a v1.5.x-style direct review.
mkdir -p .tdd/codex 2>/dev/null
pass_a_anchor=""
if [ "${tier_label#Tier 1}" != "$tier_label" ] \
   && [ "${SECOND_OPINION_PASS_A_DISABLE:-0}" != "1" ] \
   && [ "$target_kind" = "plan" ] \
   && [ -f .tdd/research-packet.md ]; then

  # Build a problem statement from the plan's high-level sections only —
  # NOT the implementation/approach/test-plan sections (those contain
  # Claude's solution; Pass A must not see them). Awk extracts named
  # sections; if extraction is too thin (<200 chars), we fall back to the
  # full plan with an explicit "ignore implementation sections" prefix.
  problem_extracted="$(printf '%s\n' "$redacted_target" | awk '
    BEGIN { in_target = 0 }
    /^## (Feature goal|Problem statement|Reproduction|Expected behavior|Actual behavior|Business\/domain invariants|Acceptance criteria|Non-goals|Risk register)/ {
      in_target = 1; print; next
    }
    /^## / { in_target = 0 }
    in_target { print }
  ')"
  if [ "${#problem_extracted}" -lt 200 ]; then
    problem_extracted="$(printf 'NOTE: section extraction was too thin; the full plan follows. IGNORE any sections labeled "Implementation", "Approach", "Design", "Minimum implementation", or "Test plan" — they contain the implementer'\''s solution. Generate YOUR design independently.\n\n%s\n' "$redacted_target")"
  fi

  redacted_packet="$(red_full < .tdd/research-packet.md)"

  pass_a_prompt="$(cat <<PASSAEOF
You are an external technical reviewer for a Go codebase.

TASK: generate your OWN independent design for the problem below. You
have NOT seen any proposed solution; there is none in this prompt. Your
output is a reference document — a later step will compare your design
to what the implementer actually proposed.

Be specific. Make decisions. Do not write "it depends" — pick what you
would actually ship.

PROBLEM (extracted from the plan's high-level sections):
$problem_extracted

RESEARCH PACKET (the evidence the implementer consulted):
$redacted_packet

OUTPUT — Markdown only, no JSON:

## Goals
<3 sentences>

## Approach
<3-5 sentences>

## Key decisions
<bullets, with reasoning per decision>

## Trade-offs
### Accepted
<bullets>
### Rejected
<bullets>

## Test strategy
<bullets, aligned with Go testing idioms>
PASSAEOF
  )"

  pass_a_response="$(timeout 120 codex exec \
    -m "$model" \
    -s read-only \
    -c approval_policy="never" \
    -c model_reasoning_effort="high" \
    --ephemeral \
    --cd "$PWD" \
    - <<<"$pass_a_prompt" 2>>"$DEBUG_LOG" || true)"

  if [ -n "$pass_a_response" ]; then
    {
      printf '# Independent design — Codex Pass A\n'
      printf 'date: %s\n' "$(date -u +%FT%TZ)"
      printf 'codex_model: %s\n\n' "$model"
      printf '%s\n' "$pass_a_response"
    } > .tdd/codex/independent-design.md
    pass_a_anchor="$(cat <<PASSBANCHOR

PRIOR INDEPENDENT DESIGN (your own — generated before seeing the implementer's plan):
$pass_a_response

Compare your independent design to the implementer's plan below. Where
do they diverge? Which divergences matter? Which divergences are
stylistic and don't matter? Findings should call out divergences that
matter; ignore stylistic ones.
PASSBANCHOR
    )"
  else
    echo "[second-opinion] Pass A returned no output; proceeding with single-pass review." >&2
  fi
fi

# v1.6.0 closure check (diff-review only): if a prior plan-review matrix
# exists, include it so Codex can verify each ACCEPTED finding from the
# plan was actually addressed in this diff. Catches the "accepted at
# plan, dropped during implementation" failure mode.
closure_check_block=""
if [ "$target_kind" = "diff" ] && [ -f .tdd/codex/disposition-matrix.md ]; then
  closure_check_block="$(cat <<CLOSUREEOF

PRIOR PLAN REVIEW DISPOSITION:
$(cat .tdd/codex/disposition-matrix.md)

CLOSURE CHECK: verify that each ACCEPTED finding in the prior matrix has
been addressed in this diff. For each row with Disposition = ACCEPT or
PARTIAL:
  - Was the spec change actually implemented?
  - If yes, locate the implementation in this diff (file:line).
  - If no, raise a P1 finding: "Plan-review finding F<N> was accepted
    but not implemented." Include the original concern text from the
    matrix.
CLOSUREEOF
  )"
fi

prompt="$(cat <<EOF
You are an external technical reviewer for a Go codebase. You are NOT the
implementer. Your value is honest disagreement, not agreement.

CALIBRATION (read first):
- Be skeptical. The author already convinced themselves. Your job is
  to find what they missed, not to validate.
- Do NOT pad with praise. Do NOT invent findings to seem thorough.
  Zero findings is acceptable when the work is genuinely solid.
- Severity:
    P0 = data loss, security breach, prod outage, irreversible state
         corruption if shipped as planned.
    P1 = high probability of real bug, missing test on a critical
         path, or design choice that needs rework within 1-2 cycles.
    P2 = quality / observability / maintainability concern that is
         real but does not threaten correctness.
    P3 = nit / taste / docs.
- If a finding could plausibly downgrade one tier, downgrade it.
  Only label P0 when you would stake your reputation on it.
- The implementer is competent. Do NOT lecture about Go basics. Assume
  Go idioms, table-driven tests, error wrapping unless contradicted.

CROSS-FILE CONSISTENCY (the class single-file review misses):
- Before declaring zero findings on a diff that adds a helper, type,
  envelope shape, callback signature, audit pattern, or lock pattern,
  check whether sibling packages or sibling tools already ship a similar
  shape. If the new code diverges from the established in-repo pattern
  — even when the new code is internally correct — flag the divergence:
    - P2 if the divergence affects observability, debuggability, or
      maintenance (callers do not depend on the inconsistency).
    - P1 if any caller branches on the inconsistent field (e.g.
      IsError, status code, error sentinel, returned outcome enum) —
      uniformity is the contract there, not optional.
- Look for: tool result envelopes, audit emit shapes, lock/sync
  patterns, error-wrapping vocabulary, test fixture shapes, retry
  budgets, log-level conventions, naming of similar concepts.
- This is the class of finding that single-file review misses: the new
  code looks correct on its own; the gap is "every other implementer
  in this repo reaches for shape X, this reaches for shape Y."

ANTI-SYCOPHANCY:
- Do not mirror the author's vocabulary back. Use your own framing.
- If the work is good, say so in one sentence and stop.
- If you disagree with a stated assumption, say so explicitly with
  evidence (file path, line, observed behavior).

CODEBASE GREP (added v1.6.0): you have read-only access to the rest of
the codebase via standard Unix tools (grep, find, cat). Before writing
your final review:
  1. Identify the public surface this plan/diff newly depends on
     (interfaces newly implemented, public functions newly called from
     outside the change's files, new map keys / metadata fields).
  2. For each, grep the codebase for cross-file consistency:
     - Are all writers and readers of any new map key / metadata field
       using the same string literal? (Catches camelCase vs snake_case
       mismatches.)
     - Does the new code's API match what existing call sites expect?
     - Are there sanctioned-wrapper invariants the new code assumes
       ("only X may call Y")? If so, grep for direct Y calls outside X.
  3. Findings from this audit get severity P0 or P1 if they would
     silently fail in production. Tag location: file:line.

OUTPUT — JSON only, no prose around it:
{
  "summary": "one sentence, max 280 chars",
  "findings": [
    {
      "id": "F1",
      "severity": "P0|P1|P2|P3",
      "category": "correctness|security|concurrency|tests|api|migration|other",
      "title": "short title",
      "evidence": "what specifically is wrong / risky, with location if known",
      "recommendation": "the smallest concrete fix",
      "location": "optional path:line"
    }
  ]
}

PROJECT CONTEXT (first 200 lines of CLAUDE.md, redacted):
$(head -n 200 CLAUDE.md 2>/dev/null | red_full)

CHANGE SCOPE: $tier_label
TARGET UNDER REVIEW (kind: $target_kind):
$redacted_target
$pass_a_anchor
$closure_check_block
EOF
)"

# Read-only sandbox. approval_policy=never. Hard timeout.
# Streams progress to stderr; final assistant message goes to stdout.
# Stderr captured to a debug log (gitignored), so failures are diagnosable
# without polluting the chat. Cat .second-opinion-debug.log when something
# fails to see what Codex actually said.
mkdir -p .tdd 2>/dev/null
DEBUG_LOG="${SECOND_OPINION_DEBUG_LOG:-.tdd/second-opinion-debug.log}"

run_codex() {
  local m="$1"
  timeout 120 codex exec \
    -m "$m" \
    -s read-only \
    -c approval_policy="never" \
    -c model_reasoning_effort="high" \
    --ephemeral \
    --cd "$PWD" \
    - <<<"$prompt" 2>>"$DEBUG_LOG"
}

response="$(run_codex "$model" || true)"

# If primary model returned nothing AND a different fallback is configured,
# try fallback. Common cause: gpt-5.5 selected with API-key auth (not
# available), or model rate-limited.
if [ -z "$response" ] && [ "$fallback_model" != "$model" ]; then
  printf 'Codex returned no output with %s; retrying with %s.\n' "$model" "$fallback_model" >&2
  response="$(run_codex "$fallback_model" || true)"
  used_model="$fallback_model"
else
  used_model="$model"
fi

if [ -z "$response" ]; then
  echo "Codex returned no output (timeout, network, or auth issue)."
  echo "Skipping second opinion. Diagnostic log: $DEBUG_LOG"
  exit 0
fi

printf '## Second opinion (scope: %s, model: %s)\n\n' "$tier_label" "$used_model"
printf '%s\n' "$response"

# v1.6.0: persist the parsed JSON to .tdd/codex/round1.json so the
# require-second-opinion.sh hook can validate row count against
# disposition-matrix.md (when require_disposition_matrix_tier1 is true).
# Best-effort: if response is not valid JSON, skip silently.
if printf '%s' "$response" | jq -e . >/dev/null 2>&1; then
  printf '%s\n' "$response" > .tdd/codex/round1.json
fi
```

### Step 4 — Read the response and decide

The response is JSON. Parse it. For each finding:

1. Read evidence + recommendation honestly.
2. Decide: **accept**, **partial**, or **pushback**.
3. Severity-specific rationale rules (mechanically checked when possible):
   - **P0 accept**: MUST include the literal phrase `Why this is correct:`
     followed by 3+ sentences explaining the underlying technical claim.
     The phrase is a discipline marker — it forces you to articulate
     "why" instead of silently deferring.
   - **PARTIAL stance at any severity** (most-abused slot — see below):
     MUST include all three sub-sections, each with substantive content:
     ```
     What I am accepting: <concrete change you are making>
     What I am rejecting: <concrete claim you disagree with — NOT "nothing"/"n/a"/"none">
     Why this split is correct: <≥2 sentences explaining the partition>
     ```
   - **P0 reject**: write at least 3 sentences of rationale.
   - **P1**: at least 2 sentences if not plain accept.
   - **P2**: 1 sentence is enough; silent accept OK.
   - **P3**: optional rationale.

   PARTIAL is the load-bearing case because two failure modes hide there:
   - **Sycophancy theatre**: accepting 100% of the finding while labeling
     PARTIAL to look more independent.
   - **Deference theatre**: rejecting 100% of the finding while labeling
     PARTIAL to look polite.

   If you cannot fill all three sub-sections with substantive content,
   you do not have a PARTIAL — you have an ACCEPT or a PUSHBACK. Choose
   the honest label. The `require-second-opinion.sh` hook scans the
   adjudication artifact (Step 6) and denies the next code-changing
   tool call if any PARTIAL entry has an empty `What I am rejecting:`
   field (`nothing`, `n/a`, `none`, `-`, blank).

4. **Anti-deference rules:**
   - "External reviewer flagged X" is NEVER the reason. The reason
     is the underlying technical claim.
   - It is acceptable to reject a P0 if the evidence is wrong. Write
     why.
   - It is unacceptable to silently accept P0 without thinking. Say
     what you are changing and why.
   - Do not change a plan or piece of code SOLELY because the reviewer
     said so. Change it because the argument is correct.

### Step 5 — Surface to the user, then continue automatically

Show in chat:

- The original findings (compact, one bullet per finding).
- Your stance and rationale per finding (with the `Why this is correct:`
  marker on any accepted P0).
- The proposed plan/code update if any findings led you to change
  something.

Then continue based on Tier:

- **Non-Tier-1 work**: proceed to implementation directly. No new gate,
  no manual step. The whole second-opinion loop is automatic.
- **Tier 1 work**: the existing TDD ceremony spec gate fires next (it
  always fires for Tier 1, with or without Codex). Wait for the
  operator to reply `APPROVED` — same gate that existed before Codex
  was added. The Codex review just gives the operator more to read
  at that gate.

This skill **adds zero new manual steps**. The only operator inputs
are the same TDD `APPROVED` gates you already had for Tier 1.

### Step 6 — Write the adjudication artifacts (REQUIRED)

After Step 5, write TWO artifact files for v1.6.0 (Tier 1) or one for
non-Tier-1. The `require-second-opinion.sh` PreToolUse hook checks
these before allowing any subsequent Edit / Write / MultiEdit /
mutating-Bash call. Without them, the next code-changing tool call
will be **denied with exit 2**.

#### 6a. Adjudication artifact (always required)

```bash
mkdir -p .tdd
cat > .tdd/second-opinion-completed.md <<EOF
# Second opinion adjudication
date: $(date -u +%FT%TZ)
scope: <Tier 1 or non-Tier-1, copy the value from the chat header you printed>
model: <the model name from the chat header>
files_in_scope:
$(printf '  - %s\n' "$@")
findings_total: <N>
adjudication_summary: |
  <one paragraph summarizing your stance — accepts vs rejects vs
   pushbacks, what changed in the plan/code as a result>
findings:
  # One block per finding. Required keys: id, severity, stance.
  # PARTIAL stance ALSO requires: accepted, rejected, why_split (each
  # substantive — "nothing"/"n/a"/"none"/blank are rejected by the hook).
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
EOF
```

#### 6b. Disposition matrix (Tier 1 only — v1.6.0)

For Tier 1 cycles, ALSO write `.tdd/codex/disposition-matrix.md` with
one row per Codex finding. The hook checks row count == findings_total.

```bash
mkdir -p .tdd/codex
cat > .tdd/codex/disposition-matrix.md <<EOF
# Concern Disposition Matrix
date: $(date -u +%FT%TZ)
cycle_id: <slug>
findings_total: <N — must equal row count below>
codex_model: <model name>
review_phase: <plan|diff>

## Cross-cutting observations

<0-3 sentences. Empty if no cross-cutting pattern across findings.
Examples:
- "Three findings (F2, F5, F7) point at error handling. Single style
  change in cycle scope addresses all three."
- "No cross-cutting patterns."
This is the v1.6.0 patterns pre-pass — surface global observations
BEFORE the per-finding loop.>

## Findings table

| ID | Source | Severity | Concern (1 line) | Disposition | Reason | Spec change |
|----|--------|----------|------------------|-------------|--------|-------------|
| F1 | Codex  | <P0..P3> | <one line>       | <ACCEPT|PARTIAL|REJECT|PUSHBACK> | <discipline-compliant reason — see template> | <yes|partial|no> |
<one row per Codex finding from round1.json>

## Pass A divergences

<Tier 1 with Pass A only. List major divergences between Codex's
independent design (.tdd/codex/independent-design.md) and Claude's
plan, with Claude's stance on each. Mark addressed-by F-ID or
"stylistic, overridden".>
EOF
```

Discipline rules for the matrix:
- **P0 ACCEPT**: "Reason" column must include `Why this is correct:`
  followed by ≥3 sentences.
- **PARTIAL (any severity)**: "Reason" column must include all three
  sub-sections inline:
  ```
  What I am accepting: <concrete change>
  What I am rejecting: <concrete claim — NOT nothing/n/a/none/blank>
  Why this split is correct: <≥2 sentences>
  ```
- **REJECT, PUSHBACK, P1+ ACCEPT**: ≥1 sentence concrete reason
  grounded in the underlying technical claim.

The hook validates row count == findings_total and applies the existing
PARTIAL discipline check to the matrix's "Reason" column.

The hook treats this file as valid for **60 minutes** from its mtime.
After that window the hook treats it as stale and re-blocks. This is
deliberate — adjudications should be tied to the work you just
reviewed, not reused on a different change tomorrow.

### Step 7 — Do NOT auto-edit code based on the review

The skill is advisory. You may UPDATE A PLAN based on accepted
findings. You may not silently EDIT PRODUCTION CODE based on
findings without going through the normal user-approval flow.

### When you skipped the skill (no adjudication needed)

If the skill exited early (all changed files in skip_globs, diff too
small, codex not installed, `SECOND_OPINION_DISABLE=1`), you do NOT
write the adjudication file. The hook also skips for those cases —
both the skill's filters and the hook's `is_always_allowed_path`
function mirror the same skip list, so the hook will pass-through
when the skill would skip.

## Anti-deference quick check

Before you accept any finding, ask yourself: "Would I make this
change if a coworker emailed it to me, with no 'reviewer' framing?"
If the answer is yes, accept. If the answer is "well, I guess if
they're sure...", that's deference. Reject and explain why.

## Constraints (hard)

- Read-only sandbox is hard-coded (`-s read-only`). Never pass
  `workspace-write` or `--full-auto`.
- Single-pass review. No Round 2 debate, no chained re-runs. If the
  user wants more, they invoke again with refined input.
- `--ephemeral` keeps no session state on disk. Clean.
- Timeout is 120 seconds. If Codex is slow today, the skill skips,
  not blocks.
- Failures are silent and non-blocking. The user is told once
  ("Codex returned no output") and the skill exits 0.

## What this skill is NOT

- Not a CI gate. Failing Codex's tastes does not block anything.
- Not a hook (auto-fire on every tool call would be wrong; it would
  burn budget for noise and add procedural weight to every TDD
  ceremony). This skill is invoked when valuable, by you or the user.
- Not multi-round debate. One review, one decision tree, done.
- Not authoritative. Codex catches things, Codex also misses things
  and invents things. Treat as peer review.

## When to skip

- The change is a typo / formatting / single-line bugfix.
- The user has explicit APPROVED on a Tier 1 spec and you are
  mid-implementation (spec gate already validated).
- The user said `/second-opinion off` or `skip second opinion`.
- `codex` is not installed or not authenticated (`make doctor`
  reports the gap).
- `SECOND_OPINION_DISABLE=1` env var is set.

## Override knobs

Two layers: env vars (per-invocation) and project config (per-repo).

### Per-invocation env vars

| Env var | Effect |
|---|---|
| `SECOND_OPINION_MODEL` | Legacy single-knob; pins both tiers to one model. |
| `SECOND_OPINION_MODEL_TIER1` | Pin Tier 1 model (default: `gpt-5.5`; needs ChatGPT auth). |
| `SECOND_OPINION_MODEL_DEFAULT` | Pin non-Tier-1 model (default: `gpt-5.5`; opt down to `gpt-5.4-mini` if you want cheap reviews on trivial paths). |
| `SECOND_OPINION_FALLBACK_MODEL` | Used if the primary returns nothing (default: `gpt-5.4`; works with API-key auth). |
| `SECOND_OPINION_DISABLE=1` | Skill exits 0 silently. |

### Per-project config (`.tdd/tdd-config.json`)

```json
"second_opinion": {
  "model_tier1": "gpt-5.5",
  "model_default": "gpt-5.5",
  "fallback_model": "gpt-5.4"
}
```

Resolution order (highest priority first): env var → legacy single-knob
env var → config field → hardcoded fallback. Edit the config when you
want a project-wide default that survives across operator shells.

The defaults pin the most powerful model for both tiers — never downgrade
for cost or latency on code review. To opt down on trivial paths (e.g.,
docs-heavy projects where universal-scope reviews would be pure
overhead), set `model_default` to a cheaper model in the config.
