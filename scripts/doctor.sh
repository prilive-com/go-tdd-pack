#!/usr/bin/env bash
# Verify required and recommended local tools are installed.
# Required tools are non-negotiable: hooks fail closed without them.
# Recommended tools enable full enforcement (lint, vuln scan, secret scan).

set -uo pipefail

REQUIRED=(go bash jq git)
RECOMMENDED=(gopls goimports staticcheck govulncheck golangci-lint gitleaks deadcode)

missing_required=0
missing_recommended=0

ok()    { printf "  \033[32mOK  \033[0m %s\n" "$1"; }
miss()  { printf "  \033[31mMISS\033[0m %s\n" "$1"; }
warn()  { printf "  \033[33mWARN\033[0m %s\n" "$1"; }

echo "Required tools (hooks fail closed without these):"
for t in "${REQUIRED[@]}"; do
  if command -v "$t" >/dev/null 2>&1; then
    ok "$t"
  else
    miss "$t"
    missing_required=$((missing_required + 1))
  fi
done

echo
echo "Recommended tools (full enforcement and quality checks):"
for t in "${RECOMMENDED[@]}"; do
  if command -v "$t" >/dev/null 2>&1; then
    ok "$t"
  else
    warn "$t"
    missing_recommended=$((missing_recommended + 1))
  fi
done

echo
echo "Optional: Codex CLI (for /second-opinion skill — fully optional):"
if command -v codex >/dev/null 2>&1; then
  ok "codex (run /second-opinion in a Claude Code session to use)"
  # Auth check
  if [[ -z "${CODEX_API_KEY:-}" && -z "${OPENAI_API_KEY:-}" ]]; then
    if ! codex login status >/dev/null 2>&1; then
      warn "codex installed but not logged in (run 'codex login' or set CODEX_API_KEY)"
    fi
  fi
  # Auth-mode / model-default mismatch warning. gpt-5.5 (the skill default)
  # requires ChatGPT-account auth; with API-key auth only, the skill will
  # silently fall back to gpt-5.4 — which works but the user should know.
  if [[ -n "${OPENAI_API_KEY:-}" || -n "${CODEX_API_KEY:-}" ]] \
     && ! codex login status >/dev/null 2>&1 \
     && [[ "${SECOND_OPINION_MODEL:-gpt-5.5}" == gpt-5.5* ]]; then
    warn "API-key auth + default model gpt-5.5: gpt-5.5 needs 'codex login' (ChatGPT). The skill will fall back to gpt-5.4."
    warn "  To silence: 'codex login', OR set SECOND_OPINION_MODEL=gpt-5.4 (or gpt-5.3-codex) in your env."
  fi
else
  warn "codex (optional; install if you want cross-model second opinions)"
fi

echo
if [[ "$missing_required" -gt 0 ]]; then
  echo "ERROR: $missing_required required tool(s) missing." >&2
  echo "Install hints:" >&2
  echo "  jq:      apt-get install jq / brew install jq / apk add jq" >&2
  echo "  go:      https://go.dev/dl/" >&2
  exit 1
fi

if [[ "$missing_recommended" -gt 0 ]]; then
  echo "$missing_recommended recommended tool(s) missing. Run 'make tools' to install."
  exit 0
fi

echo "All tools installed."
