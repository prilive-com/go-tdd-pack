# Open Source Guide

How to open a private project to public open source on GitHub in 2026.
Generic checklist + reasoning. Use alongside the project-specific
release guide when shipping a particular project.

**Audience:** Maintainers preparing to publish a private project.
**Status:** Canonical reference. Updates land here when practices change.
**Calibrated to:** 2026 tooling and conventions (Sigstore keyless,
GitHub Artifact Attestations, repository rulesets, Conventional Commits,
DCO, AI-assisted contribution policies).

---

## How to use this guide

Read **Sections 1–3** before flipping the visibility bit (these are
irreversible-or-painful-to-undo steps). Use **Section 18** as a final
go/no-go checklist on launch day. The middle sections are reference for
specific topics.

If your project is in a particular category (security tool, plugin/
extension, library, CLI app, web service), see **Section 17** for the
extra trust bar that category needs to clear.

---

## 1. Pre-publication checklist (do these BEFORE flipping visibility)

These are the hard-to-undo steps. Get them right once.

### 1.1 Ownership & employer sign-off

- [ ] Confirm who owns the copyright. If contributors were employees,
      get a written release. Most employment IP clauses cover code
      written on company time/equipment by default.
- [ ] If the project was funded by a grant or contract, check the grant/
      contract for IP terms. Government-funded work may have specific
      attribution or licensing requirements.
- [ ] If the codebase incorporates third-party code (vendored deps,
      copy-pasted snippets, AI-generated code), audit for compatible
      licensing. Apache-2.0 ↔ MIT ↔ BSD compose freely; (L)GPL imposes
      copyleft; SSPL/BSL/PolyForm are not OSI-approved.

### 1.2 Secret scrub on full history

Removing a secret from the latest commit does **nothing** — Git keeps it.
Treat any secret that ever existed in the history as compromised and
**rotate it** before publishing.

```bash
# Audit the full history. Run all three; they catch different shapes.
gitleaks detect --source . --log-level info
trufflehog git file://. --json | jq .
git log -p --all | grep -E '(AKIA|ghp_|sk-|xox[abprs]-|-----BEGIN)' | head

# If any secret was ever committed, rewrite history.
# git filter-repo is the modern replacement for git filter-branch.
pip install git-filter-repo
git filter-repo --invert-paths --path path/to/secret-file
git filter-repo --replace-text replacements.txt   # for inline secrets

# Then nuke reflogs and garbage-collect:
git reflog expire --expire=now --all
git gc --prune=now --aggressive

# Force-push to a fresh remote — never to the public repo.
```

- [ ] Run `gitleaks` (or `trufflehog`, or both).
- [ ] Rewrite history with `git filter-repo` if anything is found.
- [ ] **Rotate every leaked secret** (assume the secret is compromised).
- [ ] Enable GitHub push protection on the public repo before the first
      push. Free for public repos as of 2026.

### 1.3 Contributor identity sweep

```bash
# List every author in history.
git log --format='%an <%ae>' | sort -u
```

- [ ] Search for personal/anonymous emails contributors may not want
      public.
- [ ] Offer affected contributors a rewrite (DMCA-safe and respectful)
      OR explicit "OK to publish" sign-off.
- [ ] Consider rewriting bot-account commits to a sensible canonical
      author (e.g., merge-bot pollution).

### 1.4 Dependency licensing audit

The 2026 OSSRA report notes **68% of commercial codebases have license
conflicts**. Check before public exposure invites scrutiny.

- [ ] Generate an SBOM (`syft scan dir:. -o spdx-json` and
      `syft scan dir:. -o cyclonedx-json`).
- [ ] Check transitive licenses against your chosen project license
      (`go-licenses check ./...` for Go, `pip-licenses` for Python,
      `license-checker` for Node, etc.).
- [ ] Document any deps under copyleft/proprietary licenses; either
      remove them or comply.

### 1.5 Export controls (US-origin code)

For US-origin crypto/security tooling, check whether ECCN classification
applies. Most pure-software open-source projects fall under license
exception **TSU** (Technology and Software – Unrestricted) — but you
must still publish a notice. See **§742.15(b)** of the EAR.

- [ ] Add a `NOTICE` or paragraph in README naming the export
      classification, if applicable.
- [ ] If unsure, ask a lawyer; export-control violations carry real
      penalties.

### 1.6 Pre-launch artifact archive

Before any rewrite or rename, snapshot the pre-public state:

```bash
git bundle create pre-public-snapshot.bundle --all
sha256sum pre-public-snapshot.bundle > pre-public-snapshot.sha256
```

Store offline. If anything goes wrong with history rewrite, you have
the original.

---

## 2. Required community files

The list below maps to GitHub's **community profile** checklist (visible
under **Insights → Community Standards** on every public repo). A
complete profile unlocks UI affordances and signals seriousness.

