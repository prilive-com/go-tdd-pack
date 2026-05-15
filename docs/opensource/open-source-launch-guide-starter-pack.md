# Open Source Release Guide — go-claude-starter

How to publish `go-claude-starter` (currently private) as a public
open-source project on GitHub.

**Companion guide:** [`open-source-launch-guide-universal.md`](open-source-launch-guide-universal.md) —
generic OSS opening checklist. This guide assumes you have read that
one. It covers what's specific to *this* project.

**Status:** Action plan. Walk through it in order.
**Estimated effort:** 8–16 hours of focused work, plus 1–2 weeks for
optional hardening.
**Risk level:** Medium. Public exposure invites scrutiny; you must scrub
secrets, set governance, and back up the current state before flipping.

---

## 0. Why this is non-trivial for this pack

`go-claude-starter` is a **security-relevant Claude Code plugin**. It
ships:

- Deterministic safety hooks (dangerous-bash blocker, secret scanner,
  TDD enforcement, second-opinion gate)
- Reviewer agents (concurrency, security, architecture)
- Skills, rules, templates
- A SHA-chained audit log system

A tool whose job is to enforce security must clear a higher trust bar
than a generic library. See **§17.1** of `open-source-launch-guide-universal.md` for
the 12 expectations. This guide makes them concrete for this repo.

The pack is also **at v1.9.3** with v1.4 through v1.9.3 untagged in
git. The release backfill is part of the work.

---

## 1. Pre-publication scrub (do this first; allow 2-4 hours)

### 1.1 Secret audit on full history

```bash
cd ~/go-projects-claude-starter

# Run the same gitleaks the pack ships, against itself.
gitleaks detect --source . --log-level info --no-banner

# Belt-and-suspenders: look for high-shape patterns the regex misses.
git log -p --all | grep -E '(AKIA|ghp_|sk-ant-|sk-[A-Za-z0-9]{32}|xox[abprs]-|-----BEGIN)' | head

# Look for personal data that snuck in.
git log --format='%an <%ae>' | sort -u
```

If anything turns up, **do not skip the rotation step**. Treat any
secret that ever existed in history as compromised. Use `git filter-repo`
to rewrite history (see `open-source-launch-guide-universal.md` §1.2).

### 1.2 Pre-publication snapshot

```bash
git bundle create ~/pre-public-go-claude-starter-$(date +%Y%m%d).bundle --all
sha256sum ~/pre-public-go-claude-starter-*.bundle
```

Store offline. If anything goes wrong, you have the original.

### 1.3 Audit the existing files

The repo has files that shouldn't ship to public:

```bash
ls -la

# Likely-private files to review/remove:
# - .gitlab-ci.yml      (gitlab-specific; replace with .github/workflows/)
# - .mcp.json           (may have personal MCP server URLs)
# - REVIEW.md           (private review notes? check)
# - CONSULTANT_BRIEF.md (private consulting context? check)
# - archive/            (old code-review tarballs and snapshots)
```

For each, decide: keep, redact, or delete. Document the decision in a
PR description.

### 1.4 Existing untagged work

```bash
git tag --sort=-v:refname | head
# Currently shows: v1.3.1 v1.3.0 v1.2.0 v1.1.1 v1.1.0
```

But the codebase is at **v1.9.3** per commit messages. Tags v1.4
through v1.9.3 are missing. Either backfill them (see §6) or accept
that the public history starts with v1.9.3 and document earlier
versions only in the changelog.

---

## 2. License selection: pick **Apache-2.0**

For this pack, Apache-2.0 is the right choice. Reasons:

- **Explicit patent grant.** The pack contains hooks that may be
  patentable (the typed-exception system, the second-opinion runner).
  Apache-2.0's patent grant is meaningful for adopters at large
  companies.
- **Corporate-friendly.** Most enterprise Go users see Apache-2.0
  as the safe default.
- **OSI-approved + Scorecard-credit + CNCF-eligible.** All the things
  BSL/SSPL/PolyForm lose.
- **Compatible with the dependencies you ship** (no GPL deps in the
  pack today).

```bash
# Add the LICENSE file at repo root.
curl -L -o LICENSE https://www.apache.org/licenses/LICENSE-2.0.txt

# Add a NOTICE file (Apache-2.0 §4(d) requires one if you have prior
# attribution to preserve; otherwise optional but conventional).
cat > NOTICE <<'EOF'
go-claude-starter
Copyright 2026 Anton Dvornikov and contributors

This product is licensed under the Apache License 2.0.
See LICENSE for the full text.
EOF
```

Add the SPDX identifier to source files:

```bash
# Hook scripts — add as the first non-shebang line:
# # SPDX-License-Identifier: Apache-2.0

# Markdown files — typically NOT annotated; LICENSE at root is sufficient.
```

---

## 3. Required community files (gap analysis)

Repo state today vs. what's required:

| File | Today | Required | Action |
|---|---|---|---|
| `LICENSE` | missing | Apache-2.0 | **§2** |
| `README.md` | exists (184 lines) | Refresh for public audience | **§4** |
| `CONTRIBUTING.md` | missing | DCO + AI policy + setup | **§5** |
| `CODE_OF_CONDUCT.md` | missing | Contributor Covenant 2.1 | **§5** |
| `SECURITY.md` | missing | PVR + supported versions + timeline | **§5** |
| `CHANGELOG.md` | missing | Keep-a-Changelog, backfilled from git | **§6** |
| `.github/CODEOWNERS` | missing | Maintainer routing | **§5** |
| `.github/ISSUE_TEMPLATE/` | missing | Bug, feature, config | **§5** |
| `.github/pull_request_template.md` | missing | Standard checklist | **§5** |
| `.github/dependabot.yml` | missing | Go + actions weekly | **§7** |
| `.github/workflows/ci.yml` | check | Build + lint + smoke | **§7** |
| `.github/workflows/codeql.yml` | check | CodeQL on PR + main | **§7** |
| `.github/workflows/scorecard.yml` | check | Weekly Scorecard | **§7** |
| `.github/workflows/dependency-review.yml` | check | License + vuln on PR | **§7** |
| `.github/workflows/release.yml` | missing | Tag-triggered, signed | **§7** |
| `NOTICE` | missing | Apache-2.0 conventional | **§2** |

---

## 4. Refresh the README for a public audience

The current README (184 lines) was written for internal use. Public
README must answer in the first screen:

- **What is this?** (1 sentence)
- **Who is it for?** (Go developers using Claude Code)
- **What problem does it solve?** (Safety + TDD + second-opinion review
  baked in)
- **30-second install** (the `/plugin install` command)
- **Where to learn more** (link to docs)

Suggested structure:

```markdown
# go-claude-starter

[![CI](https://github.com/<org>/<repo>/actions/workflows/ci.yml/badge.svg)](https://github.com/<org>/<repo>/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/<org>/<repo>/badge)](https://securityscorecards.dev/viewer/?uri=github.com/<org>/<repo>)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/<id>/badge)](https://www.bestpractices.dev/projects/<id>)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

A Claude Code plugin that ships deterministic safety hooks, reviewer
agents, and a TDD-with-second-opinion enforcement system for Go projects.

## What it does

- Blocks dangerous Bash commands (`rm -rf`, `--no-verify` git commits,
  history rewrites) before they execute.
- Scans every file write for AWS keys, GitHub tokens, OpenAI keys,
  Anthropic keys, JWTs, PEM blocks, and DSNs.
- Enforces a TDD ceremony with red proof, second-opinion review, and
  green proof captured per cycle.
- Provides three reviewer specialists for Go: concurrency, security,
  architecture. Tuned for Go 1.26+, pgx/v5, golangci-lint.
- Maintains a SHA-chained audit log of every governance event for
  post-incident review.

## Quickstart

```bash
# In Claude Code:
/plugin install go-claude-starter@<your-marketplace>
```

Then in your Go project:

```bash
# Copy the starter config and customize:
cp $CLAUDE_PLUGIN_ROOT/templates/CLAUDE.md.template ./CLAUDE.md
cp $CLAUDE_PLUGIN_ROOT/templates/.tdd/tdd-config.json ./.tdd/
```

See [`docs/ADOPTION_GUIDE.md`](docs/ADOPTION_GUIDE.md) for the full
walkthrough. For a Go monorepo, see
[`docs/MONOREPO_ADOPTION_GUIDE.md`](docs/MONOREPO_ADOPTION_GUIDE.md).

## How it stays trustworthy

This pack enforces security and governance — so the pack itself must
clear that bar. The repo:

- Runs its own hooks against its own commits.
- Signs every release with [Sigstore](https://www.sigstore.dev/) keyless.
- Publishes [SLSA Build L3](https://slsa.dev/) provenance for all artifacts.
- Generates SBOMs in both SPDX and CycloneDX formats.
- Holds an OpenSSF Scorecard score of N.M (see badge above).
- Cites the real CVE/incident behind every deny rule (see hook
  source comments).

## Documentation

- [`docs/ADOPTION_GUIDE.md`](docs/ADOPTION_GUIDE.md) — Single-project install
- [`docs/MONOREPO_ADOPTION_GUIDE.md`](docs/MONOREPO_ADOPTION_GUIDE.md) — Multi-service monorepos
- [`docs/AI_DEVELOPER_GUIDE.md`](docs/AI_DEVELOPER_GUIDE.md) — Working with the agent
- [`docs/INTEGRATION_GUIDE.md`](docs/INTEGRATION_GUIDE.md) — Plugging into existing CI

## Compatibility

- Claude Code: ≥ 2.1.89 (see [security section in CLAUDE.md](CLAUDE.md))
- Go: ≥ 1.26.2 for `go fix` modernize features
- bash, jq, git, gofmt: required
- gitleaks, goimports, golangci-lint, govulncheck: strongly recommended

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). DCO required.
AI-assisted contributions must be disclosed.

## Security

See [`SECURITY.md`](SECURITY.md). Report vulnerabilities via
[GitHub Private Vulnerability Reporting](https://github.com/<org>/<repo>/security/advisories/new).

## License

Apache-2.0. See [`LICENSE`](LICENSE).
```

Cut the original README content that's purely internal (consultant
notes, internal review history, etc.).

---

## 5. Community files — drop-in templates

### 5.1 `CONTRIBUTING.md`

