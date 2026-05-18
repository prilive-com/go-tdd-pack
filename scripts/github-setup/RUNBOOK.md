# GitHub Setup Runbook for prilive-com

> **For the maintainer.** This is the one-time setup, then the per-repo
> workflow. Read this end-to-end before running anything.

---

## What this is

Eight numbered bash scripts plus an orchestrator and an audit script that
configure a GitHub repository to OpenSSF best practices for a solo
open-source maintainer.

Scripts use only `curl` and `jq` — no GitHub CLI dependency, fully portable.

Settings applied:

- **Private-first creation** (then flip to public after verification)
- **Modern Rulesets API** (not legacy branch protection)
- **Solo-maintainer pattern**: PR required, 0 reviewers, CODEOWNERS owner=you,
  admin can bypass via PR-mode (auditable)
- **Tag protection**: release tags (`v*`) cannot be deleted or force-pushed
- **Security features**: Dependabot alerts + updates, secret scanning + push
  protection, Private Vulnerability Reporting
- **CodeQL default setup** (Go, configurable)
- **Least-privilege GITHUB_TOKEN**: read-only by default
- **Org-level baseline ruleset** (optional, applies to all current + future repos)
- **Web commit signoff required** (DCO equivalent on web UI commits)

---

## §1. Prerequisites

Required on your machine:
- `bash` 4+
- `curl`
- `jq` 1.6+
- `git`

Verify:

```bash
bash --version
curl --version
jq --version
git --version
```

On macOS:
```bash
brew install bash jq    # curl and git are pre-installed
```

On Linux (Debian/Ubuntu):
```bash
sudo apt-get install bash curl jq git
```

---

## §2. One-time GitHub setup (manual, ~5 minutes)

These need to be done in the GitHub web UI; they cannot be done via API.

### 2.1 Enable org-level 2FA

1. Go to https://github.com/organizations/prilive-com/settings/security
2. Under "Authentication security", enable "Require two-factor authentication for everyone in prilive-com"

### 2.2 Enable Private Vulnerability Reporting at org level

1. Go to https://github.com/organizations/prilive-com/settings/security_analysis
2. Under "Private vulnerability reporting", enable for all current and new repos

### 2.3 Install the cncf/dco2 GitHub App

1. Go to https://github.com/apps/dco
2. Click "Install"
3. Select prilive-com → All repositories (or specific repos)

### 2.4 Create the `prilive-com/.github` org-default repo

This holds default community health files that auto-apply to repos missing
their own copy:

```bash
# Create the .github repo first
mkdir -p .github-org && cd .github-org
git init
# Add default SECURITY.md, CODE_OF_CONDUCT.md, CONTRIBUTING.md, SUPPORT.md
# Plus profile/README.md (shown on https://github.com/prilive-com)
```

Then push to `prilive-com/.github` (you'll need to create that repo first
using the scripts in this directory, with `REPO_NAME=.github`).

---

## §3. Create your fine-grained PAT (5 minutes)

The scripts authenticate via a fine-grained Personal Access Token. Classic
PATs are deprecated for new automation.

1. Go to https://github.com/settings/personal-access-tokens/new
2. **Token name:** `prilive-com-baseline-2026`
3. **Expiration:** Custom → 365 days (the max for org-policy-compliant tokens)
4. **Resource owner:** Select `prilive-com` (not your personal account)
5. **Repository access:** All repositories
6. **Repository permissions:**
   - Administration: **Read and write**
   - Contents: **Read and write**
   - Metadata: **Read-only** (auto-selected)
   - Actions: **Read and write**
   - Pull requests: **Read-only**
   - Issues: **Read and write**
   - Code scanning alerts: **Read and write**
   - Secret scanning alerts: **Read-only**
7. **Organization permissions:**
   - Administration: **Read and write**
   - Custom organization roles: **Read-only**
   - Members: **Read-only**
8. Click **Generate token**. Copy it once — GitHub only shows it once.

### Store the token in your OS keychain

Do NOT put the token in `.env` files, shell history, or git-tracked files.

**macOS Keychain:**
```bash
security add-generic-password -s gh-baseline -a $USER -w
# (paste token when prompted, then press Enter, then Ctrl+D)

# Load when needed:
export GH_BASELINE_TOKEN=$(security find-generic-password -s gh-baseline -w)
```

**Linux (libsecret):**
```bash
secret-tool store --label="gh-baseline" service gh-baseline
# (paste token at the prompt)

# Load when needed:
export GH_BASELINE_TOKEN=$(secret-tool lookup service gh-baseline)
```

