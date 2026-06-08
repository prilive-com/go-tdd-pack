#!/usr/bin/env bash
# scripts/review/proposal-review.sh — Codex adversarial review of a
# design proposal.
#
# The v2.3 proposal cycle taught us: a second-model adversarial pass
# on PROPOSAL-*.md docs catches BLOCKER-level design flaws the author
# missed. Three proposals reviewed in 2026-06-08 surfaced 8 BLOCKERs
# total (Option B in the safer-execution proposal isn't actually a
# sandbox; the FDTDD Stage 1 Gate 1 unlocks the wrong scope; etc.).
# This script encodes the recipe so the discipline is one command,
# not "remember how I did it last time".
#
# Gotchas this script handles for you:
#   - `-m gpt-5.5` to avoid v2.1.0 Bug 2 (Codex CLI 0.130+ defaults
#     to gpt-5.3-codex which is paid-only; the tdd-pack.toml pin
#     does NOT apply to direct codex calls).
#   - `--ignore-user-config` to avoid openai/codex#15451 (MCP
#     servers can silently drop output structure).
#   - `model_reasoning_effort=high` so the reviewer actually thinks.
#   - Output to `.tdd/review/proposal-review-<name>-<sha>.txt` for
#     audit trail (same convention as the postmortem A1 pre-tag-
#     smoke artifact).
#
# Usage:
#   bash scripts/review/proposal-review.sh docs/PROPOSAL-foo.md
#
# Output:
#   .tdd/review/proposal-review-<basename>-<sha>.txt
#
# Exit codes:
#   0 — review ran (regardless of severity of findings; READ them).
#   1 — usage error / proposal not found / codex unavailable.
#   2 — codex returned non-zero (auth, model, network).

set -uo pipefail

PROPOSAL="${1:-}"
if [[ -z "${PROPOSAL}" ]]; then
  echo "usage: bash scripts/review/proposal-review.sh <path-to-proposal.md>" >&2
  echo "" >&2
  echo "Example: bash scripts/review/proposal-review.sh docs/PROPOSAL-foo.md" >&2
  exit 1
fi

if [[ ! -f "${PROPOSAL}" ]]; then
  echo "error: proposal not found: ${PROPOSAL}" >&2
  exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROMPT_FILE="${PROJECT_ROOT}/prompts/proposal-critique.md"
if [[ ! -f "${PROMPT_FILE}" ]]; then
  echo "error: critique prompt missing at ${PROMPT_FILE}" >&2
  exit 1
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "error: codex CLI not on PATH. Install per docs/ADOPTION_GUIDE.md." >&2
  exit 1
fi

# Audit trail location
mkdir -p "${PROJECT_ROOT}/.tdd/review"
NAME="$(basename "${PROPOSAL}" .md)"
SHA="$(cd "${PROJECT_ROOT}" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
OUTPUT="${PROJECT_ROOT}/.tdd/review/proposal-review-${NAME}-${SHA}.txt"

echo "▶ Codex adversarial review of: ${PROPOSAL}"
echo "  prompt:    prompts/proposal-critique.md"
echo "  model:     gpt-5.5 (pinned; avoids v2.1.0 Bug 2)"
echo "  reasoning: high"
echo "  output:    ${OUTPUT#${PROJECT_ROOT}/}"
echo "  (this typically takes 2-5 minutes)"
echo ""

# Build the input: critique prompt + proposal contents
INPUT=$(cat "${PROMPT_FILE}" "${PROPOSAL}")

if printf '%s' "${INPUT}" | codex exec \
     -m gpt-5.5 \
     --ignore-user-config \
     -c model_reasoning_effort="high" \
     - > "${OUTPUT}" 2>&1; then
  RC=0
else
  RC=$?
fi

# Surface the codex response section (between "codex" header and
# "tokens used" footer) for easy reading.
echo "▶ Findings (between markers):"
echo "----------------------------------------------------------------"
awk '/^codex$/{f=1; next} /^tokens used$/{f=0} f' "${OUTPUT}"
echo "----------------------------------------------------------------"
echo ""
echo "Full audit artifact: ${OUTPUT#${PROJECT_ROOT}/}"

if [[ ${RC} -ne 0 ]]; then
  echo ""
  echo "✗ codex exit ${RC}. Common causes:" >&2
  echo "  - 'gpt-5.X model not supported on ChatGPT account' → upstream changed model availability; update -m flag." >&2
  echo "  - 'auth required' / HTTP 401 → run 'codex login'." >&2
  echo "  - empty output → check the audit artifact for the raw error." >&2
  exit 2
fi

exit 0
