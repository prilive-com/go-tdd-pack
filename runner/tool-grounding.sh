#!/usr/bin/env bash
# runner/tool-grounding.sh <project_dir>
#
# Pre-execute static analysis tools and emit a markdown block summarizing
# their output, grouped by affected Go module. The runner includes this
# block in Codex's round-1 user prompt so the reviewer has tool-grounded
# evidence (not just the diff and its own reasoning) when forming findings.
#
# UNIVERSAL DESIGN: works for single-module repos, monorepos with multiple
# go.mod files at different depths, polyglot repos, and repos with no Go
# code at all. Discovery is driven by the diff, not by where the script
# happens to be invoked from.
#
# Algorithm:
#   1. Collect changed files (git diff HEAD + untracked).
#   2. Filter via module-affecting predicate (.go, go.mod, go.sum, go.work,
#      .golangci.yml; exclude vendor/, testdata/, .git/, node_modules/).
#   3. For each surviving file, walk up to nearest non-empty go.mod.
#      Empty go.mod is the Grab "exclude this subtree" pattern.
#   4. Dedupe → set of affected module directories.
#   5. For each module: cd in, run each tool, emit a section.
#   6. Hard total cap: 30000 chars. Truncate cleanly with explicit notice.
#   7. NEVER silently skip — always emit a status section so Codex knows
#      what the script did and did not analyze.
#
# Per-tool: 60s timeout, output capped at 4000 chars, skipped silently if
# not installed. Always returns 0.

set -uo pipefail

PROJECT_DIR="${1:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
PER_TOOL_TIMEOUT_S="${TOOL_GROUNDING_TIMEOUT_S:-60}"
PER_TOOL_CHAR_CAP="${TOOL_GROUNDING_CHAR_CAP:-4000}"
TOTAL_CHAR_CAP="${TOOL_GROUNDING_TOTAL_CAP:-30000}"

cd "${PROJECT_DIR}" 2>/dev/null || exit 0

# Buffer output to a tmpfile so we can enforce a clean total-size cap.
OUT=$(mktemp)
trap 'rm -f "${OUT}"' EXIT
emit() { printf '%s\n' "$*" >> "${OUT}"; }

emit "## Tool grounding (pre-executed before this review)"
emit ""

# --- step 1: collect changed files ---
collect_changed_files() {
  {
    git diff --name-only HEAD 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | sort -u | grep -v '^$' || true
}

CHANGED_FILES=()
while IFS= read -r f; do
  [[ -n "$f" ]] && CHANGED_FILES+=("$f")
done < <(collect_changed_files)

# --- step 2: predicate ---
is_module_affecting() {
  local f="$1"
  case "$f" in
    vendor/*|*/vendor/*) return 1 ;;
    .git/*|*/.git/*) return 1 ;;
    node_modules/*|*/node_modules/*) return 1 ;;
    testdata/*|*/testdata/*) return 1 ;;
  esac
  case "$f" in
    *.go) return 0 ;;
    go.mod|*/go.mod) return 0 ;;
    go.sum|*/go.sum) return 0 ;;
    go.work|go.work.sum) return 0 ;;
    .golangci.yml|.golangci.yaml|.golangci.toml|.golangci.json) return 0 ;;
    */.golangci.yml|*/.golangci.yaml|*/.golangci.toml|*/.golangci.json) return 0 ;;
  esac
  return 1
}

# --- step 3: nearest go.mod walk ---
# Returns the directory containing the enclosing non-empty go.mod, or
# nothing if none found / if the enclosing go.mod is empty (exclude marker).
nearest_gomod_dir() {
  local d
  d="$(dirname "$1")"
  while true; do
    if [[ -f "$d/go.mod" ]]; then
      if [[ -s "$d/go.mod" ]]; then
        printf '%s\n' "$d"
      fi
      return 0
    fi
    if [[ "$d" == "/" || "$d" == "." || -z "$d" ]]; then
      return 1
    fi
    d="$(dirname "$d")"
  done
}

# --- step 4: classify changes ---
AFFECTED_FILES=()
ORPHAN_GO_FILES=()        # .go files not under any go.mod
declare -A AFFECTED_MODULES=()  # key = module dir, value = 1

for f in "${CHANGED_FILES[@]}"; do
  if ! is_module_affecting "$f"; then continue; fi
  AFFECTED_FILES+=("$f")
  mod="$(nearest_gomod_dir "$f" || true)"
  if [[ -n "$mod" ]]; then
    AFFECTED_MODULES["$mod"]=1
  elif [[ "$f" == *.go ]]; then
    ORPHAN_GO_FILES+=("$f")
  fi
