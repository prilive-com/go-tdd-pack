# Combined GitHub Setup Plan for prilive-com

## Honest verdict on the consultant document

The consultant's document is well-organized and has several ideas worth stealing.
But it has three problems that I'd be dishonest not to flag:

### Things the consultant got wrong

1. **They ignored your "no gh CLI" requirement.** You explicitly chose
   `curl + GitHub REST API — portable, no gh dependency`. The consultant's
   scripts all use `gh api`, which requires the GitHub CLI to be installed
   and authenticated. That's a hard requirement violation. Their scripts
   will not run without `brew install gh && gh auth login` first.

2. **They recommend the legacy branch-protection endpoint over Rulesets.**
   Their `protect-main.sh` uses `PUT /repos/{owner}/{repo}/branches/{branch}/protection`
   with `enforce_admins: true`. That endpoint still works in May 2026
   (verified), but the GitHub docs and changelog steer all new configuration
   toward Rulesets. Rulesets are layered, supportbypass actors with audit,
   and dry-run via `enforcement: evaluate`. Legacy branch protection has
   none of that.

3. **They use `required_approving_review_count: 1` for a solo maintainer.**
   This is a contradiction. A solo maintainer cannot approve their own PR.
   The consultant's config will block every PR until @prilive somehow has
   a second account or another maintainer joins. The correct solo-maintainer
   pattern is `required_approving_review_count: 0` with `require_code_owner_review: true`
   and a `bypass_actor` for the maintainer (see my previous research).

4. **They invented `security@prilive.com` and `conduct@prilive.com`.** You
   don't have a domain. Your email is `prilive.company@gmail.com`. Same
   error the previous consultant made.

5. **They use `gh api -F private=true`.** The `-F` flag in gh-cli sends form
   data, not JSON booleans. With raw curl + the REST API, you must send
   `"private": true` as JSON. This is a gh-specific syntax that won't
   translate to curl directly.

### Things the consultant got RIGHT that my previous answer missed

1. **The private-first workflow.** Create repo as private → push files →
   configure security → verify → only then make public. **This is genuinely
   better than my approach.** It prevents the embarrassing window where a
   public repo exists with no LICENSE, broken README, and stale secrets in
   early commits. I should adopt this.

2. **Tag rulesets to protect release tags.** Once you tag v2.0.0, you want
   it to be immutable. The consultant's `create-release-tag-ruleset.sh`
   uses a ruleset with `target: tag` and `conditions.ref_name.include: ["refs/tags/v*"]`
   plus `deletion` and `non_fast_forward` rules. **This is correct and
   important.** I missed it in my previous research.

3. **The interactive "type MAKE_PUBLIC to confirm" pattern.** Hard guard
   against accidentally making a repo public before it's ready. Good practice.

4. **Script family structure with separate purposes.** They split into
   `create-oss-repo.sh`, `protect-main.sh`, `enable-security.sh`, etc.
   Easier to run individual steps. My monolithic `apply-baseline.sh`
   was harder to debug.

5. **Explicit verification script.** They have a dedicated `verify-repo-settings.sh`
   that prints current state. Useful for sanity checks during setup.

6. **CODEOWNERS file content.** They wrote a clean example with path-specific
   ownership for security-sensitive directories. I should adopt this.

### Things I had right that the consultant lost

1. **No `gh` dependency** (the actual requirement).
2. **Rulesets over legacy branch protection.**
3. **Solo-maintainer review count = 0 with bypass actor.**
4. **Real email `prilive.company@gmail.com`.**
5. **Org-level ruleset that applies to all current and future repos.**
6. **Idempotent operations** with ruleset name reconciliation.
7. **Drift detection via separate audit script + scheduled workflow.**
8. **OpenSSF Scorecard check mapping table.**
9. **Honest "settings the API cannot configure" table.**

## The combined solution

Final design takes:

- **From me**: pure curl + jq (no gh), Rulesets API (not legacy branch protection),
  solo-maintainer `required_approving_review_count: 0` + bypass actor pattern,
  org-level rulesets, drift audit, real email, OpenSSF Scorecard mapping.

- **From consultant**: private-first workflow, tag ruleset for release immutability,
  script family structure (separate files per purpose), interactive
  "MAKE_PUBLIC" confirmation, CODEOWNERS file content, verification script.

- **New (from neither)**: a single `setup.sh` orchestrator that runs the
  family in the right order, a `repo-config.env` per-repo overrides file,
  and a "smoke" mode that creates a throwaway test repo first to verify
  the scripts work before applying to your real repos.

See the other files in this directory:

- `repo-config.env` — per-repo configuration (description, topics, etc.)
- `baseline.json` — settings baseline (declarative)
- `lib/gh-curl.sh` — common curl wrapper (rate limit, retry, logging)
- `01-create-private.sh` — create repo as private
- `02-set-metadata.sh` — description, topics, merge settings
- `03-enable-security.sh` — Dependabot, secret scanning, PVR
- `04-protect-main.sh` — Rulesets for main branch
- `05-protect-tags.sh` — Rulesets for release tags
- `06-set-actions-permissions.sh` — workflow token permissions
- `07-enable-codeql.sh` — code scanning default setup
- `08-apply-org-baseline.sh` — org-level ruleset for all repos
- `99-make-public.sh` — flip to public (interactive confirm)
- `audit.sh` — drift detection
- `setup.sh` — orchestrator that runs 01-07 in order
- `RUNBOOK.md` — first-time setup instructions

## What to do with these files

Two paths:

**Path A — quick start (recommended for go-tdd-pack):**
1. Read `RUNBOOK.md` end-to-end first.
2. Create fine-grained PAT per `RUNBOOK.md`.
3. Edit `repo-config.env` for go-tdd-pack.
4. Run `./setup.sh` to apply 01-07.
5. Push your code.
6. Run `./99-make-public.sh` when ready.

**Path B — apply to multiple existing repos:**
1. Same setup as path A.
2. For each existing repo, set `REPO_NAME` in `repo-config.env`.
3. Run `./setup.sh --skip-create` (skips step 01, applies 02-07).
4. Don't run 99 (those repos are already public).

The scripts are idempotent. Running them twice produces the same result.
