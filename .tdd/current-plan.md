# Bugfix Plan: f3-smoke-tests-in-ci — wire scripts/tdd-test-hooks.sh into CI

Status: active
Cycle ID: f3-smoke-tests-in-ci
Change type: bugfix (gap)
Tier: 0 (CI config files are not Tier 1 path)

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

`scripts/tdd-test-hooks.sh` is the smoke-test suite for every hook in
`.claude/hooks/`. It now has 201 tests covering require-tdd-state,
require-second-opinion, gate-tier1-commit, guard-bash-pipefail,
guard-dangerous-bash, scan-for-secrets, ai-bloat, etc. The runner
exits non-zero on any failure (line 1 `set -euo pipefail`; final line
`[ $FAIL -eq 0 ]`). `make tdd-test` is already wired up.

But neither `.github/workflows/ci.yml` nor `.gitlab-ci.yml` runs it.
Regressions in any hook ship to consumers because:
- The pre-commit hooks of the local dev loop are advisory (Claude
  may bypass; gates use `permissionDecision`, not blocking shell rc)
- CI is the deterministic floor (per `.gitlab-ci.yml` header comment)
- CI doesn't run the suite — so the floor leaks

This was caught in this cycle's planning: the F2-cycle Layer 0 fix
sat in working tree because local smoke ran against working tree;
CI would have caught the unstaged-fix mismatch.

## Reproduction

Confirmed by inspection: `grep -l tdd-test-hooks .github/workflows/
.gitlab-ci.yml` returns nothing. Neither config invokes the runner.

## Acceptance criteria

1. `.github/workflows/ci.yml` has a job that runs
   `bash scripts/tdd-test-hooks.sh` (or `make tdd-test`).
2. The GitHub job runs on the same triggers as the existing `verify`
   job (push to main + pull_request).
3. The GitHub job installs the runtime deps the suite needs (`jq`,
   `git` already present on ubuntu-latest, `bash`).
4. `.gitlab-ci.yml` has an equivalent job in the `verify` stage.
5. The GitLab job uses an image with `bash`, `jq`, `git` available
   (the existing `golang:1.26-alpine` + apk install pattern works).
6. Both jobs FAIL the build when the smoke runner exits non-zero.
   (Default behavior for both CIs; no special flag needed.)
7. Smoke test: the new YAML configs parse cleanly (yamllint or
   `python -c 'import yaml; yaml.safe_load(open(...))'`).
8. Smoke test: each YAML config invokes the smoke runner (grep for
   `tdd-test-hooks` substring).

## Non-goals

- Running the smoke suite in BOTH GitHub and GitLab in production;
  the README says "delete whichever you don't need" — this cycle just
  ensures both work.
- Splitting the smoke suite into per-hook jobs for parallelism. The
  whole suite runs in <60s currently; no parallelism needed yet.
- Adding new tests. This cycle wires existing tests into CI.

## Affected code

- `.github/workflows/ci.yml` — add `tdd-test-hooks` job
- `.gitlab-ci.yml` — add `tdd-test-hooks` job
- `scripts/tdd-test-hooks.sh` — add 2 self-tests (AC 7, 8) at the end

## Test plan

| Test name | Pins criterion # |
|---|---|
| f3_github_workflow_yaml_valid | 7 |
| f3_github_workflow_invokes_smoke_runner | 8 |
| f3_gitlab_yaml_valid | 7 |
| f3_gitlab_invokes_smoke_runner | 8 |

(AC 1-6 are config presence/behavior; verified by AC 7-8 tests + manual
inspection of the resulting YAML.)

## Minimum implementation

### `.github/workflows/ci.yml`

Add after the `verify` job:

```yaml
  hook-smoke-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install jq
        run: sudo apt-get update && sudo apt-get install -y jq
      - name: Run hook smoke suite
        run: bash scripts/tdd-test-hooks.sh
```

### `.gitlab-ci.yml`

Add to the `verify` stage:

```yaml
hook-smoke-tests:
  stage: verify
  script:
    - bash scripts/tdd-test-hooks.sh
```

(`default.before_script` already installs bash + jq + git in alpine.)

## Risk register

| Risk | Mitigation |
|---|---|
| Smoke suite has external deps not in CI image (codex, etc.) | Verified: hooks pass through when codex is absent. The smoke tests don't invoke codex directly. |
| Suite is slow (>5min) and bloats CI time | Local run is <60s; ubuntu-latest should match. If too slow, follow-up cycle to parallelise. |
| Tests reference $HOME or absolute paths | Verified: `PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"` is used; no hardcoded user paths. |
| Tests depend on host git config | Tests use `git config user.email/name` inside test fixtures; safe in CI. |