| File | Required? | 2026 minimum content |
|---|---|---|
| `LICENSE` | Yes | SPDX-named file at root; GitHub auto-detects via Licensee |
| `README.md` | Yes | What/why/install/quickstart/links + badges row |
| `CONTRIBUTING.md` | Yes | Dev setup, test command, branch flow, DCO/CLA stance, **AI-assisted contribution policy** |
| `CODE_OF_CONDUCT.md` | Yes | Contributor Covenant 2.1 |
| `SECURITY.md` | Yes for security-relevant projects | Supported versions, how to report privately, expected timeline, scope |
| `.github/CODEOWNERS` | Yes | Triggers required reviewers; place in `.github/` |
| `SUPPORT.md` | Optional | Where to ask questions (Discussions, Discord, etc.) |
| `.github/FUNDING.yml` | Optional | GitHub Sponsors, Open Collective links |
| `GOVERNANCE.md` | Optional initially | Required once >1 maintainer org or you join a foundation |
| `CHANGELOG.md` | Yes | Keep-a-Changelog format |

### 2.1 LICENSE

Pick from **§8 (license selection)**. Place at repo root. SPDX file
identifier on top line of the license file is helpful for tooling.

### 2.2 README.md

Modern README structure:

1. **Title + 1-line description** (matches the GitHub About).
2. **Badges row** (build, latest release, OpenSSF Scorecard,
   OpenSSF Best Practices, license, downloads). 4–6 max.
3. **Hero section** — what this is, why it exists. 2–3 sentences.
4. **Quickstart** — one-command install + 30-second working example.
5. **Documentation** — link to docs site or `docs/` directory.
6. **Contributing** — link to CONTRIBUTING.md.
7. **Security** — link to SECURITY.md.
8. **License** — name and link.
9. **Acknowledgments** — credit prior art if relevant.

Keep the README **scannable**. The first screen (the part visible
without scrolling) decides whether someone tries it. Don't bury the
quickstart under a feature list.

### 2.3 CONTRIBUTING.md

Must answer:

- How to set up the dev environment.
- How to run tests.
- Branch flow (trunk-based? GitFlow? feature branches?).
- Commit message convention (Conventional Commits is the 2026 default).
- DCO or CLA stance.
- **AI-assisted contribution policy** (new in 2026 — see §16).
- How to propose a non-trivial change (issue first? RFC?).
- Maintainer review SLA.

### 2.4 CODE_OF_CONDUCT.md

Use **Contributor Covenant 2.1** verbatim. Customize only the
"Enforcement" section: name an enforcement contact email and ≥2 named
enforcers. A CoC without an actual enforcer is not credible.

### 2.5 SECURITY.md

Must answer five questions:

1. **What versions are supported?** (Major.Minor matrix.)
2. **How do I report privately?** (GitHub Private Vulnerability Reporting
   is the default in 2026 — enable it in repo settings, then link.)
3. **What should I include?** (Repro, affected version, environment.)
4. **What can I expect after?** (Acknowledgement timeline, fix timeline,
   disclosure timeline. 90-day disclosure is industry standard.)
5. **What's out of scope?** (E.g., social engineering, DoS, third-party
   dependencies — list explicitly.)

### 2.6 CODEOWNERS

```
# .github/CODEOWNERS
* @org/maintainers
/security/   @org/security-team
/.github/    @org/maintainers
```

Triggers automatic review requests. Required reviewers can be enforced
via repository ruleset.

### 2.7 CHANGELOG.md

**Keep a Changelog** format:

```markdown
# Changelog

All notable changes documented here. Format: [Keep a Changelog].
Versioning: [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- ...

## [1.2.0] - 2026-05-15

### Added
- ...

### Fixed
- ...
```

Sections: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`,
`Security`. `release-please` (Google) or `semantic-release` automates
the file from Conventional Commits.

---

## 3. Issue and PR templates

GitHub favors **YAML issue forms** over legacy markdown templates.
Forms support typed inputs, required fields, validation, auto-labels,
and auto-assignees.

### 3.1 Layout

```
.github/
├── ISSUE_TEMPLATE/
│   ├── config.yml
│   ├── bug_report.yml
│   ├── feature_request.yml
│   └── question_redirect.md    # redirects to Discussions
├── pull_request_template.md
└── PULL_REQUEST_TEMPLATE/      # alternate templates if needed
```

### 3.2 `ISSUE_TEMPLATE/config.yml`

```yaml
blank_issues_enabled: false
contact_links:
  - name: Question / discussion
    url: https://github.com/<org>/<repo>/discussions
    about: Ask questions and discuss ideas in Discussions, not issues.
  - name: Security issue
    url: https://github.com/<org>/<repo>/security/advisories/new
    about: Report security issues privately via GitHub PVR.