**1Password CLI (free for individuals):**
```bash
op item create --category=password --title="gh-baseline" \
  password="<paste token>" --vault=Private

# Load when needed:
export GH_BASELINE_TOKEN=$(op read "op://Private/gh-baseline/password")
```

### Calendar reminder

Add to your calendar: "Rotate gh-baseline PAT" 11 months from now.

---

## §4. Run the setup for go-tdd-pack

### 4.1 Copy these scripts to your workspace

```bash
mkdir -p ~/code/prilive-com/github-setup
cp -r /path/to/github-setup/* ~/code/prilive-com/github-setup/
cd ~/code/prilive-com/github-setup
chmod +x *.sh lib/*.sh
```

### 4.2 Edit `repo-config.env`

Open `repo-config.env` and verify these match what you want:

- `ORG="prilive-com"`
- `REPO_NAME="go-tdd-pack"`
- `REPO_DESCRIPTION="..."`
- `REPO_TOPICS="go,golang,..."`
- `REQUIRED_STATUS_CHECKS="..."` — must match your CI job names exactly (or leave empty for now and add after CI is set up)

### 4.3 Load token

```bash
export GH_BASELINE_TOKEN=$(security find-generic-password -s gh-baseline -w)
```

### 4.4 Dry run

```bash
./setup.sh --dry-run
```

This prints what would be done without making changes. Verify it looks right.

### 4.5 Live run

```bash
./setup.sh
```

This will:

1. Create `prilive-com/go-tdd-pack` as **private** (if it doesn't exist)
2. Set description, topics, merge policy, features
3. Enable Dependabot, secret scanning, PVR
4. Pause and ask you to push code first
5. After you push: create the main branch ruleset
6. Create the release tag ruleset
7. Set Actions GITHUB_TOKEN to read-only
8. Enable CodeQL default setup for Go

During the pause in step 4:

```bash
# In another shell, or after pressing Enter to pause:
cd /path/to/your/go-tdd-pack/code
git remote add origin git@github.com:prilive-com/go-tdd-pack.git
git branch -M main
git push -u origin main
```

Then press Enter in the first shell to continue.

### 4.6 Verify

```bash
./audit.sh
```

Should print all checks as `OK`. If you see `DRIFT`, investigate.

### 4.7 Push community files

These are required before the public flip:

- `README.md` (full v2.0 content)
- `LICENSE` (Apache-2.0)
- `NOTICE`
- `CHANGELOG.md`
- `CONTRIBUTING.md`
- `CODE_OF_CONDUCT.md`
- `SECURITY.md`
- `MAINTAINERS.md`
- `CODEOWNERS` (see template below)
- `.github/dependabot.yml`
- `.github/workflows/ci.yml`
- `.github/workflows/scorecard.yml`

### 4.8 Flip to public

```bash
./99-make-public.sh
```

This script will pre-check all required files exist, then ask you to type
`MAKE_PUBLIC` to confirm. Read everything it prints before typing.

After this, `https://github.com/prilive-com/go-tdd-pack` is public.

---

## §5. Org-level baseline (optional, one-time)

Apply a default-branch ruleset to all current and future repos in prilive-com:

```bash
./08-apply-org-baseline.sh
```

This creates an organization-level ruleset that protects the default branch
of every repo in prilive-com (except `.github`, which is excluded). Per-repo
rulesets layer on top.

Run this once. After this, every new repo you create automatically gets the
basic protection without needing to run `04-protect-main.sh` for it
(though you should still run the per-repo scripts for status checks and
other repo-specific settings).

---

## §6. Apply to multiple existing repos

For each existing repo in prilive-com:

```bash
# Edit repo-config.env: change REPO_NAME, REPO_DESCRIPTION, REPO_TOPICS
./setup.sh --skip-create  # skips create step, applies all other settings
./audit.sh
```

Or script it:

```bash
for repo in go-tdd-pack ainews-processor devopspoint; do
  REPO_NAME="$repo" ./setup.sh --skip-create
done
```

---

## §7. CODEOWNERS template

Create `CODEOWNERS` in the repo root (or in `.github/CODEOWNERS`):

```
# Default owner
* @prilive-com

# Security-sensitive directories require code owner review on every PR
/.github/                @prilive-com
/SECURITY.md             @prilive-com
/CODEOWNERS              @prilive-com
/.claude/hooks/          @prilive-com
/.tdd/                   @prilive-com
/runner/                 @prilive-com
/prompts/                @prilive-com
/scripts/                @prilive-com

# Workflow files
/.github/workflows/      @prilive-com
```

Because the ruleset has `require_code_owner_review: true`, every PR
touching these paths requires a review from you (which you can self-approve
in PRs, but generates the audit trail).

---

## §8. Weekly drift audit (optional)

Add to `.github/workflows/repo-settings-audit.yml`:

```yaml
name: Repo settings audit
on:
  schedule:
    - cron: "0 13 * * 1"          # Mondays 13:00 UTC
  workflow_dispatch:
permissions:
  contents: read
  issues: write
jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run audit
        env:
          GH_BASELINE_TOKEN: ${{ secrets.GH_BASELINE_TOKEN }}
        run: |
          chmod +x audit.sh lib/*.sh
          ./audit.sh --json > drift.json
      - name: Open issue if drift found
        if: failure()
        env:
          GH_BASELINE_TOKEN: ${{ secrets.GH_BASELINE_TOKEN }}
        run: |
          title="Settings drift report ($(date -u +%G-W%V))"
          body=$(jq -Rs '.' < drift.json)
          curl -X POST \
            -H "Authorization: Bearer $GH_BASELINE_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/prilive-com/${{ github.event.repository.name }}/issues" \
            -d "{\"title\":\"$title\",\"labels\":[\"settings-audit\"],\"body\":$body}"
```

Add `GH_BASELINE_TOKEN` as a repository or organization secret.

For the first month, run audit-only (no auto-remediation). Once you trust
the audit, you can extend the workflow to call `setup.sh --skip-create` to
auto-fix drift.

---

## §9. Things you still need to do manually

These cannot be configured via the GitHub API as of May 2026:

| Setting | Why API-impossible | Where to set |
|---|---|---|
| Org-level **Require 2FA** | Read-only in API | Org Settings → Authentication security |
| **Repository social preview image** | No API upload field | Repo Settings → Social preview |
| **Discussions categories schema** | API creates discussions, not categories | Repo Settings → Discussions |
| **Email routing for security alerts** | Per-user setting | Personal Settings → Notifications |
| **OpenSSF Best Practices badge** | Manual questionnaire | https://www.bestpractices.dev/projects/new |
| **DCO2 app installation** | Requires UI install | https://github.com/apps/dco |
| **Default LICENSE via .github repo** | GitHub doesn't auto-apply LICENSE | Each repo must have its own |

---

## §10. Troubleshooting

### "Repository creation failed: 403"
Your PAT doesn't have org admin permissions. Re-create the PAT with
"Resource owner: prilive-com" and "Administration: Read and write."

### "Ruleset creation failed: 422 — invalid actor_id"
The `actor_id: 5` (Admin role) may have changed. Run:
```bash
curl -H "Authorization: Bearer $GH_BASELINE_TOKEN" \
  "https://api.github.com/orgs/prilive-com/roles" | jq
```
Find the correct ID and update `04-protect-main.sh`.

### "CodeQL default setup failed: 422 — no supported language"
You haven't pushed any Go code yet. Push first, then re-run
`./07-enable-codeql.sh`.

### "PVR enable failed"
Verify it's enabled at org level (see §2.2). If yes but per-repo still fails,
the org may not allow PVR on private repos — wait until repo is public.

### "Token expired"
Generate a new PAT (§3), store it, re-export `GH_BASELINE_TOKEN`.

---

## §11. What this does NOT do

This setup does NOT configure:

- Webhooks (set up per-repo as needed in UI)
- Deploy keys (set up per-repo as needed in UI)
- Environment protection rules (only meaningful if you use Environments)
- Merge queues (only meaningful for high-traffic repos)
- GitHub Pages (set up per-repo as needed)
- Actions secrets (use `gh secret set` or UI)
- Custom GitHub App installations (one-time UI install)
- The `prilive-com/.github` default community health files (separate setup)

This is intentional. These scripts handle the security and governance
baseline; per-repo specifics belong in per-repo configuration.

---

## §12. Calendar reminders to set up

Add to your calendar:

- **Annual: Rotate PAT** — every May 17, generate new `gh-baseline-2027` token
- **Weekly: Review drift audit** — every Monday afternoon, check for issues
  labeled `settings-audit`
- **Quarterly: Verify all scripts still work** — re-run on a test repo to
  catch GitHub API breaking changes

---

_Generated 2026-05-17 for prilive-com._
