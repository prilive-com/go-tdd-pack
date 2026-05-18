# Maintainers

The current maintainer team for `go-tdd-pack`.

## Active maintainers

| Name | GitHub | Role | Sigstore identity |
|---|---|---|---|
| Anton Dvornikov | _(your GitHub handle here, e.g. `@your-handle`)_ | Lead maintainer, releases, security contact | _(set up via `gitsign` and record OIDC subject here)_ |

## Status: single-maintainer project; succession plan below

This is currently a **single-maintainer project**. We state that
explicitly because downstream consumers deserve to know. Limitations
this implies:

- **CoC enforcement**: Contributor Covenant 3.0 typically assumes ≥2
  Community Moderators so reports against one can be escalated to
  another. We document this gap in [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)
  and route around it via GitHub's Trust & Safety channel.
- **Single point of failure**: for releases, security fixes, and
  triage. If the maintainer becomes unreachable, the repository
  remains under Apache-2.0 and may be forked freely.
- **Review velocity**: PRs may take longer to land than a multi-
  maintainer project can deliver — see best-effort SLAs below.

### Succession plan

If the lead maintainer becomes unavailable for an extended period
(no public activity for 90 consecutive days, no response to
Critical-severity security reports within 30 days):

1. Any co-maintainer added under "Looking for co-maintainers" below
   inherits the lead role automatically.
2. If no co-maintainer exists, the repository will be marked
   **archived** on GitHub with a notice in the README. Consumers
   should fork.
3. The Apache-2.0 license permits any party to fork and continue
   the work; we recommend forks publish a clear NOTICE update and
   their own SECURITY.md.

### Response-time expectations (best-effort, no SLA)

| Channel | Target acknowledgment |
|---|---|
| Security report (PVR or abuse channel) | 72 hours |
| Code of Conduct report | 7 days |
| Bug issue | 14 days |
| Feature request / discussion | 30 days |
| PR Tier 1 (trivial) | 1 week |
| PR Tier 2 (standard) | 2 weeks |
| PR Tier 3 (risky) | 4 weeks |

See `CONTRIBUTING.md` for tier definitions.

## Looking for co-maintainers

We actively want to grow to two or more maintainers. A contributor
becomes eligible for promotion to co-maintainer once **all** of the
following are met:

1. **Sustained contribution.** At least **4 merged pull requests
   over a span of at least 2 months**, with at least one in Tier 2
   (standard) or higher per `CONTRIBUTING.md` change-risk tiers.
2. **Reviewing, not just authoring.** At least **1 substantive
   code review** on someone else's pull request (not a "looks good
   to me" review — a review that surfaced or shaped a finding).
3. **Design familiarity.** Demonstrated understanding of the
   project's design via either (a) a non-trivial documentation
   contribution, or (b) a written response on an issue that shaped
   the project's direction.
4. **Alignment.** Public agreement with the project's goals as
   stated in README.md and with this governance document.
5. **DCO and CoC compliance.** All contributions DCO-signed; no
   unresolved Code of Conduct concerns.

Promotion is by invitation from the current lead maintainer,
recorded as a pull request to this file. Self-nominations are
welcome — open a Discussion referencing this section and the
contributions that meet the criteria. We evaluate against the
criteria, not against personal preference.

A co-maintainer has commit access, review authority on Tier 1 and
Tier 2 PRs, and co-equal authority on Code of Conduct enforcement.
Tier 3 PRs and release tagging continue to require lead-maintainer
sign-off until there are at least two co-maintainers AND a
documented release procedure in `MAINTAINING.md`.

Co-maintainer responsibilities are the same as those listed under
"Maintainer responsibilities" below. We are not looking for a
specific background — what we need is someone who reviews
carefully, communicates clearly, and would actually act on a CoC
report.

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

- Public discussion: <https://github.com/prilive-com/go-tdd-pack/discussions>
- Bugs / feature requests: <https://github.com/prilive-com/go-tdd-pack/issues>
- Security: <https://github.com/prilive-com/go-tdd-pack/security/advisories/new>
- Code of Conduct: see [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)
