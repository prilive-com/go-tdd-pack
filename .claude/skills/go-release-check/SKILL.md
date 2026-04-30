---
name: go-release-check
description: Pre-release Go checklist for services, libraries, and CLIs.
license: MIT
version: 1.0.0
---

# Go Release Check

Run before any version bump or deploy.

## Universal

- `go test ./...` and `go test -race ./...` green
- `go vet ./...`, `staticcheck ./...`, `golangci-lint run` clean
- `govulncheck ./...` clean (justify findings)
- Allowed-modules check passes (`scripts/check-allowed-modules.sh`)
- TDD ceremony check passes for Tier 1 changes (CI runs
  `scripts/check-tdd-ceremony.sh`)
- CHANGELOG.md updated
- Public API docs updated

## For libraries

- `gorelease` / `apidiff` for SemVer impact
- Behavioral compatibility (no silent timeout/retry/default changes)
- `Example_xxx` tests for new exported APIs
- go.mod `go` directive conservative (don't bump unless required)

## For services

- Migration backward compatible
- Rollback plan documented
- Health checks (readiness/liveness)
- Operational alerts for the change
- Feature flag plan if behavior gates are involved

## For CLIs

- Flag/output/exit-code compatibility
- Config compatibility
- User workflow impact documented

## Output

A pass/fail verdict per item, then either:

- **Ready for release** — list any caveats
- **Not ready** — list the shortest possible blocking items, in
  order of urgency
