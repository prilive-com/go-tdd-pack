# Maintainers

The current maintainer team for `go-claude-forge`.

## Active maintainers

| Name | GitHub | Role | Sigstore identity |
|---|---|---|---|
| Anton Dvornikov | _(your GitHub handle here, e.g. `@your-handle`)_ | Lead maintainer, releases, security contact | _(set up via `gitsign` and record OIDC subject here)_ |

## Status: single-maintainer project

This is currently a **single-maintainer project**. We are open about
the limitations this implies:

- **CoC enforcement**: Contributor Covenant 3.0 typically assumes ≥2
  enforcers so that reports against one can be escalated to another.
  We document this gap in [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)
  and route around it via GitHub's Trust & Safety channel.
- **Bus factor**: a single point of failure for releases, security
  fixes, and triage. If the maintainer becomes unreachable, the
  repository remains under Apache-2.0 and may be forked freely.
- **Review velocity**: PRs may take longer to land than a multi-
  maintainer project can deliver.

## Looking for co-maintainers

We are actively looking for a second maintainer to help with:

- Code of Conduct enforcement (real human #2 to triage reports)
- Release co-signing (co-maintained release artifacts)
- PR review for hooks and `/second-opinion` workflow changes
- Adopter support in Discussions

If you would be interested, open a Discussion thread or reach out via
GitHub. We're not looking for a specific background — what we need is
someone who reviews carefully, communicates clearly, and would
actually act on a CoC report.

## Maintainer responsibilities

Each maintainer commits to:

1. **Triage** — acknowledge new issues / PRs within 14 days, even if
   only "thanks, looking."
2. **Release discipline** — every release signed with `cosign` keyless,
   SLSA provenance attached, SBOM (SPDX + CycloneDX) attached.
3. **Security disclosure** — respond to PVR reports within 72 hours;
   90-day fix target for P0/P1.
4. **CoC enforcement** — handle reports per the documented ladder.
5. **Honest framing** — keep the README, CHANGELOG, and feature-status
   table accurate to what the pack actually does, not what we wish it
   did.

## Maintainer add / remove process

Adding a maintainer requires consensus from existing maintainers. For
a single-maintainer project, that means: Anton invites; the invitee
accepts in a public PR adding their entry to this file; the PR lands
with an `Assisted-by:` trailer disclosing any AI involvement in the
discussion.

Removing a maintainer requires either:

- Voluntary resignation (PR removing their entry)
- Inactivity ≥ 6 months with no response to outreach attempts
  documented in a public issue
- Code of Conduct violation per the enforcement ladder

## Decision-making

While this is a single-maintainer project, decision-making is
documented as **BDFL** (Benevolent Dictator for Life): the lead
maintainer has final say. We will move to **lazy consensus** among
maintainers once a second maintainer joins, and to a more formal
governance model (probably documented in `GOVERNANCE.md`) once we
have ≥3.

This is not a permanent stance — it is the appropriate model for a
project of this size and team count today, and we will revisit as the
project grows.

## Contact

- Public discussion: <https://github.com/prilive-com/go-claude-forge/discussions>
- Bugs / feature requests: <https://github.com/prilive-com/go-claude-forge/issues>
- Security: <https://github.com/prilive-com/go-claude-forge/security/advisories/new>
- Code of Conduct: see [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)