```

### 3.3 `bug_report.yml` (example)

```yaml
name: Bug report
description: A reproducible defect
title: "[bug] "
labels: [bug, triage]
body:
  - type: input
    id: version
    attributes:
      label: Version
      placeholder: v1.2.3
    validations:
      required: true
  - type: textarea
    id: repro
    attributes:
      label: Reproduction
      description: Smallest steps that reliably reproduce the bug.
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
    validations:
      required: true
  - type: input
    id: env
    attributes:
      label: Environment
      placeholder: macOS 14.5, go1.23, etc.
```

Keep forms short. Asking for kernel version on a typo report increases
abandonment without improving quality.

### 3.4 `pull_request_template.md`

```markdown
## What this PR changes

<!-- 1-2 sentences. The "why" matters more than the "what". -->

## Linked issue

Fixes #

## Type

- [ ] Bug fix (non-breaking)
- [ ] Feature (non-breaking)
- [ ] Breaking change
- [ ] Docs only
- [ ] CI / tooling only

## Checklist

- [ ] Tests added/updated
- [ ] Docs updated
- [ ] CHANGELOG entry under `## [Unreleased]`
- [ ] Commits signed (DCO `Signed-off-by` trailer)
- [ ] AI-assisted disclosure (if applicable, see CONTRIBUTING.md §AI)

## Test evidence

<!-- Output, screenshot, or "ran make test, all green" -->
```

---

## 4. Repository settings

**Repository rulesets** are now the recommended primary mechanism;
classic branch protection rules are legacy.

### 4.1 Day-one settings

- **Default branch:** `main`.
- **Auto-delete head branches on merge:** on.
- **Allowed merge strategies:**
  - Squash: on (default for most projects).
  - Merge commit: off unless you need them.
  - Rebase: off unless maintainers understand implications.
- **Forking:** allowed (off only if license forbids).
- **Discussions:** on.
- **Wiki:** off (use `docs/` in repo).
- **Issues:** on.
- **Projects:** on if you use them.
- **Releases:** required for tagged versions.

### 4.2 Ruleset on `main`

Create a new ruleset under **Settings → Rules → Rulesets**:

- **Require pull request before merging:** on
  - Required approvals: ≥1 (≥2 for security tools)
  - Dismiss stale approvals: on
  - Require Code Owner review: on
- **Require status checks to pass:** on
  - CI workflow
  - CodeQL
  - OpenSSF Scorecard
  - Dependency review
  - Lint
  - Secret scan
- **Require conversation resolution:** on
- **Require signed commits:** on
- **Require linear history:** on (no merge commits)
- **Block force pushes:** on
- **Block deletions:** on
- **Bypass permissions:** none (admins follow the same rules — this
  is a 2026 best practice for security-credibility)

### 4.3 Ruleset on tags (`v*`)

- Restrict who can push tags
- Require signed tags

### 4.4 GitHub Actions permissions

- **Workflow permissions:** Read-only `GITHUB_TOKEN` by default
  (Scorecard `Token-Permissions` check).
- **Allowed actions:** Allow GitHub-owned + verified-creator + a
  pinned allowlist of specific commits.
- **Fork PR workflow approval:** Require approval for first-time
  contributors.

### 4.5 Secret scanning, code scanning, Dependabot

All free for public repos in 2026. Enable in **Settings → Code security
and analysis**:

- Dependency graph: on (auto)
- Dependabot alerts: on
- Dependabot security updates: on
- Dependabot version updates: on (with `.github/dependabot.yml`)
- Code scanning (CodeQL): on
- Secret scanning: on
- Push protection: on

---

## 5. CI/CD baseline (GitHub Actions)

### 5.1 Day-one workflows

Create `.github/workflows/`:

- `ci.yml` — build + lint + unit tests on PRs and `main`
- `codeql.yml` — SAST (use the GitHub default starter)
- `scorecard.yml` — OpenSSF Scorecard, weekly + on push
- `dependency-review.yml` — license + vuln check on PRs
- `release.yml` — tag-triggered: build, sign, attest, publish

### 5.2 Hardening rules (Scorecard checks all of these)

- **Pin actions to commit SHAs**, not tags. `actions/checkout@v4` →
  `actions/checkout@b4ffde65...`. Dependabot can update pinned SHAs.
- **Minimum permissions per job.** Default to `permissions:
  contents: read`; grant write only to the job that needs it.
- **No `pull_request_target` with checkout of PR code** unless you
  fully understand the attack vector.
- **No untrusted `${{ github.event.* }}` interpolation** in shell scripts
  (script injection vector). Use env vars instead.
- **Concurrency cancels in PR workflows** (`cancel-in-progress: true`)
  but never in release/main workflows.

### 5.3 Example `ci.yml` skeleton

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
      - uses: golangci/golangci-lint-action@<sha>

  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<sha>
      - uses: actions/setup-go@<sha>
        with:
          go-version-file: go.mod
      - run: go test -race ./...

  smoke:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<sha>
      - run: bash scripts/smoke.sh
```

