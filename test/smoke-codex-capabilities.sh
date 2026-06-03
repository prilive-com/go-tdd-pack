#!/usr/bin/env bash
# test/smoke-codex-capabilities.sh
#
# Unit tests for runner/lib/codex-capabilities.sh — the detector that
# learns what the installed `codex` CLI supports. Tests use synthetic
# fake-codex stubs in PATH so we cover (a) modern CLI with --json +
# --output-last-message + --output-schema, (b) older CLI without --json,
# (c) no CLI at all.

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CAPS_LIB="${PROJECT_DIR}/runner/lib/codex-capabilities.sh"

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "▶ $*"; }
PASS_COUNT=0

CLEANUP_PATHS=()
cleanup_all_sandboxes() {
  local p
  for p in "${CLEANUP_PATHS[@]}"; do
    [[ -n "$p" ]] && rm -rf "$p"
  done
}
trap cleanup_all_sandboxes EXIT

# Build a sandbox with .tdd/ so the cache file has somewhere to land.
make_sandbox() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.tdd"
  echo "$d"
}

# Write a fake codex CLI to a directory and add it to PATH.
# Behavior is parameterized: full = all flags; no-json = pre --json era;
# none = empty (binary not installed).
install_fake_codex() {
  local bindir="$1" mode="$2"
  mkdir -p "$bindir"
  case "$mode" in
    full)
      cat > "$bindir/codex" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "codex-cli 0.130.0-fake"; exit 0 ;;
  exec)
    case "${2:-}" in
      --help)
        cat <<HELP
Run Codex non-interactively
Options:
      --output-schema <FILE>
      --json
  -o, --output-last-message <FILE>
      --ignore-user-config
HELP
        exit 0
        ;;
      resume)
        case "${3:-}" in
          --help)
            cat <<HELP
Resume a previous session by id
Options:
      --json
  -o, --output-last-message <FILE>
HELP
            exit 0
            ;;
        esac
        ;;
    esac
    ;;
esac
echo "fake codex called with: $*" >&2
exit 0
EOF
      chmod +x "$bindir/codex"
      ;;
    no-json)
      cat > "$bindir/codex" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "codex-cli 0.120.0-fake-old"; exit 0 ;;
  exec)
    case "${2:-}" in
      --help)
        cat <<HELP
Run Codex non-interactively
Options:
      --output-schema <FILE>
  -o, --output-last-message <FILE>
HELP
        exit 0
        ;;
      resume)
        case "${3:-}" in
          --help)
            cat <<HELP
Resume a previous session by id
Options:
  -o, --output-last-message <FILE>
HELP
            exit 0
            ;;
        esac
        ;;
    esac
    ;;
esac
exit 0
EOF
      chmod +x "$bindir/codex"
      ;;
  esac
}

# ---- case 1: modern CLI (full caps) ----

info "[1] modern CLI: detects --json, --output-last-message, --output-schema exec"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("${SANDBOX}")
BINDIR="${SANDBOX}/bin"
install_fake_codex "${BINDIR}" "full"

# Run detector with fake codex in PATH
(
  export PATH="${BINDIR}:${PATH}"
  # shellcheck source=/dev/null
  . "${CAPS_LIB}"
  codex_detect_capabilities "${SANDBOX}"
)
CACHE="${SANDBOX}/.tdd/.codex-capabilities.json"
[[ -f "$CACHE" ]] || fail "cache file not written"

ver=$(jq -r '.version' "$CACHE")
[[ "$ver" == "codex-cli 0.130.0-fake" ]] || fail "version mismatch: got '$ver'"
pass "modern CLI: version captured ($ver)"
PASS_COUNT=$((PASS_COUNT + 1))

for cap in supports_json supports_output_last_message supports_output_schema_exec supports_ignore_user_config; do
  val=$(jq -r --arg c "$cap" '.[$c]' "$CACHE")
  if [[ "$val" == "true" ]]; then
    pass "modern CLI: $cap = true"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    fail "modern CLI: $cap expected true, got $val"
  fi
done

# resume schema: NOT supported on this fake (matches reality on 0.129)
val=$(jq -r '.supports_output_schema_resume' "$CACHE")
[[ "$val" == "false" ]] || fail "resume schema should be false; got $val"
pass "modern CLI: supports_output_schema_resume correctly = false"
PASS_COUNT=$((PASS_COUNT + 1))

