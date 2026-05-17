#!/usr/bin/env bash
# runner/tool-grounding.sh <project_dir>
#
# Pre-execute static analysis tools and emit a markdown block summarizing
# their output. The runner includes this block in Codex's round-1 user
# prompt so the reviewer has tool-grounded evidence (not just the diff
# and its own reasoning) when forming findings.
#
# Why: deterministic tools catch concrete bugs (vet vetters, races,
# unused vars, lint nits) with high recall and zero false confidence.
# Letting Codex see their output saves it from re-deriving the same
# signal — and prevents disagreement between Codex's guesses and what
# the tools actually report.
#
# Behavior:
#   - Skips silently if no go.mod (project is not Go).
#   - For each tool: skips silently if not installed. Caps output at
#     4000 chars per tool. Times out at 60s per tool.
#   - Always returns 0. Tool failures appear in the output as "(error)"
#     rather than aborting the runner.
#
# Output: markdown to stdout. Always at least the "## Tool grounding"
# header, even if everything was skipped.

set -uo pipefail

PROJECT_DIR="${1:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
PER_TOOL_TIMEOUT_S="${TOOL_GROUNDING_TIMEOUT_S:-60}"
PER_TOOL_CHAR_CAP="${TOOL_GROUNDING_CHAR_CAP:-4000}"

cd "${PROJECT_DIR}" 2>/dev/null || exit 0

echo "## Tool grounding (pre-executed before this review)"
echo ""

# Skip entirely if not a Go project.
if [[ ! -f "go.mod" ]]; then
  echo "(no go.mod found; tool grounding skipped — not a Go project)"
  exit 0
fi

# --- helper: run a tool, format its output ---
run_tool() {
  local label="$1"; shift
  local bin="$1"; shift

  echo "### ${label}"

  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "(skipped: ${bin} not installed)"
    echo ""
    return 0
  fi

  local out
  if ! out=$(timeout "${PER_TOOL_TIMEOUT_S}" "${bin}" "$@" 2>&1); then
    local rc=$?
    if [[ "${rc}" == "124" ]]; then
      echo "(timed out after ${PER_TOOL_TIMEOUT_S}s)"
      echo ""
      return 0
    fi
    # Non-zero exit usually means the tool found issues; print the output.
    # If output is empty, surface the exit code.
    if [[ -z "${out}" ]]; then
      echo "(exited ${rc} with no output)"
      echo ""
      return 0
    fi
  fi

  if [[ -z "${out}" ]]; then
    echo "(clean)"
    echo ""
    return 0
  fi

  # Cap output. Use head -c to truncate by bytes; append truncation marker.
  local capped
  capped=$(printf '%s' "${out}" | head -c "${PER_TOOL_CHAR_CAP}")
  echo '```'
  printf '%s\n' "${capped}"
  if [[ "${#out}" -gt "${PER_TOOL_CHAR_CAP}" ]]; then
    echo ""
    echo "(... truncated; full output was ${#out} chars)"
  fi
  echo '```'
  echo ""
}

# Order matters: cheapest first so the user-facing output starts with
# the fast tools' results even if a slow one ends up timing out.

run_tool "gofmt -l ./..." gofmt -l .
run_tool "go vet ./..." go vet ./...
run_tool "staticcheck ./..." staticcheck ./...
run_tool "golangci-lint run" golangci-lint run --timeout=50s ./...
run_tool "govulncheck ./..." govulncheck ./...

exit 0
