# Launch Checklist — Prilive Go TDD Pack v2.0

> **For the maintainer.** Master to-do list before tagging v2.0.0 and
> announcing publicly. Work top to bottom; check off as you go.

---

## A — Before tagging v2.0.0

### A.1 Enable GitHub Private Vulnerability Reporting **[one-time]**

- [ ] Settings → Security → Code security and analysis
- [ ] Under "Private vulnerability reporting", **Enable**
- [ ] Verify in incognito: `https://github.com/<org>/<repo>/security/advisories/new` shows the new-advisory form

**Why:** SECURITY.md tells reporters to use this URL. Without it
enabled, reporters fall back to public issues or your personal email.
Takes 30 seconds.

### A.2 Install cncf/dco2 GitHub App **[one-time]**

- [ ] https://github.com/apps/dco → **Configure**
- [ ] Select your GitHub org → choose the repo
- [ ] Add `.github/dco.yml`:
  ```yaml
  require:
    members: true
  ```
- [ ] Commit signed: `git add .github/dco.yml && git commit -sm "Add DCO config"`
- [ ] Test with a deliberately unsigned PR — DCO check should fail

**Why:** Without DCO sign-off, some companies' legal won't let
employees contribute. 1 minute. Required for serious OSS.

### A.3 Verify all placeholders are filled

Search the repo for unfilled placeholders:

```bash
grep -rn -E '<MAINTAINER|<SECURITY_EMAIL|<YEAR|<PGP|<CONDUCT' . \
  --include='*.md' --include='*.json' --include='*.yml' \
  | grep -v ./archive | grep -v ./docs/opensource
```

Expected: zero hits. If anything matches, fill it before tagging.

### A.4 Verify links work

```bash
# Find external links in main docs
grep -hoE 'https?://[a-zA-Z0-9./_-]+' README.md CHANGELOG.md \
  CLAUDE.md AGENTS.md docs/*.md | sort -u
```

Spot-check each. Particularly the badge URLs in README.md.

### A.5 Make sure plugin.json matches reality

- [ ] `version` matches the tag you'll cut (`2.0.0`)
- [ ] `name` matches the marketplace ID you'll register under
- [ ] `homepage` and `repository` URLs match the real GitHub repo
- [ ] `engines.claude-code` and `requires.codex-cli` versions match
  what we actually test against
- [ ] Each `hooks.*.command` path exists in the repo

```bash
jq -r '.hooks | .. | .command? // empty' .claude-plugin/plugin.json | sort -u
# Each line should resolve to a real file relative to repo root
```

### A.6 Run the full smoke suite

- [ ] Structural smokes pass:
  ```bash
  bash test/smoke-v2-phase2.sh        # expect 25/25 PASS
  bash test/smoke-tool-grounding.sh   # expect 12/12 PASS
  ```
- [ ] Live smokes pass (uses Codex calls):
  ```bash
  bash test/smoke-v2-mvp.sh           # expect PASS
  bash test/smoke-v2-phase2-live.sh   # expect "final status: converged"
  ```

### A.7 Verify governance files

- [ ] `LICENSE` is Apache-2.0 (or whatever license you picked)
- [ ] `SECURITY.md` has the right reporting URL
- [ ] `CONTRIBUTING.md` documents DCO + smoke requirements
- [ ] `CODE_OF_CONDUCT.md` references Contributor Covenant
- [ ] `CHANGELOG.md` has a real `[2.0.0]` entry (not `[Unreleased]`)

### A.8 Verify the marketplace mechanic actually works

If publishing as a Claude Code plugin:

- [ ] Test `/plugin marketplace add` from a fresh Claude Code session
  against your repo
- [ ] Test `/plugin install` and verify hooks register
- [ ] Edit a file in a Go project and verify Codex runs

---

## B — Tag and release

### B.1 Final commit + tag

```bash
git add -A
git status   # verify nothing surprising
git commit -sm "release: v2.0.0"
git tag -a v2.0.0 -m "v2.0.0 — first public release of continuous peer review architecture"
git push origin main
git push origin v2.0.0
```

### B.2 GitHub release

- [ ] Create GitHub release for tag `v2.0.0`
- [ ] Title: `v2.0.0 — Continuous silent peer review`
- [ ] Body: copy the `[2.0.0]` section from `CHANGELOG.md`
- [ ] Mark as **Latest release**

### B.3 Marketplace registration (if applicable)

If you have a marketplace repository:
- [ ] Add an entry pointing to `github.com/<org>/<repo>` with version `2.0.0`
- [ ] Commit + push to the marketplace repo

---

## C — Announce

### C.1 README on GitHub

- [ ] Open the public repo page in an incognito window
- [ ] Verify badges render
- [ ] Verify the documentation links in the README's table all resolve
- [ ] Verify the Quickstart code block looks right

### C.2 Public announcement channels (optional, you choose what fits)

- [ ] Anthropic Claude Code community / forum post
- [ ] HN / lobste.rs / r/golang (only if you want the volume)
- [ ] X/Twitter / Mastodon post with the README's TL;DR
- [ ] Personal blog post if you have one

Don't oversell on day 1. The system has been validated on one
production project; that's honest, useful, and a reasonable hook.

### C.3 OpenSSF Best Practices Badge **[optional, post-launch OK]**

- [ ] https://www.bestpractices.dev/en/projects/new
- [ ] Submit `github.com/<org>/<repo>`
- [ ] Fill the questionnaire — save progress, can take a week
- [ ] When awarded, add the badge to README.md

---

## D — Watch and respond

### D.1 First 48 hours

- [ ] Watch issues and Discussions; respond within a day to anything
  that lands
- [ ] Watch the cncf/dco bot — make sure it's signing off real PRs
- [ ] Watch the Codex / Claude Code dependencies for breaking changes;
  the pack pinned `claude-code >= 2.1.89` and `codex-cli >= 0.125`,
  but releases happen often

### D.2 First week

- [ ] Triage any reported bugs to issues with labels
- [ ] If a real bug surfaces, follow `RELEASE_GUIDE.md` Hotfix process
- [ ] Write a follow-up blog post if traction is real

---

## What this checklist deliberately does NOT include

The following appear in some consultant launch checklists but were
excluded from v2.0.0 as scope:

- OpenSSF Scorecard GitHub Action setup — nice-to-have, not blocking
- Signed releases via cosign + SBOM (SPDX/CycloneDX) — for v2.1+ if
  enterprise demand surfaces
- Release notes broadcast to a mailing list — there isn't one yet
- Build artifacts (binaries) — the pack ships as source, no binaries

Add these incrementally as the project matures, not as gates to v2.0.0.

---

_Last updated: 2026-05-18 for v2.0._