### 5.4 Dependabot config

```yaml
# .github/dependabot.yml
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

## 6. Security baseline

For any public project, especially a security-relevant one.

### 6.1 SECURITY.md

See §2.5. Must enable **GitHub Private Vulnerability Reporting (PVR)**
in the repo settings; SECURITY.md should link to the PVR submission URL.

### 6.2 GitHub security features (all free for public repos)

- Dependency graph + Dependabot alerts + version updates
- Secret scanning + push protection (on by default for public repos)
- Code scanning (CodeQL)
- Private Vulnerability Reporting
- Security advisories (GHSA), with optional CVE assignment via GitHub
  as a CNA

### 6.3 Disclosure ladder

Publish the timeline in SECURITY.md:

```
T+0:    Reporter submits via PVR.
T+72h:  Maintainer acknowledges receipt.
T+30d:  Severity triage, fix scoped, ETA shared.
T+90d:  Coordinated public disclosure (CVE published, advisory live,
        patch released). Earlier if exploited in the wild.
```

### 6.4 Maintainer 2FA

Required on the repo settings. Hardware keys (Yubikey) preferred.

---

## 7. Supply chain (Sigstore, SLSA, SBOM, attestations)

The 2026 stack:

### 7.1 Signing — Sigstore keyless

Use `cosign` with OIDC from GitHub Actions. No long-lived keys; identity-
bound certs from Fulcio expire in minutes; signatures recorded in Rekor
transparency log.

```yaml
# release.yml excerpt
permissions:
  id-token: write       # OIDC
  contents: write       # release upload
  attestations: write   # GitHub artifact attestations

steps:
  - uses: sigstore/cosign-installer@<sha>
  - run: |
      cosign sign-blob --yes \
        --output-signature artifact.sig \
        --output-certificate artifact.pem \
        artifact.tar.gz
```

Verifiers check **"signed by workflow X in repo Y at ref Z"**, not
"signed by key K." This is the modern attestation contract.

### 7.2 Commit signing — gitsign

Use `gitsign` (Sigstore) for keyless signed commits — no GPG-key
management, identity-bound to your OIDC provider.

```bash
brew install sigstore/tap/gitsign
git config --global commit.gpgsign true
git config --global tag.gpgsign true
git config --global gpg.x509.program gitsign
git config --global gpg.format x509
```

### 7.3 SLSA provenance

Use **GitHub Artifact Attestations** (`actions/attest-build-provenance`)
to generate SLSA in-toto provenance and store it in the Rekor
transparency log. Free for public repos.

```yaml
- uses: actions/attest-build-provenance@<sha>
  with:
    subject-path: 'dist/*.tar.gz'
```

This satisfies **SLSA Build L2** trivially. **L3** requires hosted,
hardened build platform with isolated signing — GitHub-hosted runners
+ reusable workflows can satisfy L3.

### 7.4 SBOM (Software Bill of Materials)

Generate **both** SPDX (compliance/licensing standard) and CycloneDX
(security/vulnerability-management standard) for every release:

```yaml
- uses: anchore/sbom-action@<sha>
  with:
    format: spdx-json
    output-file: sbom.spdx.json
- uses: anchore/sbom-action@<sha>
  with:
    format: cyclonedx-json
    output-file: sbom.cdx.json
