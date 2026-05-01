---
name: second-opinion
description: |
  Get a cross-model second opinion on a plan or code change before
  implementing it. Calls OpenAI Codex CLI (read-only) to review the
  current plan, the current diff, or a specific snippet. Returns
  honest findings — not blocking, advisory only. Use this BEFORE
  implementing non-trivial changes, especially on Tier 1 paths
  (money, auth, migrations, anything matching .tdd/tdd-config.json
  tier1_path_regexes), or when the user says "second opinion",
  "ask codex", "what would another model think", or "/second-opinion".
when_to_use: |
  Auto-invoke before:
    - Implementing any Tier 1 plan that involves >50 lines or
      cross-package logic.
    - Fixing a Tier 1 bug whose root cause you are not 100% sure of.
    - Any architecture / API design decision the user explicitly
      asks you to think hard about.
  Manually invoke when the user says:
    - "second opinion" / "ask codex" / "what would another model say"
    - "/second-opinion plan" / "/second-opinion diff" / "/second-opinion file <path>"
  Skip when:
    - The change is a typo, doc-only, formatting, or single-line bugfix.
    - You already have explicit user APPROVED on a Tier 1 plan and
      are mid-implementation (the spec gate already cleared it).
    - The user said "skip second opinion" or "/second-opinion off".
license: MIT
version: 1.0.0
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

# Diff size guards (skip if too small or too large):
if [ "$target_kind" = "diff" ]; then
  lines="$(printf '%s\n' "$target_text" | grep -cE '^[+-][^+-]' || true)"
  [ "$lines" -lt 10 ]   && { echo "Diff too small ($lines lines); skipping second opinion."; exit 0; }
  [ "$lines" -gt 4000 ] && { echo "Diff too large ($lines lines); split before reviewing."; exit 0; }
fi

# Redaction. Mirrors patterns from .claude/hooks/scan-for-secrets.sh plus
# universal credential-shape additions (DSN, vendor-agnostic named vars,
# Telegram, JWT, bearer). Multi-line PEM uses python3 if available; falls
# back to single-line awk match otherwise.
#
# Per-project patterns (internal hostnames, custom token formats, schema
# names) go in .claude/redact-patterns.txt — see
# .claude/redact-patterns.txt.example for the template.

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
      while (patfile != "" && (getline p < patfile) > 0) pats[++n] = p
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
      # Project-specific extras from .claude/redact-patterns.txt
      for (i = 1; i <= n; i++) gsub(pats[i], "[REDACTED]", line)
      print line
    }'
}

# Pipeline: multi-line PEM scrub → line-oriented redaction.
red_full() { red_pem_multiline | red; }

REDACT_FILE=".claude/redact-patterns.txt"
[ ! -f "$REDACT_FILE" ] && REDACT_FILE=""
export REDACT_FILE

# Default to the newest Codex model. Override with SECOND_OPINION_MODEL.
# - gpt-5.5: newest frontier; ChatGPT auth only (NOT API key).
# - gpt-5.4: flagship; works with both auth modes.
# - gpt-5.3-codex: most capable agentic coding model.
# If the primary model fails (unavailable / auth mismatch), the skill
# retries once with SECOND_OPINION_FALLBACK_MODEL (default gpt-5.4).
model="${SECOND_OPINION_MODEL:-gpt-5.5}"
fallback_model="${SECOND_OPINION_FALLBACK_MODEL:-gpt-5.4}"

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

ANTI-SYCOPHANCY:
- Do not mirror the author's vocabulary back. Use your own framing.
- If the work is good, say so in one sentence and stop.
- If you disagree with a stated assumption, say so explicitly with
  evidence (file path, line, observed behavior).

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

TARGET UNDER REVIEW (kind: $target_kind):
$(printf '%s' "$target_text" | red_full)
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

printf '## Second opinion (model: %s)\n\n' "$used_model"
printf '%s\n' "$response"
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
   - **P0 reject / partial**: write at least 3 sentences of rationale.
   - **P1**: at least 2 sentences if not plain accept.
   - **P2**: 1 sentence is enough; silent accept OK.
   - **P3**: optional rationale.

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

### Step 6 — Do NOT auto-edit code based on the review

The skill is advisory. You may UPDATE A PLAN based on accepted
findings. You may not silently EDIT PRODUCTION CODE based on
findings without going through the normal user-approval flow.

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

| Env var | Effect |
|---|---|
| `SECOND_OPINION_MODEL` | Pin to a specific Codex model (default: `gpt-5.5`). Examples: `gpt-5.4`, `gpt-5.3-codex`. |
| `SECOND_OPINION_DISABLE=1` | Skill exits 0 silently. |

That's the entire surface. Two env vars, no config file, no JSON
schema, no Round 2, no eval harness. If after a few weeks of real
use you find yourself wishing it auto-fired, see MAINTAINING.md
"Second-opinion skill design choices" for the rationale.