# ---- case 2: older CLI without --json ----

info "[2] older CLI: detects no --json on exec, no --json on resume"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("${SANDBOX}")
BINDIR="${SANDBOX}/bin"
install_fake_codex "${BINDIR}" "no-json"

(
  export PATH="${BINDIR}:${PATH}"
  # shellcheck source=/dev/null
  . "${CAPS_LIB}"
  codex_detect_capabilities "${SANDBOX}"
)
CACHE="${SANDBOX}/.tdd/.codex-capabilities.json"
val=$(jq -r '.supports_json' "$CACHE")
[[ "$val" == "false" ]] || fail "older CLI: supports_json should be false; got $val"
pass "older CLI: supports_json correctly = false"
PASS_COUNT=$((PASS_COUNT + 1))

# v2.1 PR 7: --ignore-user-config wasn't in the old CLI either
val=$(jq -r '.supports_ignore_user_config' "$CACHE")
[[ "$val" == "false" ]] || fail "older CLI: supports_ignore_user_config should be false; got $val"
pass "older CLI: supports_ignore_user_config correctly = false"
PASS_COUNT=$((PASS_COUNT + 1))

val=$(jq -r '.supports_output_last_message' "$CACHE")
[[ "$val" == "true" ]] || fail "older CLI: supports_output_last_message should be true; got $val"
pass "older CLI: supports_output_last_message correctly = true"
PASS_COUNT=$((PASS_COUNT + 1))

# ---- case 3: no codex CLI ----

info "[3] no CLI: writes available=false marker"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("${SANDBOX}")
EMPTY_BINDIR="${SANDBOX}/empty-bin"
mkdir -p "${EMPTY_BINDIR}"

(
  # Keep coreutils on PATH (jq, dirname, date are required by the lib)
  # but place an empty bindir FIRST so `codex` is not resolvable.
  # Sandbox-bin contains no `codex` binary → command -v codex fails.
  export PATH="${EMPTY_BINDIR}:/usr/bin:/bin"
  # shellcheck source=/dev/null
  . "${CAPS_LIB}"
  codex_detect_capabilities "${SANDBOX}"
)
CACHE="${SANDBOX}/.tdd/.codex-capabilities.json"
avail=$(jq -r '.available' "$CACHE")
[[ "$avail" == "false" ]] || fail "no CLI: available should be false; got $avail"
pass "no CLI: cache writes available=false marker"
PASS_COUNT=$((PASS_COUNT + 1))

# ---- case 4: cap query returns false when no cache ----

info "[4] codex_cap_supports returns false when no cache file"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("${SANDBOX}")

(
  # shellcheck source=/dev/null
  . "${CAPS_LIB}"
  val=$(codex_cap_supports supports_json "${SANDBOX}")
  if [[ "$val" == "false" ]]; then
    exit 0
  else
    exit 1
  fi
) || fail "codex_cap_supports should return false on missing cache"
pass "codex_cap_supports defaults to false when no cache"
PASS_COUNT=$((PASS_COUNT + 1))

# ---- case 5: cache is re-used on same version ----

info "[5] cache survives second invocation on same version"
SANDBOX=$(make_sandbox); CLEANUP_PATHS+=("${SANDBOX}")
BINDIR="${SANDBOX}/bin"
install_fake_codex "${BINDIR}" "full"

(
  export PATH="${BINDIR}:${PATH}"
  # shellcheck source=/dev/null
  . "${CAPS_LIB}"
  codex_detect_capabilities "${SANDBOX}"
  ts1=$(jq -r '.detected_at' "${SANDBOX}/.tdd/.codex-capabilities.json")
  sleep 1
  codex_detect_capabilities "${SANDBOX}"
  ts2=$(jq -r '.detected_at' "${SANDBOX}/.tdd/.codex-capabilities.json")
  # Same version → cache should NOT be re-written → ts1 == ts2
  if [[ "$ts1" == "$ts2" ]]; then
    exit 0
  else
    echo "ts1=$ts1 ts2=$ts2" >&2
    exit 1
  fi
) || fail "cache should not be rewritten when version unchanged"
pass "cache is reused on second invocation (same version)"
PASS_COUNT=$((PASS_COUNT + 1))

# ---- summary ----

echo ""
echo "================================================================"
echo "  CODEX CAPABILITIES SMOKE — PASS (${PASS_COUNT} checks)"
echo "================================================================"

exit 0