```

Attach as release assets. GitHub auto-generates a basic SPDX SBOM
from your dependency graph; the manual generation gives you finer
control and additional formats.

### 7.5 Reproducible builds

Increasingly expected for security tooling. Debian 14 ("Forky") will
block packages that fail reproducibility. For Go: ensure
`-trimpath -ldflags="-buildid="` and document the build command;
verifiers can rebuild and compare hashes.

### 7.6 Trusted Publishing

GitHub's OIDC-to-registry flow eliminates long-lived API tokens:

- **PyPI**: Trusted Publisher
- **npm**: Trusted Publisher (provenance attestations)
- **RubyGems**: Trusted Publisher
- **crates.io**: Trusted Publisher

For Go modules, the equivalent is publishing artifacts via OIDC-attested
Actions; for Claude Code plugins, the marketplace consumes signed
attestations directly.

---

## 8. License selection

### 8.1 The 2026 short list

| License | When to pick | Patent grant | Copyleft | OSI-approved |
|---|---|---|---|---|
| **MIT** | Maximum permissiveness, smallest text | No | No | Yes |
| **Apache-2.0** | Permissive + explicit patent grant + corporate-friendly | Yes | No | Yes |
| **BSD-3-Clause** | Permissive + no-endorsement clause | No | No | Yes |
| **MPL-2.0** | File-level copyleft (modify-the-file → share-the-file) | Yes | File-level | Yes |
| **LGPL-3.0** | Library-level copyleft (link-OK, modify-the-lib → share) | Yes | Lib-level | Yes |
| **GPL-3.0** | Strong copyleft (any combined work → share) | Yes | Strong | Yes |
| **AGPL-3.0** | GPL + closes the SaaS loophole | Yes | Strong | Yes |
| **BSL** / **PolyForm** / **SSPL** | Source-available (NOT open source) | Varies | Varies | **No** |

### 8.2 The 2026 default for a new community-oriented project

- **Apache-2.0** if any patentable invention OR corporate contributors
  expected. Explicit patent grant is the deciding factor.
- **MIT** for the simplest tools where patents are not a concern and
  brevity matters.
- **AGPL-3.0** if you're worried about hyperscalers running your code as
  a service without contributing back.
- **BSL/SSPL/PolyForm** only with eyes open: you lose Scorecard credit,
  OSI listing, CNCF eligibility, and significant goodwill. The "fork
  wars" of 2024–26 demonstrate the cost.

### 8.3 What's losing favor

- **GPL/LGPL share is declining** in new projects (still huge in
  installed base).
- **Apache-2.0 share peaked then dropped** as MIT spiked from
  enterprise adoption.
- **BSL** retains visibility (HashiCorp, MongoDB) but contributor counts
  drop sharply after a relicense; treat any BSL adoption as a one-way
  door from community OSS to commercial source-available.

---

## 9. DCO vs CLA in 2026

**DCO (Developer Certificate of Origin) is winning.**

- Inflection point: OpenInfra Foundation transitioned from CLA to DCO
  on 2025-07-01, citing measurable contributor-retention gains.
- Linux Foundation has favored DCO since inventing it in 2004.
- Linux kernel, Docker, Git, Kubernetes all use DCO.

**Pick DCO unless** you specifically need:

- Explicit corporate patent grant beyond the license.
- Future right to **relicense** the project (CLA-with-copyright-
  assignment lets the project owner change license; DCO does not).
- Some enterprise compliance teams still require CLA for inbound.

DCO mechanics: enforce `Signed-off-by:` trailer on every commit via
the **DCO GitHub App** or a CI check. Adding the trailer is one flag:
`git commit -s -m "..."`.

---

## 10. Versioning and releases

### 10.1 SemVer 2.0.0

`MAJOR.MINOR.PATCH`. Universal default. Pre-release suffixes
(`-rc.1`, `-beta.2`) and build metadata (`+build.123`) supported.

### 10.2 Conventional Commits 1.0.0

```
feat(scope): add support for X
fix(scope): handle nil response from Y
docs: clarify install instructions
chore(deps): bump go to 1.23
feat!: rename HTTP API endpoints       # breaking change → MAJOR bump
```

This commit convention powers automated version bumps via:

- `release-please` (Google) — opens a PR with the bump and changelog,
  merging it cuts the release.
- `semantic-release` (npm-ecosystem-flavored) — pushes the tag on merge
  to main.

Pick one, document it in CONTRIBUTING.md.

### 10.3 Release process (gold standard)

1. Conventional commits land on `main`.
2. `release-please` keeps an open PR with the next version + changelog.
3. Merging the release PR creates the tag.
4. `release.yml` triggers on tag:
   - Build artifacts (cross-platform if relevant).
   - Generate SBOM (SPDX + CycloneDX).
   - Sign artifacts with `cosign` keyless.
   - Generate SLSA provenance via `actions/attest-build-provenance`.
   - Create GitHub Release with all assets attached.
   - Optionally publish to package registries via Trusted Publishing.
5. Releases are **immutable** — never edit a published release; cut a
   new patch instead.

### 10.4 What a good release page looks like

- **Title:** matches the tag (e.g., `v1.2.0`).
- **Body:** the changelog section for that version.
- **Assets:** binaries (one per platform), SBOM (both formats),
  cosign signatures and certificates, SLSA provenance attestation.
- **Discussion:** auto-create a release-discussion thread for feedback.

---

## 11. Governance

### 11.1 The four common models

- **BDFL** (Benevolent Dictator for Life) — default for solo/small
  projects. Document it explicitly.
- **Meritocracy / maintainer team** — contributors earn write access by
  track record.
- **Liberal contribution** (Node.js style) — broad commit access, lazy
  consensus.
- **Foundation** — when the project is critical infra or has multi-org
  maintainership.

### 11.2 When to write GOVERNANCE.md

Skip at launch if you are BDFL. **Required** once:

- ≥2 maintainer organizations.
- You join a foundation (CNCF, Apache, OpenInfra, LF).
- Contributors ask "how do I become a maintainer?"
- A controversial decision is on the table and you need a documented
  process.

### 11.3 GOVERNANCE.md contents

- Decision-making process (lazy consensus? supermajority? BDFL veto?)
- Maintainer roles and how to become one (the "contributor ladder")
- Sub-project lifecycle (proposal, incubation, graduation, archival)
- Conflict resolution procedure
- Code of Conduct enforcement chain

### 11.4 RFC processes

Rust RFCs, Python PEPs, Kubernetes KEPs — formal proposal processes.
Worth introducing only once the project has many active contributors
**and** irreversible API decisions are common. Premature RFC processes
add friction without benefit.

---

## 12. Community building

### 12.1 GitHub Discussions

Enable from day one. Redirect support requests there from Issues via
`config.yml`. Categories: Q&A, Ideas, Show & Tell, Polls.

### 12.2 Real-time chat

Pick one based on audience:

- **Discord** — dominant for indie/dev-tool projects. Easy onboarding,
  free Nitro features for verified servers.
- **Matrix** (Element) — preferred by FOSS purists, federated.
- **Slack** — enterprise-leaning communities.

### 12.3 Code of Conduct enforcement

Naming an enforcement contact email and ≥2 named enforcers (gender-
diverse if possible). A CoC without an actual enforcer is not credible.
Document the escalation ladder (warning → temporary ban → permanent ban).

### 12.4 Contributor ladder

Document concrete criteria:

- **Contributor** — anyone who opens a PR.
- **Triager** — accepted ≥X PRs; can label/close issues.
- **Reviewer** — accepted ≥Y PRs; can approve PRs.
- **Maintainer** — accepted ≥Z PRs; commit access; release authority.

Recommended once you accept ≥10 PRs from non-core contributors.

### 12.5 Recognition

- All-Contributors bot or similar — credit non-code contributions
  (docs, design, triage, translation).
- Quarterly thank-you in release notes or blog.
- Conference talks — credit the contributors who shipped the feature.

---

## 13. Discoverability

### 13.1 GitHub topics

Set 5–10 topics: language, framework, category. E.g.:
`go`, `claude-code`, `security`, `cli`, `developer-tools`.

### 13.2 About section

One-line description + website + topics. This is what shows up in
search results.

### 13.3 Social preview image

1280×640 PNG. Massively boosts click-through on Twitter/Bluesky/HN.
Generate with a template (Figma, OG-image generator).

### 13.4 README badges row

4–6 high-signal badges:

- Build status
- Latest release
- OpenSSF Scorecard score
- OpenSSF Best Practices badge
- License
- Downloads / stars (only if impressive)

Don't overdo. 12 badges signal noise, not seriousness.

### 13.5 OpenSSF Best Practices badge

`https://www.bestpractices.dev/en` — passing/silver/gold tiers.
Self-assessed; **passing tier is achievable in ~2 hours** and signals
seriousness to security-conscious adopters.

