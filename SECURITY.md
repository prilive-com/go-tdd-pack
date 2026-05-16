# Security Policy

This project ships hooks that gate AI-driven file edits and shell
commands in real Go projects. A vulnerability here can affect every
adopter's repository. We take reports seriously.

## Supported versions

| Version | Status | Security fixes |
|---|---|---|
| **1.9.x** (current) | active | yes |
| 1.8.x | maintenance | critical only, until 2026-08 |
| 1.7.x | end-of-life | no |
| < 1.7 | end-of-life | no |

When a 1.10.x line ships, 1.9.x will move to maintenance mode (critical
fixes only) for ~3 months, then end-of-life.

## Reporting a vulnerability

**Do not open a public issue.** Use one of these private channels:

1. **GitHub Private Vulnerability Reporting (preferred)** —
   <https://github.com/prilive-com/go-claude-forge/security/advisories/new>
2. **GitHub abuse / Trust & Safety** (only if the maintainer is
   non-responsive or the issue involves them) —
   <https://github.com/contact/report-abuse?report=prilive-com%2Fgo-claude-forge>

We do not currently operate a dedicated `security@` email address.
PVR provides audit trails, encrypted communication, and escalation
paths a personal mailbox does not.

## What to include in a report

- **Affected version**: tag (e.g. `v1.9.8`) and full commit SHA from
  `git rev-parse HEAD` of the repo where you observed the issue.
- **Reproduction**: smallest commands, JSON inputs to hooks, and exact
  output that demonstrates the bug.
- **Affected component**: which hook, skill, runner script, or config
  key is involved.
- **Severity assessment** with reasoning (P0 / P1 / P2 / P3 — see
  table below).
- **Proof-of-concept**, if you have one. Sanitized of any actual
  secrets.
- **Disclosure preferences**: do you want to be credited? Do you have
  a planned disclosure date? CVE assignment requested?

## Severity rubric

We treat the following as **P0** (drop everything):

- Any way an AI agent can bypass a Tier 1 hook gate without operator
  approval.
- Any way the SHA-chained audit log can be silently tampered with
  while preserving validation.
- Any path that lets `--no-verify` reach the Tier 1 commit gate.
- Secret-scanner false-negative on a known credential pattern shipped
  in the canonical regex set.
- Hook script remote code execution from untrusted input.

**P1** (next release):

- Hook misclassification (Tier 2 path treated as Tier 1, or vice
  versa) that meaningfully shifts the protection envelope.
- Audit log entries with mis-chained `prev_sha` that pass current
  validation.
- Any way for the runner to record an `obligation_completed` event
  for a scope it did not actually review.

**P2 / P3**: usability defects, documentation accuracy bugs that
mislead operators, hook performance problems on large repos.

## Disclosure timeline

| Stage | Target |
|---|---|
| Acknowledgment of report | within 72 hours |
| Severity triage + ETA shared | within 14 days |
| P0/P1 fix released | within 90 days |
| Coordinated public disclosure (CVE if applicable) | per reporter agreement |

If we cannot meet a target we will tell you and propose a revised
timeline. If a vulnerability is being actively exploited in the wild,
we shorten timelines accordingly.

## Out of scope

The following are **not** treated as security issues:

- Bypasses that require root access on the developer's machine.
- Issues in upstream tools (Claude Code, Codex CLI, jq, git, gitleaks)
  rather than in this pack — please report those upstream.
- Theoretical bypasses that require multiple combined permission
  failures **AND** administrator privileges to execute.
- Social engineering of project maintainers.
- Findings from automated scanners with no demonstrated impact.
- "Hooks can be disabled by the operator via documented killswitch
  env vars" — yes, by design. The killswitches exist for emergencies
  and are audit-logged. That is not a vulnerability.

## Trust note for adopters

This pack defines hooks that **execute shell scripts** on every
Bash/Edit/Write tool call. Only install from sources you trust, and
review `.claude/hooks/*.sh` the same way you would review any code
that runs on your machine.

Relevant prior incident: [CVE-2025-59536](https://nvd.nist.gov/vuln/detail/CVE-2025-59536)
— a Claude Code vulnerability where untrusted project settings could
trigger code execution before the user accepted the trust dialog.
Fixed upstream in Claude Code 1.0.111. We require Claude Code ≥
2.1.89 (which supersedes that fix and addresses related defer-mode
gaps). Verify with `claude --version`.

## Vulnerability disclosure history

| ID | Date | Severity | Component | Fixed in | Reporter |
|---|---|---|---|---|---|
| _(none yet — this section will list past advisories once any land)_ |

## Maintainer security contact

The current maintainer team is documented in [`MAINTAINERS.md`](MAINTAINERS.md).
Note that we are currently a single-maintainer project. If your report
relates to the maintainer's behavior or the maintainer is unresponsive,
use the GitHub abuse / Trust & Safety channel above — that path
operates independently of project maintainers.
