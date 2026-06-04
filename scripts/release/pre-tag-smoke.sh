#!/usr/bin/env bash
# scripts/release/pre-tag-smoke.sh
#
# Action A1 from docs/POSTMORTEM-v2.1.0.md.
#
# Runs the two live Codex smokes against the current HEAD and writes a
# SHA-stamped artifact proving the run happened. Without this proof,
# the per-release checklist refuses to tag.
#
# Why this exists: the v2.1.0 release had its CHANGELOG and CI smokes
# green but never ran the live smokes against the post-merge clean
# `main`. The live smokes are the only thing that hits OpenAI strict
# mode and the only thing that resolves the configured Codex model
# against the live auth backend. The v2.1.0 schema strict-mode bug
# and the model-default crash would both have been caught here.
#
# Usage:
#   bash scripts/release/pre-tag-smoke.sh
#
# Preconditions:
#   - On a clean working tree (the smokes' own dirty-tree guard will
#     refuse otherwise, but we also exit early with a clear message).
#   - `codex` CLI on PATH with a valid `codex login` session (subscription
#     or API-key — both must work; A1's whole point is to verify both).
#   - `jq` and `git` available.
#
# Output:
#   .tdd/release/pre-tag-smoke-<SHORT_SHA>.txt — audit artifact.
#   Exit code 0 = both smokes PASS, OK to tag.
#   Exit code 1 = one or more smoke FAIL, DO NOT TAG.
#   Exit code 2 = preconditions not met (dirty tree, missing tools, etc).

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${PROJECT_ROOT}" || { echo "cannot cd to project root: ${PROJECT_ROOT}" >&2; exit 2; }

ARTIFACT_DIR="${PROJECT_ROOT}/.tdd/release"
mkdir -p "${ARTIFACT_DIR}"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
amber() { printf '\033[33m%s\033[0m\n' "$*"; }

# --- preconditions ---------------------------------------------------------

for tool in jq git codex bash; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    red "required tool not on PATH: ${tool}"
    exit 2
  fi
done

if [[ -n "$(git status --porcelain)" ]]; then
  red "working tree is dirty — the live smokes need a clean tree to mean anything."
  red "  Commit or stash first, then re-run."
  git status --short | sed 's/^/    /'
  exit 2
fi

SHA_FULL="$(git rev-parse HEAD)"
SHA_SHORT="$(git rev-parse --short HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
CODEX_VER="$(codex --version 2>/dev/null | head -1 | tr -d '\n' || echo 'unknown')"
RUN_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

ARTIFACT="${ARTIFACT_DIR}/pre-tag-smoke-${SHA_SHORT}.txt"

# --- run the two live smokes ----------------------------------------------

amber "Pre-tag live smoke run"
echo "  HEAD:         ${SHA_SHORT} (${SHA_FULL})"
echo "  branch:       ${BRANCH}"
echo "  codex CLI:    ${CODEX_VER}"
echo "  artifact:     ${ARTIFACT#${PROJECT_ROOT}/}"
echo ""

run_smoke() {
  local name="$1"
  local path="${PROJECT_ROOT}/test/${name}"
  if [[ ! -x "${path}" ]]; then
    red "${name}: missing or not executable at ${path}"
    printf '%s\n' "${name}|2|missing|missing|0"
    return 1
  fi
  amber "${name}"
  local started ended elapsed rc
  started=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  if bash "${path}"; then
    rc=0
  else
    rc=$?
  fi
  ended=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  elapsed=$(($(date -d "${ended}" +%s) - $(date -d "${started}" +%s)))
  if [[ ${rc} -eq 0 ]]; then
    green "${name} PASS (${elapsed}s)"
  else
    red "${name} FAIL (exit ${rc}, ${elapsed}s)"
  fi
  printf '%s\n' "${name}|${rc}|${started}|${ended}|${elapsed}"
}

MVP_RESULT=$(run_smoke "smoke-v2-mvp.sh" | tail -1)
echo ""
PHASE2_RESULT=$(run_smoke "smoke-v2-phase2-live.sh" | tail -1)
echo ""

MVP_RC=$(echo "${MVP_RESULT}" | awk -F'|' '{print $2}')
PHASE2_RC=$(echo "${PHASE2_RESULT}" | awk -F'|' '{print $2}')

# --- write artifact -------------------------------------------------------

{
  echo "pre-tag live smoke run"
  echo "======================"
  echo ""
  echo "run_at:       ${RUN_AT}"
  echo "sha:          ${SHA_FULL}"
  echo "sha_short:    ${SHA_SHORT}"
  echo "branch:       ${BRANCH}"
  echo "codex_cli:    ${CODEX_VER}"
  echo ""
  echo "smoke-v2-mvp.sh:         ${MVP_RESULT}"
  echo "smoke-v2-phase2-live.sh: ${PHASE2_RESULT}"
  echo ""
  if [[ "${MVP_RC}" == "0" && "${PHASE2_RC}" == "0" ]]; then
    echo "verdict: OK to tag against ${SHA_SHORT}"
  else
    echo "verdict: DO NOT TAG — at least one smoke failed at ${SHA_SHORT}"
  fi
} > "${ARTIFACT}"

# --- final verdict --------------------------------------------------------

echo ""
if [[ "${MVP_RC}" == "0" && "${PHASE2_RC}" == "0" ]]; then
  green "================================================================"
  green "  PRE-TAG LIVE SMOKE — PASS at ${SHA_SHORT}"
  green "  Artifact: ${ARTIFACT#${PROJECT_ROOT}/}"
  green "  OK to proceed to: git tag vX.Y.Z ${SHA_SHORT}"
  green "================================================================"
  exit 0
else
  red "================================================================"
  red "  PRE-TAG LIVE SMOKE — FAIL at ${SHA_SHORT}"
  red "  Artifact: ${ARTIFACT#${PROJECT_ROOT}/}"
  red "  DO NOT TAG. Diagnose, fix, re-run."
  red "================================================================"
  exit 1
fi
