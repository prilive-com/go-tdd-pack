# GitHub repo setup scripts

Curl-based scripts to configure a GitHub repo to OpenSSF best practices.
No `gh` CLI dependency, no external state, idempotent.

**To run these:** read [`RUNBOOK.md`](RUNBOOK.md) end-to-end first. It
covers prerequisites, fine-grained PAT creation, the one-time manual
GitHub UI steps, and the run order.

**Why this design** (curl-only, modern Rulesets API, solo-maintainer
review-count=0 with bypass actor, private-first workflow): see
[`DESIGN.md`](DESIGN.md).

## TL;DR run order

```bash
# One-time: load your PAT
export GH_BASELINE_TOKEN=$(security find-generic-password -s gh-baseline -w)

# Per repo: edit config + dry run + live run
$EDITOR repo-config.env
./setup.sh --dry-run
./setup.sh

# Verify
./audit.sh

# When ready for the world
./99-make-public.sh
```

## File index

| Script | What it does |
|---|---|
| `lib/gh-curl.sh` | Shared curl wrapper (auth, retry, logging) |
| `01-create-private.sh` | Create the repo as private |
| `02-set-metadata.sh` | Description, topics, merge policy, features |
| `03-enable-security.sh` | Dependabot, secret scanning, PVR |
| `04-protect-main.sh` | Modern Rulesets for the default branch |
| `05-protect-tags.sh` | Tag protection for release tags (`v*`) |
| `06-set-actions-permissions.sh` | Least-privilege `GITHUB_TOKEN` |
| `07-enable-codeql.sh` | CodeQL default setup |
| `08-apply-org-baseline.sh` | Org-level ruleset (one-time, optional) |
| `99-make-public.sh` | Flip to public with pre-flight checks |
| `audit.sh` | Drift detection (`--json` mode for CI) |
| `setup.sh` | Orchestrator running 01–07 in order |
| `repo-config.env` | Per-repo configuration |
| `RUNBOOK.md` | Full setup runbook |
| `DESIGN.md` | Design rationale and what was rejected |

## Environment variables

| Variable | Purpose | Default |
|---|---|---|
| `GH_BASELINE_TOKEN` | Fine-grained PAT (required) | none |
| `GH_API_BASE` | Override API base URL | `https://api.github.com` |
| `GH_API_VERSION` | API version header | `2026-03-10` |
| `LOG_DIR` | Where JSONL audit logs go | `./logs` |
| `CONFIG_FILE` | Override config file path | `./repo-config.env` |

## Safety notes

- Scripts are idempotent. Running twice produces the same result.
- `01-create-private.sh` creates as **private**. Public visibility
  requires explicit `99-make-public.sh` with `MAKE_PUBLIC` confirmation.
- The token must be stored outside the repo (`security`, `secret-tool`,
  1Password, etc.). The scripts read it from `$GH_BASELINE_TOKEN` only.
- `logs/` is `.gitignore`d. Audit logs may contain partial response
  bodies — don't commit them.

For everything else, see `RUNBOOK.md`.
