#!/usr/bin/env bash
# UserPromptSubmit hook: route implementation/bugfix prompts toward
# go-tdd-* skills when the prompt looks code-flavored AND mentions
# Tier 1 keywords (per .tdd/tdd-config.json). Advisory only — never blocks.

set -euo pipefail

PAYLOAD="$(cat)"
PROMPT="$(printf '%s' "$PAYLOAD" | jq -r '.prompt // empty' 2>/dev/null || echo '')"
[[ -z "$PROMPT" ]] && exit 0

PROMPT_LC="$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')"

INTENT_RE='\b(implement|implementing|add|adding|build|building|create|creating|fix|fixing|refactor|refactoring|change|update|debug|investigate|resolve)\b'
printf '%s' "$PROMPT_LC" | grep -qE "$INTENT_RE" || exit 0

SUPPRESS_RE='\b(typo|changelog|readme|claude\.md|review\.md|comment|docstring|markdown|doc only|just docs|update the docs|fix the docs|documentation|review|analyze|explain|summarize)\b'
printf '%s' "$PROMPT_LC" | grep -qE "$SUPPRESS_RE" && exit 0

QUESTION_RE='^(what|why|how|when|where|who|can you|could you|should we|is it|are there|tell me|show me|list)'
printf '%s' "$PROMPT_LC" | grep -qE "$QUESTION_RE" && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CONFIG="$PROJECT_DIR/.tdd/tdd-config.json"
KEYWORDS=""
if [[ -f "$CONFIG" ]] && command -v jq >/dev/null 2>&1; then
  KEYWORDS="$(jq -r '.tier1_prompt_keywords[]? // empty' "$CONFIG" | paste -sd '|' -)"
fi

KIND="feature"
if printf '%s' "$PROMPT_LC" | grep -qE '\b(fix|bug|regression|incorrect|wrong|broken|crash|panic|leak|race|deadlock|debug|resolve)\b'; then
  KIND="bugfix"
fi

if [[ -n "$KEYWORDS" ]] && printf '%s' "$PROMPT_LC" | grep -qE "\b($KEYWORDS)\b"; then
  cat <<ROUTER_MSG
[TDD router]

This looks like a $KIND request that may touch Tier 1 high-stakes code.
Use the /go-tdd-$KIND skill if production code is affected.

Required Tier 1 cadence:
  spec -> APPROVED -> failing test/red proof -> APPROVED -> implementation -> green -> AI-bloat review

The PreToolUse hook blocks Tier 1 production edits until .tdd/current-plan.md has:
  Human approved spec: yes
  Red phase confirmed: yes
  Green phase authorized: yes
(Commit also requires: Implementation reviewed: yes — set after the post-impl review.)

Ignore this notice for: docs, questions, test-only work, or explicitly low-risk changes.
ROUTER_MSG
fi

exit 0