done

# --- step 5: report status if nothing to do ---
TOTAL_AFFECTED=${#AFFECTED_FILES[@]}
TOTAL_MODULES=${#AFFECTED_MODULES[@]}

if [[ "$TOTAL_AFFECTED" -eq 0 ]]; then
  emit "(no module-affecting files in this diff)"
  emit ""
  emit "Diff includes ${#CHANGED_FILES[@]} changed file(s); none matched the"
  emit "tool-grounding predicate (no .go, go.mod, go.sum, go.work, or"
  emit ".golangci.yml changes outside vendor/testdata/node_modules)."
  emit ""
  emit "Codex should review the diff without tool-derived evidence."
  cat "${OUT}"
  exit 0
fi

if [[ "$TOTAL_MODULES" -eq 0 ]]; then
  emit "(Go files changed but no enclosing go.mod found)"
  emit ""
  emit "Could not walk any changed file up to a non-empty go.mod. Either"
  emit "the project is not Go, the relevant go.mod is missing, or the"
  emit "enclosing go.mod is empty (Grab \"exclude this subtree\" marker)."
  emit ""
  if [[ "${#ORPHAN_GO_FILES[@]}" -gt 0 ]]; then
    emit "Orphan Go files in this diff:"
    for f in "${ORPHAN_GO_FILES[@]:0:20}"; do
      emit "  - ${f}"
    done
    [[ "${#ORPHAN_GO_FILES[@]}" -gt 20 ]] && emit "  ... and $((${#ORPHAN_GO_FILES[@]} - 20)) more"
    emit ""
  fi
  emit "Codex should investigate the repo layout."
  cat "${OUT}"
  exit 0
fi

# --- step 6: run tools per affected module ---
emit "**Summary:** ${TOTAL_MODULES} affected Go module(s), ${TOTAL_AFFECTED} affected file(s)."
emit ""

run_tool() {
  local mod="$1"; shift
  local label="$1"; shift
  local bin="$1"; shift

  emit "### ${label}"

  if ! command -v "${bin}" >/dev/null 2>&1; then
    emit "(skipped: ${bin} not installed)"
    emit ""
    return 0
  fi

  local out rc
  out=$(cd "${PROJECT_DIR}/${mod}" 2>/dev/null && \
        timeout "${PER_TOOL_TIMEOUT_S}" "${bin}" "$@" 2>&1)
  rc=$?

  if [[ "${rc}" == "124" ]]; then
    emit "(timed out after ${PER_TOOL_TIMEOUT_S}s)"
    emit ""
    return 0
  fi

  if [[ -z "${out}" ]]; then
    emit "(clean)"
    emit ""
    return 0
  fi

  local capped
  capped=$(printf '%s' "${out}" | head -c "${PER_TOOL_CHAR_CAP}")
  emit '```'
  emit "${capped}"
  if [[ "${#out}" -gt "${PER_TOOL_CHAR_CAP}" ]]; then
    emit ""
    emit "(... truncated; full output was ${#out} chars)"
  fi
  emit '```'
  emit ""
}

# Sorted module list for deterministic output across runs.
SORTED_MODULES=()
while IFS= read -r m; do SORTED_MODULES+=("$m"); done < <(printf '%s\n' "${!AFFECTED_MODULES[@]}" | sort)

for mod in "${SORTED_MODULES[@]}"; do
  emit "## Module: \`${mod}\`"
  emit ""

  if ! command -v go >/dev/null 2>&1; then
    emit "(go binary not on PATH; cannot run any Go tooling)"
    emit ""
    continue
  fi

  run_tool "${mod}" "gofmt -l ./..." gofmt -l .
  run_tool "${mod}" "go vet ./..." go vet ./...
  run_tool "${mod}" "staticcheck ./..." staticcheck ./...
  run_tool "${mod}" "golangci-lint run" golangci-lint run --timeout=50s ./...
  run_tool "${mod}" "govulncheck ./..." govulncheck ./...
done

# --- step 7: enforce total-output cap ---
TOTAL_SIZE=$(wc -c < "${OUT}" | tr -d ' ')
if [[ "${TOTAL_SIZE}" -gt "${TOTAL_CHAR_CAP}" ]]; then
  head -c "${TOTAL_CHAR_CAP}" "${OUT}"
  echo ""
  echo "(... total tool grounding output truncated at ${TOTAL_CHAR_CAP} chars;"
  echo " full output was ${TOTAL_SIZE} chars across ${TOTAL_MODULES} module(s))"
else
  cat "${OUT}"
fi

exit 0
