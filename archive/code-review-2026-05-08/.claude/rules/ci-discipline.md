# CI and Pull Request Discipline

## Size

Target:   ≤300 lines changed per PR
Warning:  300–600 lines changed (explain why it can't split)
Required split: >600 lines changed

Exceptions (no warning, no split):
- Generated code
- Bulk deletions
- Mechanical renames
- Formatting-only changes

## Scope

One PR = one self-contained change. If you cannot describe it in one
sentence, it should be multiple PRs.

Do not mix:
- refactor + bugfix
- dependency upgrade + behavior change
- test additions + production code changes in areas unrelated to the tests

## Tests in the same PR

Every production logic change must include the tests that prove it.
Adding tests in a follow-up PR is only acceptable for emergency
hotfixes, and only with an explicit tracking issue.

For Tier 1 paths, the TDD ceremony enforces this: a `green(<id>):`
commit without a preceding `red(<id>):` commit fails the
`tdd-ceremony-check` CI job.

## CI gates

No merge without:

1. All tests pass (`go test ./...`)
2. Race tests pass (`go test -race -count=1 ./...`)
3. Lint passes (`golangci-lint run`)
4. Static analysis passes (`go vet ./...`, `staticcheck ./...`)
5. Dependency vulnerability scan passes (`govulncheck ./...`)
6. Allowed-modules check passes (`scripts/check-allowed-modules.sh`)
7. Dead-code check passes (`scripts/check-deadcode.sh`)
8. TDD ceremony check passes (for Tier 1 changes)
9. Build of all production binaries succeeds

Nightly or scheduled:
- Long-running integration tests
- Full security scan (including container image scans if applicable)
- Dependency update proposals

## Forbidden git operations

Under no circumstances:

- `git commit --no-verify` (bypasses pre-commit hooks; blocked at
  hook level)
- `git push --force` without `--force-with-lease`, even on feature
  branches (blocked at hook level)
- `git filter-repo` or `git filter-branch` on shared branches (blocked)
- `git reset --hard origin/*` on shared branches (blocked)
- Pushing directly to main/master/trunk without a PR/MR

These operations have caused documented production incidents. The hooks
in this pack block them at the tool level; do not try to work around
the block by editing `.claude/settings.json` (also blocked).

## Review expectations

A PR review is approved when the change improves overall code health,
not when it is perfect. Known follow-up work should be captured as
issues/tickets, not as blockers on the current PR.

Reviewers check:

- Design soundness
- Correctness of the change for the stated failure mode
- Adequate test coverage for the risk level
- Edge cases and failure modes considered
- Known concerns either fixed or explicitly documented
- For Tier 1: TDD ceremony observed (red commit before green commit,
  red-proof artifact present)

## When CI is broken

A broken main/trunk branch is a P1 incident. Either fix-forward quickly
or revert. Do not merge on top of red CI.
