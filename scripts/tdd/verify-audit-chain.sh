#!/usr/bin/env bash
# scripts/tdd/verify-audit-chain.sh
#
# v1.8.0 AC5: verify the sha-chain integrity of a per-cycle audit log.
#
# Usage:
#   verify-audit-chain.sh <cycle-id>
#
# Reads .tdd/audit/<cycle-id>.jsonl line by line. For each line, the
# `prev_sha` field MUST equal sha256 of the previous line (verbatim,
# no trailing newline). The first line MUST have prev_sha == "".
#
# Exit codes:
#   0  chain intact (or empty file / file missing — vacuously OK).
#   1  chain broken (tamper detected). First diverging line is named
#      on stderr with expected vs actual prev_sha.
#   2  hard error (jq missing, non-JSON line, etc.).
#
# Lines without a `prev_sha` field are treated as legitimate
# pre-v1.8 history (one-shot stderr warning, not a failure). Once a
# `prev_sha` field appears, the chain is enforced from that point.

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "[verify-audit-chain] BLOCKED: jq required." >&2
  exit 2
fi

cycle_id="${1:-}"
if [[ -z "$cycle_id" ]]; then
  echo "usage: verify-audit-chain.sh <cycle-id>" >&2
  exit 2
fi

log=".tdd/audit/${cycle_id}.jsonl"
if [[ ! -f "$log" ]]; then
  exit 0
fi

sha256() {
  if   command -v sha256sum >/dev/null 2>&1; then sha256sum
  elif command -v shasum    >/dev/null 2>&1; then shasum -a 256
  else return 127
  fi
}

prev_line=""
prev_sha_warn=0
chain_started=0  # v1.8.0 round-5 F4: once any line has prev_sha,
                  # subsequent lines without it are tampering.
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))
  [[ -z "$line" ]] && continue
  if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
    echo "[verify-audit-chain] BLOCKED: line $lineno is not valid JSON." >&2
    exit 2
  fi
  has_prev_sha="$(printf '%s' "$line" | jq -r 'has("prev_sha")')"
  if [[ "$has_prev_sha" != "true" ]]; then
    if [[ "$chain_started" == "1" ]]; then
      echo "[verify-audit-chain] BLOCKED: chain_broken — line $lineno has no prev_sha field, but chain has already started (an earlier line had prev_sha). This looks like operator tampering." >&2
      exit 1
    fi
    if [[ "$prev_sha_warn" == "0" ]]; then
      echo "[verify-audit-chain] WARN: line $lineno has no prev_sha field (treating as pre-v1.8 history; chain check resumes from next line with prev_sha)." >&2
      prev_sha_warn=1
    fi
    prev_line="$line"
    continue
  fi
  chain_started=1
  stored_prev="$(printf '%s' "$line" | jq -r '.prev_sha')"
  if [[ "$lineno" -eq 1 ]] || [[ -z "$prev_line" ]]; then
    if [[ -n "$stored_prev" ]]; then
      echo "[verify-audit-chain] BLOCKED: chain_broken — line $lineno has prev_sha='$stored_prev' but it is the first line; expected empty." >&2
      exit 1
    fi
    prev_line="$line"
    continue
  fi
  expected_prev="$(printf '%s' "$prev_line" | sha256 | awk '{print $1}')"
  if [[ "$stored_prev" != "$expected_prev" ]]; then
    echo "[verify-audit-chain] BLOCKED: chain_broken — line $lineno prev_sha mismatch. Expected: $expected_prev. Got: $stored_prev." >&2
    exit 1
  fi
  prev_line="$line"
done < "$log"

exit 0
