# Bugfix Plan: f6-enforcement-mode-config — graduated strict/warn/off for process-discipline gates

Status: active
Cycle ID: f6-enforcement-mode-config
Change type: enhancement (rollout ergonomics)
Tier: 1

<!-- TDD ceremony markers. Set each ONLY after the matching operator APPROVED reply. -->
Bug reproduced: yes
Human approved spec: yes
Red phase confirmed: yes
Green phase authorized: yes
Implementation reviewed: yes
Fix applied: yes
Regression tests added: yes
Bug-elsewhere check complete: yes

## Bug

The pack's deny gates today have only binary enforcement: ON (deny +
exit 2) or OFF via per-hook env-var killswitch (`TDD_COMMIT_GATE_DISABLE`,
`SECOND_OPINION_DISABLE`). Two gates have no killswitch at all
(`require-tdd-state`, `guard-bash-pipefail`). No graduated mode for
teams adopting the pack — they hit hard denials before they understand
the discipline, then either disable everything or fight the gates.

The friction is real:
- A team installing the pack on day 1 wants to learn the gates without
  their commits being blocked
- A team mid-migration wants `warn` mode while they fix the workflow,
  then flip to `strict` once the team is aligned
- The existing env-var killswitches are emergency-only (env vars don't
  travel via git; team-shared config does)

## Acceptance criteria

1. `.tdd/tdd-config.json` accepts a top-level `enforcement_mode`
   field with values `strict` (default) / `warn` / `off`.
2. `.tdd/tdd-config.json` accepts `enforcement_mode_overrides` — an
   object mapping hook basename → mode for per-hook tuning.
3. Per-hook override takes precedence over global default.
4. The 4 process-discipline gates read the mode and act accordingly:
   - `gate-tier1-commit`
   - `require-second-opinion`
   - `require-tdd-state`
   - `guard-bash-pipefail`
   On a deny condition:
   - `strict` → deny + exit 2 (current behavior preserved)
   - `warn` → stderr "[hook-name] WARNING: ..." + allow exit 0
   - `off` → silent passthrough exit 0
5. Existing env-var killswitches (`TDD_COMMIT_GATE_DISABLE=1`,
   `SECOND_OPINION_DISABLE=1`) continue to work — equivalent to
   `off` mode for that hook (no behavior change for emergency).
6. Security gates IGNORE the config — strict-only by design:
   - `guard-dangerous-bash`
   - `guard-protected-files`
   - `scan-for-secrets`
7. Invalid mode value (typo, non-string) → fall back to `strict` with
   a stderr warning. Defense-in-depth: typos can't accidentally soften.
8. Smoke tests cover the matrix.

## Non-goals

- Per-finding mode (warn on P2, deny on P0). Whole-hook granularity
  only; severity-aware gates would be a separate spec.
- Auto-promotion (warn → strict after N days). Manual flip via config
  is enough for v1.
- A separate "soft" mode that escalates after N warnings. Same.
- Applying enforcement_mode to security gates. By design they are
  fail-closed; teams can't soften them via config.

## Affected code

- `.tdd/tdd-config.json` — add `enforcement_mode` + `enforcement_mode_overrides`
- `.claude/hooks/gate-tier1-commit.sh` — wire mode into deny path
- `.claude/hooks/require-second-opinion.sh` — wire mode into deny path
- `.claude/hooks/require-tdd-state.sh` — wire mode into deny path
- `.claude/hooks/guard-bash-pipefail.sh` — wire mode into deny path
- `scripts/tdd-test-hooks.sh` — new tests covering the matrix

## Test plan

| Test name | Pins criterion # |
|---|---|
| f6_default_mode_is_strict | 1 |
| f6_global_warn_emits_stderr_allows | 4 (warn) |
| f6_global_off_silent_passthrough | 4 (off) |
| f6_override_takes_precedence | 3 |
| f6_existing_killswitch_still_works | 5 |
| f6_security_hook_ignores_warn_config | 6 |
| f6_invalid_mode_falls_back_to_strict | 7 |
| f6_warn_mode_does_not_block_commit (gate-tier1-commit) | 4 |
| f6_warn_mode_does_not_block_edit (require-second-opinion) | 4 |
| f6_warn_mode_does_not_block_pipefail | 4 |

## Minimum implementation

### Config shape

```json
{
  "enforcement_mode": "strict",
  "enforcement_mode_overrides": {
    "require-second-opinion": "warn"
  }
}
```

### Shared helper (inlined per hook for portability)

Each gate's deny path becomes:

```bash
# Resolve mode: per-hook override > global > default "strict".
resolve_enforcement_mode() {
  local hook_name="$1" cfg="$2"
  if [[ ! -f "$cfg" ]] || ! command -v jq >/dev/null 2>&1; then
    echo "strict"; return
  fi
  local override
  override="$(jq -r --arg n "$hook_name" '.enforcement_mode_overrides[$n] // empty' "$cfg" 2>/dev/null)"
  if [[ -n "$override" && "$override" != "null" ]]; then
    case "$override" in strict|warn|off) echo "$override"; return ;; esac
  fi
  local global
  global="$(jq -r '.enforcement_mode // "strict"' "$cfg" 2>/dev/null)"
  case "$global" in strict|warn|off) echo "$global" ;; *) echo "strict" ;; esac
}

# Replace `deny(...)` with mode-aware version:
HOOK_NAME="$(basename "$0" .sh)"
ENFORCEMENT_MODE="$(resolve_enforcement_mode "$HOOK_NAME" "$CONFIG")"

deny_with_mode() {
  local reason="$1" key="$2" target="${3:-}"
  case "$ENFORCEMENT_MODE" in
    off)
      audit "off_mode_passthrough" "{\"reason\":\"${reason//\"/\\\"}\"}"
      exit 0
      ;;
    warn)
      audit "warn_mode" "{\"reason\":\"${reason//\"/\\\"}\"}"
      cat >&2 <<DIRECTIVE
[$HOOK_NAME] WARNING (enforcement_mode=warn): $reason
This would be DENIED in strict mode. To enforce, set
enforcement_mode: "strict" in .tdd/tdd-config.json.
DIRECTIVE
      jq -n '{}'  # explicit allow
      exit 0
      ;;
    strict|*)
      # Original deny logic (jq JSON, stderr directive, exit 2)
      deny_strict "$reason" "$key" "$target"
      ;;
  esac
}
```

### Killswitch precedence

Existing env-var killswitches map to "off" mode for that hook only.
They check FIRST (before mode resolution) so emergency override is
unchanged.

### Security gate isolation

`guard-dangerous-bash`, `guard-protected-files`, `scan-for-secrets`
do NOT call `resolve_enforcement_mode`. Their deny paths are
strict-only. Documented in each hook header.

## Risk register

| Risk | Mitigation |
|---|---|
| Operator sets warn globally and forgets — gates effectively off forever | Documented; warn mode emits visible stderr per call so it's not silent. |
| Per-hook override gets out of sync with global | Resolution is per-call (config read each time); no caching. |
| Invalid mode value silently disables gates | AC 7: fall back to strict + stderr warning. |
| Test fixtures need to flip the mode mid-suite | Use a helper to set + restore the mode per test (mirrors existing `f5_set_flag`). |
| Security gates accidentally honor the mode | Each security hook's audit trail shows it ignored the config (stderr "strict-only by design"). |
