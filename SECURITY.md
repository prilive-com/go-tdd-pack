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
   <https://github.com/prilive-com/go-tdd-pack/security/advisories/new>
2. **GitHub abuse / Trust & Safety** (only if the maintainer is
   non-responsive or the issue involves them) —
   <https://github.com/contact/report-abuse?report=prilive-com%2Fgo-tdd-pack>

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

We rate reports on a four-band prose scale anchored to **CVSS v4.0**
ranges (FIRST.org's current standard since November 2023, what
GitHub Security Advisories emit). The prose band is the user-facing
label; the numeric range is the rubric, not a substitute for a
per-report assessment.

| Band | CVSS v4.0 | Typical examples for this project |
|---|---|---|
| **Critical** | 9.0 – 10.0 | A shipped hook that executes attacker-controlled code without operator approval; supply-chain compromise of a published tag; secret-scanner false-negative on a credential pattern in the canonical regex set; any path that lets `--no-verify` reach the Tier 1 commit gate. |
| **High** | 7.0 – 8.9 | A hook that leaks credentials, files outside the repo, or environment variables; `scripts/*.sh` path traversal; SHA-chained audit log silently tamperable while preserving validation; runner records `obligation_completed` for a scope it did not actually review. |
| **Medium** | 4.0 – 6.9 | Hook misclassification (Tier 2 path treated as Tier 1, or vice versa) that meaningfully shifts the protection envelope; logic flaw in a hook that requires unusual configuration to exploit. |
| **Low** | 0.1 – 3.9 | Defence-in-depth hardening opportunities, documentation gaps with security implications, hook performance problems on large repos with no exploitability impact. |

CVSS v3.1 scores may be quoted alongside where downstream consumers
require them — v3.1 remains the more widely-issued version in NVD
enrichment volume as of May 2026, even though v4.0 is the current
FIRST standard.

Because this is a single-maintainer project, the maintainer's CVSS
assessment may be imprecise. The prose band governs public
communication; the numeric score is informational.

## Disclosure timeline

Our default coordinated-disclosure window is **90 days** from
acknowledgment of a valid report.

| Stage | Target |
|---|---|
| Acknowledgment of report | within 72 hours |
| Severity triage + ETA shared | within 14 days |
| Critical/High fix released | within 90 days |
| Coordinated public disclosure (CVE if applicable) | per reporter agreement |

Two documented levers on the 90-day window:

- **Shorten** the window (down to immediate disclosure-with-patch) if
  there is credible evidence of active exploitation in the wild.
- **Extend** the window by up to **30 days** (one-time) if a
  high-quality patch is imminent but not yet ready AND the reporter
  agrees in writing.

When the embargo lifts we publish a GitHub Security Advisory, request
a CVE via GitHub's CNA where applicable, and credit the reporter
unless they prefer to remain anonymous.

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

## Trust note for adopters — required upstream context

This pack defines hooks that **execute shell scripts** on every
Bash/Edit/Write tool call. Only install from sources you trust, and
review `.claude/hooks/*.sh` the same way you would review any code
that runs on your machine.

Two Claude Code vulnerabilities directly inform our defensive posture
and are required reading for anyone shipping or auditing a plugin
like this one. Both were originally disclosed by Check Point Research
(Aviv Donenfeld and Oded Vanunu) in their 2026 "Caught in the Hook"
write-up.

- **[CVE-2025-59536](https://nvd.nist.gov/vuln/detail/CVE-2025-59536)**
  (GHSA-4fgq-fpq9-mr3g, CVSS v4.0 = 8.7 High, CWE-94) — Claude Code
  prior to **1.0.111** executed code from project files (hooks, MCP
  server commands) **before** the user accepted the startup trust
  dialog. Fixed October 2025.
- **[CVE-2026-21852](https://nvd.nist.gov/vuln/detail/CVE-2026-21852)**
  (GHSA-jh7p-qr78-84p7, CVSS v4.0 = 5.3 Medium, CWE-522) — Claude
  Code prior to **2.0.65** honored an `ANTHROPIC_BASE_URL` value
  from a repository's `.claude/settings.json` and issued API calls
  (carrying the user's Anthropic API key) to the configured endpoint
  before the trust prompt was shown. Fixed early 2026.

**Required runtime**: Claude Code ≥ **2.1.89** — supersedes both
fixes above AND addresses related defer-mode gaps. Verify with
`claude --version`.

What this pack does to harden against the failure modes those CVEs
exposed: we deliberately do not set `ANTHROPIC_BASE_URL`; we do not
ship MCP server configurations beyond the local `gopls`; every
hook's deny patterns cite the CVE or incident that motivated them
in the source (see `CONTRIBUTING.md` "Adding a deny pattern").
Review `.claude/` before first run if you cloned from a fork.

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