```markdown
# Contributing to go-claude-starter

Thanks for considering a contribution.

## Quick links

- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md)
- [Open issues](https://github.com/<org>/<repo>/issues)
- [Discussions](https://github.com/<org>/<repo>/discussions)

## Dev setup

```bash
git clone https://github.com/<org>/<repo>
cd <repo>

# Verify required tools
for t in jq bash git gofmt go; do command -v $t || echo "$t MISSING"; done

# Run the smoke suite (verifies hooks parse and execute)
bash scripts/tdd-test-hooks.sh

# Validate every hook script parses
for f in .claude/hooks/*.sh; do bash -n "$f"; done

# Validate every JSON file parses
for f in $(find . -name '*.json' -not -path './archive/*'); do jq empty "$f"; done
```

## Branch flow

Trunk-based. `main` is the only long-lived branch. Feature work happens
on short-lived branches; PR into `main`.

## Commit messages

[Conventional Commits 1.0.0](https://www.conventionalcommits.org/):

```
<type>(<scope>): <subject>

<body>

<footer>
```

Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci`,
`build`, `perf`, `style`. Append `!` for breaking changes.

Add `Signed-off-by:` via `git commit -s` (DCO required, see below).

## DCO

We use the [Developer Certificate of Origin](https://developercertificate.org/).
Every commit must have a `Signed-off-by` trailer:

```bash
git commit -s -m "fix(hooks): handle empty CLAUDE_PROJECT_DIR"
```

This certifies you wrote the code or have the right to contribute it
under the project's license.

## AI-assisted contributions

This project welcomes AI-assisted contributions, with disclosure.

If a non-trivial portion of your contribution was generated or
substantially shaped by an AI tool (Claude, GPT, Copilot, Cursor, etc.):

1. Add an `Assisted-by:` trailer to your commits, e.g.:
   `Assisted-by: Claude Sonnet 4.5`
2. Include in the PR description a one-paragraph note on what the AI
   produced and what you reviewed/modified.
3. By submitting, you certify that you understand every line of the
   contribution and accept responsibility for it under our license.
4. PRs that look LLM-output without disclosure may be closed without
   review.

Trivial AI assistance (autocomplete, single-line suggestions, error-
message rewrites) does not require disclosure.

We require this both because we use AI internally and because we want
the contribution chain to remain audit-trail-friendly.

## Pull request checklist

- [ ] Commits signed (DCO `Signed-off-by`)
- [ ] AI assistance disclosed (if applicable)
- [ ] `bash scripts/tdd-test-hooks.sh` passes locally
- [ ] If you added a hook deny pattern, you cited the real CVE/incident
  in the comment
- [ ] If you changed a hook contract, the JSON shape is documented
- [ ] CHANGELOG entry under `## [Unreleased]`
- [ ] Docs updated for user-visible changes

## Adding a deny pattern to a hook

Pattern: every deny rule cites its motivating incident. Example from
`guard-dangerous-bash.sh`:

```bash
# Block --no-verify on git commit (issue #40117).
case "$cmd" in
  *git\ commit*--no-verify*) deny "git commit --no-verify bypasses ..." ;;
esac
```

Without an incident citation, advisory text rots into noise. With one,
future maintainers know why the rule exists.

## Reporting a security issue

Do **not** open a public issue. See [SECURITY.md](SECURITY.md).
```

### 5.2 `CODE_OF_CONDUCT.md`

```markdown
# Contributor Covenant Code of Conduct

[... use Contributor Covenant 2.1 verbatim from
https://www.contributor-covenant.org/version/2/1/code_of_conduct/code_of_conduct.md ...]

## Enforcement

Instances of abusive, harassing, or otherwise unacceptable behavior may
be reported to the community leaders responsible for enforcement at
**conduct@<your-domain>**. All complaints will be reviewed and
investigated promptly and fairly.

The enforcement team:

- Anton Dvornikov (project lead)
- [Second enforcer needed before launch]

All community leaders are obligated to respect the privacy and security
of the reporter of any incident.
```

Required: name a real enforcement contact and ≥2 enforcers. A CoC
without an actual enforcer is not credible.

### 5.3 `SECURITY.md`

```markdown
# Security Policy

This project ships safety hooks for Claude Code. Vulnerabilities here
can affect every adopter's repository. We take reports seriously.

## Supported versions

| Version | Supported          |
|---------|--------------------|
| 1.9.x   | :white_check_mark: |
| 1.8.x   | :white_check_mark: (security fixes only) |
| < 1.8   | :x:                |

## Reporting a vulnerability

**Do not open a public issue.**

Use [GitHub Private Vulnerability Reporting](https://github.com/<org>/<repo>/security/advisories/new).

Include:

- Affected version (`git rev-parse HEAD` of the repo where you saw it)
- Reproduction steps (commands, JSON inputs to hooks, exact output)
- Affected hook or component
- Your assessment of severity (P0/P1/P2/P3) and reasoning
- Any proof-of-concept

## Disclosure timeline

| Stage | Target |
|---|---|
| Acknowledge receipt | within 72h |
| Severity triage + ETA shared | within 14d |
| Fix released | within 90d for P0/P1 |
| Public disclosure (CVE if applicable) | coordinated with reporter |

If we cannot reach the 90-day target, we'll explain why and propose a
revised timeline.

## Out of scope

- Bypasses that require root access on the user's machine
- Issues in upstream tools (Claude Code, codex, jq, gitleaks)
- Theoretical bypasses that require multiple combined permission failures
  AND administrator privileges
- Social engineering of project maintainers

## Vulnerability disclosure history

| ID | Date | Severity | Component | Fixed in |
|---|---|---|---|---|
| (none yet) | | | | |
```

### 5.4 `.github/CODEOWNERS`

```
# .github/CODEOWNERS
# All files default to the maintainers team.
* @<your-org>/maintainers

# Hooks are security-critical; require security-team review.
/.claude/hooks/         @<your-org>/security
/scripts/tdd/           @<your-org>/security

# Documentation can be reviewed by docs team.
/docs/                  @<your-org>/docs

# Governance files require maintainer + security review.
/CODE_OF_CONDUCT.md     @<your-org>/maintainers
/SECURITY.md            @<your-org>/maintainers @<your-org>/security
/.github/               @<your-org>/maintainers
```

If you don't have GitHub teams yet, use individual handles:
`* @your-username @co-maintainer`.

### 5.5 Issue templates

Create `.github/ISSUE_TEMPLATE/config.yml`:

```yaml
blank_issues_enabled: false
contact_links:
  - name: Question / discussion
    url: https://github.com/<org>/<repo>/discussions
    about: Ask questions in Discussions, not issues.
  - name: Security issue
    url: https://github.com/<org>/<repo>/security/advisories/new
    about: Report security issues privately via GitHub PVR.
```

`.github/ISSUE_TEMPLATE/bug_report.yml`:

```yaml
name: Bug report
description: A reproducible defect in the pack
title: "[bug] "
labels: [bug, triage]
body:
  - type: input
    id: pack_version
    attributes:
      label: Pack version
      placeholder: v1.9.3 or commit SHA
    validations:
      required: true
  - type: input
    id: claude_code_version
    attributes:
      label: Claude Code version
      placeholder: 2.1.89
    validations:
      required: true
  - type: input
    id: os
    attributes:
      label: OS
      placeholder: macOS 14.5, Ubuntu 22.04, etc.
    validations:
      required: true
  - type: textarea
    id: repro
    attributes:
      label: Reproduction
      description: Smallest commands and JSON inputs that reproduce the bug.
      render: bash
    validations:
      required: true
  - type: textarea
    id: expected
    attributes:
      label: Expected behavior
    validations:
      required: true
  - type: textarea
    id: actual
    attributes:
      label: Actual behavior
      description: Include hook output, exit codes, audit-log entries.
    validations:
      required: true
  - type: textarea
    id: logs
    attributes:
      label: Relevant logs
      description: Output of `tail .tdd/audit/audit.jsonl` if relevant.
      render: text
```

`.github/ISSUE_TEMPLATE/feature_request.yml`:

```yaml
name: Feature request
description: Propose a new feature or change
title: "[feature] "
labels: [enhancement, triage]
body:
  - type: textarea
    id: problem
    attributes:
      label: Problem
      description: What can't you do today?
    validations:
      required: true
  - type: textarea
    id: proposal
    attributes:
      label: Proposed solution
    validations:
      required: true
  - type: textarea
    id: alternatives
    attributes:
      label: Alternatives considered
  - type: dropdown
    id: scope
    attributes:
      label: Where would this live?
      options:
        - Hook (.claude/hooks/)
        - Skill (.claude/skills/)
        - Agent (.claude/agents/)
        - Rule (.claude/rules/)
        - Runner script (scripts/tdd/)
        - Documentation
        - Other
    validations:
      required: true
```

### 5.6 PR template

`.github/pull_request_template.md`:

```markdown
## What this PR changes

<!-- 1-2 sentences. The "why" matters more than the "what". -->

## Linked issue

Fixes #

## Type

- [ ] Bug fix (non-breaking)
- [ ] Feature (non-breaking, minor bump)
- [ ] Breaking change (major bump)
- [ ] New deny pattern (patch bump)
- [ ] Docs only
- [ ] CI / tooling only

## Checklist

- [ ] Commits signed (`git commit -s` for DCO)
- [ ] AI-assisted disclosure if applicable (see CONTRIBUTING.md §AI)
- [ ] `bash scripts/tdd-test-hooks.sh` passes
- [ ] If a hook contract changed, the JSON shape is documented
- [ ] If a deny pattern was added, the comment cites the CVE/incident
- [ ] CHANGELOG entry under `## [Unreleased]`
- [ ] Docs updated for user-visible changes

## Test evidence

<!-- Paste smoke output, command output, or "ran `bash scripts/tdd-test-hooks.sh`, 559 passed, 0 failed" -->
```

---

## 6. Backfill the changelog and tag history

The repo is at v1.9.3 in commit messages but only tagged through v1.3.1.
Two paths:

### 6.1 Path A — Backfill tags (recommended)

```bash
# For each missing version, find the commit that shipped it and tag.
git log --grep='feat(v1.4' --oneline
# v1.4.0 → commit SHA
git tag -a v1.4.0 <sha> -m "v1.4.0: ..."

# Repeat for v1.4.1 ... v1.9.3.

# Or programmatically — find each "feat(vX.Y.Z)" commit and tag it:
git log --oneline | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -u | while read v; do
  sha=$(git log --grep="$v" --format='%H' | tail -1)
  [ -n "$sha" ] && git tag -a "$v" "$sha" -m "$v"
done

# Push tags only after everything else is in place.
# git push origin --tags
```

Sign these tags with `gitsign` if you have it set up; otherwise plain
tags are acceptable for backfill (document this in CHANGELOG.md).

### 6.2 Path B — Public history starts at v1.9.3

Acceptable if backfill is too much work. Document in CHANGELOG.md:

```markdown
> History prior to v1.9.3 was developed in a private repository and
> is summarized here. Detailed commit-level history before v1.9.3 may
> not be reachable from the public Git history.
```

### 6.3 CHANGELOG.md (Keep a Changelog format)

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- (next changes go here)

## [1.9.3] - 2026-05-15

### Fixed
- Schema: `required` array now enumerates every key in `properties` for
  the review-completion schema, satisfying OpenAI Responses API strict
  structured-output requirement. Without this, the runner's first Codex
  call was rejected with `invalid_json_schema`.

## [1.9.2] - 2026-05-13

### Fixed
- Schema: added `additionalProperties: false` at every object level in
  the review-completion schema, satisfying OpenAI's response_format API
  contract.

## [1.9.1] - 2026-05-13

### Added
- Round cap: `/second-opinion` is now hard-limited to 4 review rounds
  per cycle per review_type. Configured via
  `second_opinion.no_discretion.max_review_rounds_per_cycle`.

### Fixed
- `scripts/tdd/run-second-opinion.sh` now resolves project root from
  `CLAUDE_PROJECT_DIR` or `pwd` before falling back to script-relative.

## [1.9.0] - 2026-05-13

### Added
- Pack no-discretion `/second-opinion` enforcement.
- Six new hooks: plan/test/production triggers, Bash pre-trigger,
  PostToolUse backstop, Stop gate.
- Runner: `scripts/tdd/run-second-opinion.sh` (single Codex caller).
- Skill is now invoke-only (`disable-model-invocation: true`).
- Schema-extended typed exception for review completions.
- AST validator subcommand for review-completion schema check.

## [1.8.0]
[Backfilled summary or "see git history"]

## [1.7.0]
[...]

## Earlier versions
History prior to public release was developed privately. Earlier tags
may not be reachable from the public history.
```

---

## 7. CI/CD workflows for public release

### 7.1 Replace `.gitlab-ci.yml` with GitHub Actions

The repo has `.gitlab-ci.yml`. Translate it to `.github/workflows/`.

### 7.2 `.github/workflows/ci.yml`

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<sha>
      - name: Validate JSON files
        run: for f in $(find . -name '*.json' -not -path './archive/*'); do jq empty "$f"; done
      - name: Validate hook scripts parse
        run: for f in .claude/hooks/*.sh scripts/tdd/*.sh; do bash -n "$f"; done
      - name: Shellcheck
        uses: ludeeus/action-shellcheck@<sha>

  smoke:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<sha>
      - name: Install jq
        run: sudo apt-get update && sudo apt-get install -y jq
      - name: Run hook smoke suite
        run: bash scripts/tdd-test-hooks.sh

  hook-deny-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<sha>
      - name: guard-dangerous-bash.sh deny cases
        run: |
          HOOK=.claude/hooks/guard-dangerous-bash.sh
          for cmd in "git commit --no-verify" "rm -rf /" "git push --force"; do
            d=$(echo "{\"tool_input\":{\"command\":\"$cmd\"}}" | bash "$HOOK" | jq -r '.hookSpecificOutput.permissionDecision')
            [ "$d" = "deny" ] || { echo "expected deny for: $cmd, got: $d"; exit 1; }
          done
      - name: scan-for-secrets.sh deny cases
        run: |
          HOOK=.claude/hooks/scan-for-secrets.sh
          d=$(echo '{"tool_name":"Write","tool_input":{"content":"AKIAIOSFODNN7EXAMPLE","file_path":"x"}}' | bash "$HOOK" | jq -r '.hookSpecificOutput.permissionDecision')
          [ "$d" = "deny" ] || exit 1
```

### 7.3 `.github/workflows/codeql.yml`

Use the GitHub default starter:

```yaml
name: CodeQL
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  schedule:
    - cron: '0 0 * * 1'

permissions:
  actions: read
  contents: read
  security-events: write

jobs:
  analyze:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        language: [ 'go', 'javascript' ]   # remove unused languages
    steps:
      - uses: actions/checkout@<sha>
      - uses: github/codeql-action/init@<sha>
        with:
          languages: ${{ matrix.language }}
      - uses: github/codeql-action/analyze@<sha>
```

### 7.4 `.github/workflows/scorecard.yml`

```yaml
name: OpenSSF Scorecard
on:
  branch_protection_rule:
  schedule:
    - cron: '20 7 * * 2'
  push:
    branches: [main]

permissions: read-all

jobs:
  analysis:
    runs-on: ubuntu-latest
    permissions:
      security-events: write
      id-token: write
      contents: read
      actions: read
    steps:
      - uses: actions/checkout@<sha>
        with:
          persist-credentials: false
      - uses: ossf/scorecard-action@<sha>
        with:
          results_file: results.sarif
          results_format: sarif
          publish_results: true
      - uses: actions/upload-artifact@<sha>
        with:
          name: SARIF
          path: results.sarif
      - uses: github/codeql-action/upload-sarif@<sha>
        with:
          sarif_file: results.sarif
```

### 7.5 `.github/workflows/dependency-review.yml`

```yaml
name: Dependency Review
on: [pull_request]
permissions:
  contents: read
jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<sha>
      - uses: actions/dependency-review-action@<sha>
        with:
          fail-on-severity: moderate
          deny-licenses: GPL-3.0, AGPL-3.0
```

### 7.6 `.github/workflows/release.yml`

```yaml
name: Release
on:
  push:
    tags: [ 'v*.*.*' ]

permissions:
  contents: write
  id-token: write
  attestations: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<sha>
        with:
          fetch-depth: 0

      - name: Build artifact (pack tarball)
        run: |
          tar --exclude='./.git' --exclude='./archive' \
              -czf go-claude-starter-${GITHUB_REF_NAME}.tar.gz .
          sha256sum go-claude-starter-*.tar.gz > checksums.txt

      - name: Generate SBOM (SPDX)
        uses: anchore/sbom-action@<sha>
        with:
          format: spdx-json
          output-file: sbom.spdx.json

      - name: Generate SBOM (CycloneDX)
        uses: anchore/sbom-action@<sha>
        with:
          format: cyclonedx-json
          output-file: sbom.cdx.json

      - name: Install cosign
        uses: sigstore/cosign-installer@<sha>

      - name: Sign artifact (keyless)
        run: |
          cosign sign-blob --yes \
            --output-signature go-claude-starter-${GITHUB_REF_NAME}.sig \
            --output-certificate go-claude-starter-${GITHUB_REF_NAME}.pem \
            go-claude-starter-${GITHUB_REF_NAME}.tar.gz

      - name: Attest build provenance (SLSA)
        uses: actions/attest-build-provenance@<sha>
        with:
          subject-path: 'go-claude-starter-*.tar.gz'

      - name: Create GitHub Release
        uses: softprops/action-gh-release@<sha>
        with:
          generate_release_notes: true
          files: |
            go-claude-starter-*.tar.gz
            *.sig
            *.pem
            sbom.spdx.json
            sbom.cdx.json
            checksums.txt
```

### 7.7 `.github/dependabot.yml`

```yaml
version: 2
updates:
  - package-ecosystem: gomod
    directory: "/"
    schedule:
      interval: weekly
    groups:
      go-deps:
        patterns: ["*"]
  - package-ecosystem: github-actions
    directory: "/"
    schedule:
      interval: weekly
    groups:
      actions:
        patterns: ["*"]
```

---

## 8. Repository settings on the new GitHub repo

After pushing, configure in the GitHub UI:

### 8.1 General

- Default branch: `main`
- Auto-delete head branches: on
- Allow squash merging: on (default)
- Allow merge commits: off
- Allow rebase merging: off
- Allow auto-merge: optional
- Suggest updating pull request branches: on

### 8.2 Code security and analysis

- Dependency graph: on
- Dependabot alerts: on
- Dependabot security updates: on
- Code scanning (CodeQL): on
- Secret scanning: on
- Push protection: on
- **Private vulnerability reporting: on**

### 8.3 Rulesets (Settings → Rules → Rulesets)

Create one ruleset on `main`:

- Target branches: `main`
- Restrictions:
  - Restrict creations: off
  - Restrict updates: on (only via PR)
  - Restrict deletions: on
  - Block force pushes: on
- Branch rules:
  - Require pull request before merging: on
    - Required approvals: 1 (raise to 2 once you have a co-maintainer)
    - Dismiss stale approvals: on
    - Require Code Owner review: on
    - Require approval of most recent reviewable push: on
  - Require status checks to pass: on
    - Add: CI / lint, CI / smoke, CI / hook-deny-tests, CodeQL,
      Scorecard, Dependency Review
  - Require conversation resolution: on
  - Require signed commits: on
  - Require linear history: on
- Bypass list: **empty** (admins follow the same rules)

Create another ruleset on tags `v*`:

- Target tags: `v*`
- Restrict creations: on (only release workflow can push tags)
- Require signed tags: on

### 8.4 Actions permissions

- Workflow permissions: Read repository contents permission (default
  `GITHUB_TOKEN` is read-only)
- Allow GitHub Actions to create and approve pull requests: off
- Allowed actions: Allow select actions, with explicit allowlist of
  `actions/*`, `github/*`, `sigstore/*`, `anchore/*`, `ossf/*`,
  `softprops/*`, `golangci/*`, `ludeeus/*` pinned to commit SHAs.

### 8.5 About section

- Description: "A Claude Code plugin shipping safety hooks, reviewer
  agents, TDD enforcement, and second-opinion review for Go projects."
- Website: documentation URL or homepage
- Topics: `go`, `claude-code`, `claude-code-plugin`, `security`,
  `tdd`, `developer-tools`, `code-review`, `cli`, `governance`

### 8.6 Discussions

Enable. Categories: Q&A, Ideas, Show & Tell, Polls, Adoption Stories.

---

## 9. Migration steps from GitLab to GitHub

### 9.1 Create the GitHub repo

In the GitHub UI: create a new public repo named `go-claude-starter`
under your org. Do **not** initialize with README/LICENSE/gitignore
(you have your own).

### 9.2 Push from local

```bash
cd ~/go-projects-claude-starter

# Confirm current remotes
git remote -v
# origin = ssh://git@gt.devopspoint.io:2244/...

# Add github as a new remote
git remote add github git@github.com:<your-org>/go-claude-starter.git

# Push main branch
git push github main

# Push tags AFTER backfill is done
git push github --tags

# Optionally rename remotes:
git remote rename origin gitlab
git remote rename github origin
```

### 9.3 Verify on GitHub

- Repo Insights → Community Standards → all green ticks
- Settings → Code security: all features enabled
- Settings → Rules → ruleset on `main` active
- Actions → first workflow runs succeed

### 9.4 Update the marketplace listing

If the pack is published to a Claude Code marketplace, update the
marketplace's `marketplace.json` to point to the new GitHub URL:

```json
{
  "name": "go-claude-starter",
  "version": "1.9.3",
  "description": "...",
  "source": "github:<your-org>/go-claude-starter",
  "tag": "v1.9.3"
}
```

---

## 10. Trust posture (the high bar — see `open-source-launch-guide-universal.md` §17.1)

This pack must demonstrably eat its own dog food. Walk through the
12-point list:

| # | Expectation | Status today | Action |
|---|---|---|---|
| 1 | Eat your own dog food (repo runs its own enforcement) | partial — hooks installed | Document in README |
| 2 | Reproducible builds + signed releases + SLSA L3 + SBOM | none | §7.6 release.yml does signed + SLSA + SBOM. Reproducible builds for the pack itself are trivial since it's mostly bash/JSON/markdown. |
| 3 | Signed commits via gitsign / hardware-key GPG | none today | Set up gitsign before v1.9.4. Enable in ruleset. |
| 4 | OpenSSF Scorecard ≥7.0, badge in README | unknown | Set up §7.4 scorecard.yml. Aim for 7.0 within first week. |
| 5 | OpenSSF Best Practices passing badge | not applied | https://www.bestpractices.dev/en/projects/new — apply for passing tier (achievable in ~2 hours). |
| 6 | CVE assignment via GitHub as CNA | not registered | Apply at https://github.com/orgs/<org>/security/advisories — eligibility opens after first repo with security-advisories enabled |
| 7 | Independent security audit | none | Optional first year; consider for v2.0. |
| 8 | Cite incidents on every deny rule | partial | The existing hooks already do this (see `guard-dangerous-bash.sh` header). Make this an enforced PR-review rule. |
| 9 | Transparent governance: maintainer list with Sigstore IDs | none | Add MAINTAINERS.md with handles + Sigstore identities. |
| 10 | No telemetry by default | already true | Document in README + privacy section. |
| 11 | Permission minimization | already true (hooks ask for nothing extra) | README justifies the hook permissions. |
| 12 | AI-assisted contribution policy with teeth | none today | §5.1 CONTRIBUTING.md adds it. |

---

## 11. Phased rollout

Don't try to ship all of this at once. Suggested phases:

### Phase 1 — Pre-public scrub (1 day)

- §1 secret audit + history snapshot
- §2 LICENSE + NOTICE
- §5 community files (CONTRIBUTING, COC, SECURITY)
- §6 CHANGELOG (Unreleased + last 3 versions)

### Phase 2 — Public push (1 day)

- §9 create GitHub repo, push main + tags (existing tags v1.1–v1.3 only
  if backfill not done)
- §8 repository settings (rulesets, security features, About, topics)
- §4 README refresh
- Community Standards score green

### Phase 3 — CI/CD baseline (2-3 days)

- §7 all five workflows (ci, codeql, scorecard, dep-review, release)
- §7.7 Dependabot
- Tag a no-op `v1.9.4` to verify release.yml end-to-end (also fixes
  the smoke-test issue from devopspoint feedback if you tackle it now)
- Apply for OpenSSF Best Practices passing tier

### Phase 4 — Trust posture hardening (1 week)

- §10 gitsign on all maintainers' machines
- §10 MAINTAINERS.md with Sigstore identities
- §10 Apply for CVE assignment via GitHub CNA
- Aim for OpenSSF Scorecard ≥7.0
- Reproducible build of the pack tarball — verify with `cosign verify-blob`

### Phase 5 — Launch (1 day, ~2 weeks after Phase 1 starts)

- §6.1 Tag-backfill if you went Path A
- README badges populated (Scorecard score, Best Practices, license)
- Show HN draft + blog post drafted
- 3–5 early users primed
- Submit to `awesome-claude-code` and `awesome-go` if applicable
- Flip the visibility bit; post Show HN

### Phase 6 — Sustain (ongoing)

- Triage new issues within 24h
- Quarterly Scorecard audit
- Quarterly disposition-matrix review (any silently-accepted P0/P1?)
- Apply for OpenSSF Best Practices silver tier within 6 months

---

## 12. Things specific to this pack to call out in the README

- **Eat your own dog food.** The repo's own commits go through the
  same hooks, audit log, and second-opinion ceremony the pack ships.
  Show the live audit log SHA chain as proof.
- **Incident-driven defense.** Every deny rule cites a real CVE or
  incident in the source comment. Link to a public deny-rationale doc.
- **Not security theater.** The pack runs deterministic structural
  checks; it doesn't trust the model's promises. Specifically: the
  second-opinion skill has `disable-model-invocation: true` so the
  model cannot invoke its own review; only the runner can. Cite this
  in the README to highlight the design discipline.
- **Compatibility floor honesty.** Claude Code ≥ 2.1.89 is required
  because earlier versions silently treat hook `permissionDecision:
  "defer"` as `allow` in non-interactive mode (CVE-2025-59536 +
  CVE-2026-21852 disclosed Feb 2026). README must disclose this.
- **Limitations honesty.** v1.9.4 backlog (smoke-test host-config
  isolation, end-to-end runner Codex test) is open work; document it.

---

## 13. Open questions for you to decide

Before launch, decide explicitly:

1. **Org name on GitHub?** `prilive-company`? Personal `tohovsky`?
   New `claude-code-plugins`?
2. **Marketplace home?** Anthropic official marketplace, your own
   marketplace, both?
3. **DCO or CLA?** This guide assumes DCO. Switch only if you have a
   specific corporate-patent reason.
4. **AI-assisted policy stance?** This guide assumes "disclose."
   Switch to "ban" if you want stricter posture.
5. **Co-maintainer?** Required to make the CoC enforcement credible
   (need ≥2 enforcers). Find one before launch.
6. **Domain for `conduct@` and `security@` emails?** Use a real domain;
   personal Gmail signals amateur.
7. **Backfill tags v1.4–v1.9.3, or only document them in CHANGELOG?**
   Backfill is preferred; document path is acceptable.

---

## 14. Final-day checklist

Print and walk through on launch day. From `open-source-launch-guide-universal.md` §18,
adapted for this pack:

### Pre-flight

- [ ] gitleaks clean on full history
- [ ] All leaked secrets rotated
- [ ] Pre-public bundle stored offline
- [ ] Decision on §13 questions documented

### Files at root

- [ ] `LICENSE` (Apache-2.0)
- [ ] `NOTICE`
- [ ] `README.md` refreshed for public audience
- [ ] `CONTRIBUTING.md` with DCO + AI policy
- [ ] `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1, ≥2 enforcers named)
- [ ] `SECURITY.md` with PVR link, supported versions, 90-day timeline
- [ ] `CHANGELOG.md` (Unreleased + last 3 versions minimum)
- [ ] `MAINTAINERS.md` with handles + Sigstore identities
- [ ] `.github/CODEOWNERS`
- [ ] `.github/ISSUE_TEMPLATE/` (config + bug + feature)
- [ ] `.github/pull_request_template.md`
- [ ] `.github/dependabot.yml`

### Workflows

- [ ] `.github/workflows/ci.yml`
- [ ] `.github/workflows/codeql.yml`
- [ ] `.github/workflows/scorecard.yml`
- [ ] `.github/workflows/dependency-review.yml`
- [ ] `.github/workflows/release.yml`
- [ ] `.gitlab-ci.yml` removed

### Repository settings

- [ ] Default branch `main`, auto-delete head on merge
- [ ] Ruleset on `main` (PR + ≥1 approval + signed commits + status
      checks + linear history + no force-push, **no admin bypass**)
- [ ] Ruleset on `v*` tags (signed tags, restricted creations)
- [ ] Code security: Dependabot, CodeQL, secret scanning, push
      protection, **Private Vulnerability Reporting**: all on
- [ ] Discussions: on
- [ ] Wiki: off
- [ ] About: description + topics

### Trust posture

- [ ] gitsign installed on every maintainer's machine
- [ ] OpenSSF Scorecard score ≥7.0 (badge in README)
- [ ] OpenSSF Best Practices passing badge applied for
- [ ] First release tag (`v1.9.4` or `v1.10.0`) signed end-to-end
      (cosign + SLSA provenance + SBOM)

### Discoverability

- [ ] Topics set
- [ ] Social preview image uploaded
- [ ] Submitted to `awesome-claude-code` and `awesome-go`
- [ ] Marketplace listing updated to point at GitHub repo

### Launch comms

- [ ] Show HN draft ready
- [ ] Blog post / launch post ready
- [ ] 3–5 early users primed to comment
- [ ] Maintainer team available for first 72 hours

---

## 15. After launch

- Triage every issue and PR within 24h.
- Ship a patch release within 7 days for any critical bug.
- Monthly: review Scorecard score, address regressions.
- Quarterly: review disposition matrix (any silently-accepted P0/P1?).
- 6 months: apply for OpenSSF Best Practices silver tier.
- 12 months: consider an independent security audit before v2.0.

---

## 16. References specific to this pack

- `open-source-launch-guide-universal.md` — generic 2026 OSS opening checklist
- `MAINTAINING.md` — internal release workflow (already exists)
- `docs/ADOPTION_GUIDE.md` — how adopters install this pack
- `docs/MONOREPO_ADOPTION_GUIDE.md` — multi-service monorepo pattern
- `docs/AI_DEVELOPER_GUIDE.md` — agent-side workflow documentation
- `docs/INTEGRATION_GUIDE.md` — CI/CD integration
- `CLAUDE.md` — pack maintainer instructions

---

End of guide.