### 13.6 OpenSSF Scorecard badge

Machine-evaluated; reflects actual repo configuration. Aim for **≥7.0**.
Address failing checks publicly.

### 13.7 Awesome lists

Submit to relevant awesome-lists for your ecosystem
(`awesome-go`, `awesome-claude-code`, etc.). Free distribution to
exactly the right audience.

---

## 14. Launch playbook

### 14.1 Two weeks before

- Soft-announce on Bluesky/Twitter/Mastodon.
- Line up 3–5 early users to comment with real experience on launch day.
- Polish landing page (or README, if no website).
- Make sure `make test` and the quickstart actually work on a fresh
  machine.

### 14.2 Launch day

- **Show HN** is the highest-ROI channel for dev tools. Title format:
  `Show HN: <plain-language description>`. No buzzwords. Working demo +
  README required.
- Reply to every HN comment within the first 4 hours.
- Cross-post to:
  - Lobste.rs (systems/infra audiences)
  - Reddit r/<your-language> (e.g., r/golang)
  - dev.to with a long-form post
  - Hacker News (the Show HN above)
- Skip Product Hunt for niche B2B/dev tools — saturated, upvotes don't
  convert.
- Send DMs to 2–3 relevant newsletter authors.

### 14.3 Blog post template

1. Hook — the problem you faced.
2. Why existing solutions don't fit.
3. What you built — show, don't tell.
4. 30-second demo (terminal cast or screenshot sequence).
5. Architecture diagram if non-trivial.
6. Call to action — try it, star, contribute.
7. Roadmap — what's next.

### 14.4 The first 72 hours

- Triage every issue and PR within 24h. Even a "thanks, looking" reply.
- Keep replies friendly. The tone of the first 30 issues sets the tone
  of the next 3000.
- Track friction points; ship the first patch release within a week.

---

## 15. Plugin / extension specifics

If the project is a plugin or extension for a host platform (VS Code,
Claude Code, Obsidian, Chrome, Slack), the host has a marketplace and
manifest format you must conform to.

### 15.1 Manifest

The host's manifest (`package.json`, `manifest.json`,
`plugin.json`, etc.) typically requires:

