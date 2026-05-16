# Contributing to go-claude-forge

Thanks for considering a contribution. This file covers how to set up,
how to propose changes, and the rules around DCO and AI-assisted work.

## Quick links

- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md)
- [Open issues](https://github.com/prilive-com/go-claude-forge/issues)
- [Discussions](https://github.com/prilive-com/go-claude-forge/discussions)
- [Maintainers](MAINTAINERS.md)

## What contributions are welcome

The review bar scales with risk:

- **Docs, examples, typos** → open a PR; review within 14 days.
- **Bug fixes** → open a PR with a regression test; review within 14 days.
- **Hook behavior, schema, or `/second-opinion` workflow changes** →
  open an issue first with a written proposal; we discuss before code.
- **New language packs** (Python, TypeScript, etc.) → open a Discussion
  first to align on shape with the existing Go pack.

## Dev setup

```bash
git clone https://github.com/prilive-com/go-claude-forge
cd go-claude-forge

# Verify required tools
make doctor
# (or run by hand: jq, bash, git, gofmt, go ≥ 1.26.2)

# Run the smoke suite (target: 571/571 passing)
bash scripts/tdd-test-hooks.sh

# Validate every JSON file parses
for f in $(find . -name '*.json' -not -path './archive/*'); do jq empty "$f"; done

# Validate every hook script parses
for f in .claude/hooks/*.sh scripts/tdd/*.sh; do bash -n "$f"; done
```

## Branch flow

Trunk-based. `main` is the only long-lived branch. Feature work happens
on short-lived branches; PR into `main`.

## Commit messages

[Conventional Commits 1.0.0](https://www.conventionalcommits.org/):

```
<type>(<scope>): <subject>

<body, wrapped at ~72 chars>

<footer>
```

Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci`,
`build`, `perf`, `style`. Append `!` for breaking changes.

Add `Signed-off-by:` via `git commit -s` (DCO required, see below).

## DCO (Developer Certificate of Origin)

We use the [Developer Certificate of Origin](https://developercertificate.org/).
Every commit must have a `Signed-off-by` trailer:

```bash
git commit -s -m "fix(hooks): handle empty CLAUDE_PROJECT_DIR"
```

This certifies that **you wrote the code** or **have the right to
contribute it** under the project's license. We chose DCO over a CLA
because it has lower friction for contributors and stronger industry
adoption (Linux kernel, Docker, Kubernetes, OpenInfra Foundation as
of mid-2025).

The [DCO GitHub App](https://github.com/apps/dco) enforces the
`Signed-off-by` check on every PR.

## AI-assisted contributions

This project is an **AI-tooling project**. Contributions assisted by
Claude, GPT, Cursor, Copilot, or similar tools are welcome — with
disclosure.

### When you must disclose

If a non-trivial portion of your contribution was generated or
substantially shaped by an AI tool:

1. **Add an `Assisted-by:` trailer** to your commits, e.g.:

   ```
   Assisted-by: Claude Sonnet 4.5
   Assisted-by: Codex GPT-5.5
   ```

2. **Include in the PR description** a one-paragraph note on what the
   AI produced and what you reviewed/modified.

3. By submitting, **you certify** that you understand every line of
   the contribution and accept responsibility for it under the
   project's license.

### When you don't need to disclose

Trivial AI assistance does not require disclosure:

- Autocomplete (single-line suggestions)
- Error-message rewrites
- Variable renames / mechanical refactors
- Documentation typo fixes

### What we'll close without review

PRs that look LLM-generated without disclosure may be closed without
review. We're not against AI assistance — we're against unattributed
provenance on a project whose job is to enforce attribution.

### Why this policy

- **Provenance**: training-data licensing is unsettled in 2026; future
  legal rulings may affect derivative work classification.
- **Quality**: disclosure forces contributor self-review and surfaces
  PRs where the contributor has not actually understood the code.
- **Trust**: reviewers calibrate scrutiny based on knowing the source.
- **Liability**: if an AI-generated regression slips through, the
  policy documents the chain of responsibility.

## Pull request checklist

- [ ] Commits signed (`git commit -s` for DCO)
- [ ] AI-assisted disclosure added if applicable (`Assisted-by:` trailer + PR note)
- [ ] `bash scripts/tdd-test-hooks.sh` passes (target: 571/571)
- [ ] If a hook contract changed, the JSON shape is documented
- [ ] If a deny pattern was added, the comment cites the CVE/incident
- [ ] CHANGELOG entry under `## [Unreleased]`
- [ ] Docs updated for user-visible changes

## Adding a deny pattern to a hook

Pattern: every deny rule cites its motivating incident or CVE. Example
from `guard-dangerous-bash.sh`:

```bash
# Block --no-verify on git commit (issue #40117).
case "$cmd" in
  *git\ commit*--no-verify*) deny "git commit --no-verify bypasses ..." ;;
esac
```

Without an incident citation, advisory text rots into noise. With one,
future maintainers know why the rule exists. This is the same
discipline our own commit history documents (`fix(v1.9.4)`,
`fix(v1.9.7)`, `fix(v1.9.8)` all cite the adopter session that
surfaced them).

## Reporting a security issue

**Do not** open a public issue. See [`SECURITY.md`](SECURITY.md) for
the private vulnerability reporting flow.

## Code of conduct

By contributing, you agree to follow our
[Code of Conduct](CODE_OF_CONDUCT.md) (Contributor Covenant 3.0).