- `name`, `description`, `version` (SemVer)
- Permissions / capabilities (declare the minimum needed)
- Compatibility floor (minimum host version)
- Entry points (commands, hooks, etc.)

### 15.2 Marketplace listing

Each marketplace has its own publishing flow. Common requirements:

- Verified-publisher status (often requires email verification).
- Icon (PNG, exact dimensions per marketplace).
- Screenshots (3–5 typical).
- Categories (pick narrow, not broad).
- Pricing (free, freemium, paid).

### 15.3 Permissions hygiene

Declare the minimum permissions needed. Users see this on install —
over-broad permissions kill adoption for security-sensitive plugins.
README should justify each permission requested.

### 15.4 Hook contract stability

If the plugin ships hooks/extension points, treat the input/output
contract as a public API. SemVer applies. Breaking the hook contract
is a MAJOR version bump.

### 15.5 Compatibility floor

Declare the minimum host version explicitly. Hosts evolve fast; pinning
prevents users on old versions from installing a plugin that won't work.

---

## 16. AI-assisted contribution policy (new in 2026)

Major projects now require disclosure of significant AI-assisted
contributions. Policies range from outright bans (Zig, NetBSD, QEMU)
to mandatory disclosure (Fedora, Apache Airflow, NumPy) to permissive
(FastAPI, Icechunk).

### 16.1 The three policy positions

1. **Ban** — no LLM-generated code accepted. Justification: model
   output may incorporate training-data without proper attribution;
   contributors cannot defend every line if challenged.
2. **Disclose** — LLM-assisted PRs allowed, but contributor must:
   - Add `Assisted-by: <tool>` trailer to commits (Fedora convention).
   - Be able to explain every line to a reviewer.
   - Take full responsibility for the contribution under the project's
     license.
3. **Permit silently** — no special policy.

### 16.2 The 2026 default for a new project

**Disclose.** Add to CONTRIBUTING.md:

```markdown
## AI-assisted contributions

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
```

### 16.3 Why this matters in 2026

- Provenance: training-data licensing is unsettled; future legal
  rulings may affect derivative work classification.
- Quality: disclosure forces contributor self-review and surfaces
  PRs where the contributor has not actually understood the code.
- Trust: reviewers calibrate scrutiny based on knowing the source.
- Liability: if an AI-generated regression slips through, the policy
  documents the chain of responsibility.

---

## 17. Trust posture by project category

### 17.1 Security tool / governance tool

A tool whose job is to enforce security must clear a higher bar.
Baseline for credibility in 2026:

1. **Eat your own dog food.** The repo runs your own enforcement.
2. **Reproducible builds + signed releases + SLSA L3 provenance + SBOM.**
   All four. Missing any one is a credibility hit.
3. **Signed commits** via gitsign or hardware-key GPG. Enforced by
   ruleset, **no admin exemption**.
4. **OpenSSF Scorecard score** ≥7.0, published in README.
5. **OpenSSF Best Practices passing badge** at minimum; aim for silver
   within 6 months.
6. **CVE assignment**: register the repo as a GHSA-issuing repo so you
   can publish CVEs you find/receive without going through MITRE.
7. **Independent security audit** — even a small one signals seriousness.
8. **Cite incidents** — when adding a deny pattern or guard, cite the
   real CVE/incident. This is what differentiates "security theater"
   from "incident-driven defense."
9. **Transparent governance** — published maintainer list with PGP/
   Sigstore identities; documented disclosure ladder; 90-day disclosure
   commit in SECURITY.md.
10. **No telemetry by default** — opt-in only, fully documented.
11. **Permission minimization** in distributed artifacts; README
    justifies every permission requested.
12. **AI-assisted contribution policy with teeth** (see §16.2).

### 17.2 Library

- Stable API contract via SemVer.
- Test coverage badge (≥80% is conventional).
- Idiomatic for the language.
- Supports the last 2 minor versions of the language runtime.

### 17.3 CLI app

- Cross-platform binaries in releases (linux/amd64, linux/arm64,
  darwin/amd64, darwin/arm64, windows/amd64).
- `--version` output includes commit SHA and build date.
- `--help` is high-quality (use cobra/clap/click idioms).
- Homebrew/scoop/winget formula for easy install.

### 17.4 Web service / SaaS

- Self-hosting documentation including hardware requirements.
- Privacy policy + Terms of Service even for OSS (if you host an
  instance).
- Rate-limit + abuse-mitigation documented.

---

## 18. Launch-day checklist

Print this. Walk through it on the day you flip visibility.

### Pre-flight (do once, before flipping)

- [ ] `gitleaks` clean on full history
- [ ] All leaked secrets rotated
- [ ] Contributor identities reviewed; consent obtained
- [ ] Dependency licenses audited; conflicts resolved
- [ ] Pre-public snapshot bundled and stored offline
- [ ] Employer / contractor IP sign-offs in hand

### Files at root

- [ ] `LICENSE` (SPDX-named)
- [ ] `README.md` with badges, quickstart, links
- [ ] `CONTRIBUTING.md` with DCO + AI-policy
- [ ] `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1)
- [ ] `SECURITY.md` with PVR link, supported versions, timeline
- [ ] `CHANGELOG.md` (Keep a Changelog format)
- [ ] `.github/CODEOWNERS`
- [ ] `.github/ISSUE_TEMPLATE/` (config + bug + feature forms)
- [ ] `.github/pull_request_template.md`
- [ ] `.github/dependabot.yml`
- [ ] `.github/FUNDING.yml` (optional)

### Workflows

- [ ] `.github/workflows/ci.yml`
- [ ] `.github/workflows/codeql.yml`
- [ ] `.github/workflows/scorecard.yml`
- [ ] `.github/workflows/dependency-review.yml`
- [ ] `.github/workflows/release.yml`

### Repository settings

- [ ] Default branch `main`, auto-delete head on merge
- [ ] Ruleset on `main` (PR + ≥1 approval + signed commits + status
      checks + linear history + no force-push + no admin bypass)
- [ ] Ruleset on `v*` tags (signed tags, restricted)
- [ ] GitHub Actions: read-only token, allowed actions pinned
- [ ] Dependabot alerts/updates: on
- [ ] CodeQL: on
- [ ] Secret scanning + push protection: on
- [ ] Private Vulnerability Reporting: on
- [ ] Discussions: on
- [ ] Wiki: off
- [ ] About: description + website + topics

### First release

- [ ] Tag created (`vMAJOR.MINOR.PATCH`)
- [ ] Release artifacts built and attached
- [ ] SBOM (SPDX + CycloneDX) attached
- [ ] cosign keyless signature attached
- [ ] SLSA provenance attestation attached
- [ ] Release notes match CHANGELOG entry
- [ ] Release-discussion thread auto-created

### Discoverability

- [ ] OpenSSF Scorecard badge in README, score ≥7.0
- [ ] OpenSSF Best Practices badge applied for (passing tier)
- [ ] 5–10 GitHub topics set
- [ ] Social preview image uploaded (1280×640 PNG)
- [ ] Submitted to 1+ relevant awesome-list

### Launch communication

- [ ] Show HN draft ready
- [ ] Blog post / launch post ready
- [ ] 3–5 early users primed to comment
- [ ] Newsletter authors DM'd
- [ ] Maintainer team available for first 72 hours

---

## 19. After launch

### Week 1

- Triage every issue/PR within 24h.
- Ship a patch release if any critical bug surfaces.
- Track which features people ask for; **don't** build them yet.

### Month 1

- First minor release with the most-asked feature.
- Apply for OpenSSF Best Practices silver tier if ready.
- Announce a roadmap with 3 themes for the next quarter.

### Month 3

- Review contributor ladder — anyone earned the next rung?
- Run CoC enforcement self-audit (any incidents handled correctly?).
- Survey: ask 5 active users what's missing.

### Month 6

- Consider GOVERNANCE.md if multi-maintainer.
- Consider Foundation membership if the project is critical infra.
- Audit Scorecard score; address any regressions.

---

## 20. References

Authoritative sources used for this guide:

- GitHub Open Source Guide — https://opensource.guide/
- GitHub Community docs — https://docs.github.com/en/communities
- GitHub Code Security — https://docs.github.com/en/code-security
- GitHub Repository Rulesets —
  https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets
- OpenSSF Best Practices — https://www.bestpractices.dev/en
- OpenSSF Scorecard — https://github.com/ossf/scorecard
- OpenSSF SCM Best Practices — https://best.openssf.org/SCM-BestPractices/
- choosealicense.com — https://choosealicense.com/
- SLSA Framework — https://slsa.dev/spec/v1.0/levels
- Sigstore cosign — https://github.com/sigstore/cosign
- Sigstore gitsign — https://github.com/sigstore/gitsign
- GitHub Artifact Attestations —
  https://github.blog/security/supply-chain-security/introducing-artifact-attestations-now-in-public-beta/
- Conventional Commits — https://www.conventionalcommits.org/en/v1.0.0/
- Keep a Changelog — https://keepachangelog.com/en/1.1.0/
- DCO at OpenInfra Foundation — https://openinfra.org/dco/
- Contributor Covenant 2.1 — https://www.contributor-covenant.org/version/2/1/code_of_conduct/
- AI-policy collection (Melissa Mendonça) —
  https://github.com/melissawm/open-source-ai-contribution-policies
- EFF AI-policy — https://www.eff.org/deeplinks/2026/02/effs-policy-llm-assisted-contributions-our-open-source-projects
- Reproducible Builds — https://reproducible-builds.org/

---

End of guide.
