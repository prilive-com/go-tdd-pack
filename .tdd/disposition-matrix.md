# Disposition matrix — v1.9.0-pack-no-discretion-second-opinion

**Date:** 2026-05-13
**Rounds:** 10
**Total findings addressed:** ~37 (P0/P1 only)
**Disposition:** 36 ACCEPT + FIXED, 3 deferred to v1.10 (round-10 F2/F3/F4)

## Triggering evidence

Real conversation transcript 2026-05-12: AI developer skipped
`/second-opinion` four consecutive times in a single supervisor-race-fix
cycle. v1.9.0 removes that discretion mechanically.

## Round-by-round summary

### Round 1 (5 findings — 1 already-pass, 4 fixed)
| ID | Title | Disposition |
|---|---|---|
| F1 | Runner can't satisfy trigger scope hashes | ACCEPT — runner reads pending obligation, transitions status |
| F2 | Forged completions bypass review | ACCEPT — audit-chain validation per match |
| F3 | Production drift detection disabled | ACCEPT — empty scope = INVALID |
| F4 | Review completions poison v1.8 typed audit | ACCEPT (already-pass; later tightened in round 8) |
| F5 | Stop hook can't see pending obligations | ACCEPT — same fix as F1 |

### Round 2 (5 P0 — all fixed)
| ID | Title | Disposition |
|---|---|---|
| F1 | Runner doesn't bind completions to obligation scope | ACCEPT — runner reads pending entry, uses its scope_hash |
| F2 | Production reviews can never unlock | ACCEPT — runner populates allowed_file_globs from pending scope |
| F3 | Test scope excludes proposed content | ACCEPT — include proposed_content_hash |
| F4 | Empty prev_audit_sha forgeable | ACCEPT — require audit entry reference |
| F5 | Pending obligation never transitions | ACCEPT — runner updates pending → approved (no new entry) |

### Round 3 (3 P0 + 1 P1 — all fixed)
| ID | Title | Disposition |
|---|---|---|
| F1 | Runner reviews pre-edit git state | ACCEPT — persist proposed content; runner pack includes it |
| F2 | Audit-event check too lax | ACCEPT — accept obligation_completed OR granted with id match |
| F3 | CYCLE_ABANDONED.txt unprotected | ACCEPT — permissions.deny + cycle_id match |
| F4 | P1 findings can self-approve | ACCEPT — block on P0 OR P1 unresolved |

### Round 4 (4 P0 — all fixed)
| ID | Title | Disposition |
|---|---|---|
| F1 | Audit matching too lax | ACCEPT — strict event+id+cycle+scope_hash match (with legacy fallback) |
| F2 | Mechanical skip-through over-broad | ACCEPT (later refined in round 6 — skip-through removed entirely) |
| F3 | Runner doesn't validate Codex output binding | ACCEPT — verify_conformance checks review_type/cycle_id/scope_hash |
| F4 | Production drift deadlock | ACCEPT — drift creates fresh pending with drift_scope_hash |

### Round 5 (5 P0 — all fixed)
| ID | Title | Disposition |
|---|---|---|
| F1 | Codex prompt missing expected scope_hash | ACCEPT — runner-context-pack includes it |
| F2 | Drift scope never satisfies hook | ACCEPT — hook also looks for drift scope_hash for the file |
| F3 | Plan/test scope hashes only replacement fragment | ACCEPT — include old_string + new_string + path |
| F4 | AUDIT_LOG used before defined (set -u abort) | ACCEPT — defined early |
| F5 | Artifact files model-writable via Edit | ACCEPT — permissions.deny for .tdd/exceptions/** + .tdd/audit/** |

### Round 6 (3 P0 + 1 P1 — all fixed)
| ID | Title | Disposition |
|---|---|---|
| F1 | verify_conformance type-loose | ACCEPT — jq strict type checks for findings array + fields |
| F2 | Audit-event binding loose | ACCEPT — jq-parse audit lines; match scope_hash + review_type |
| F3 | Mechanical skip-through malformed diff | ACCEPT — REMOVED skip-through entirely (v1.7 still gates at commit) |
| F4 | PostToolUse backstop AC mentioned, never built | ACCEPT — backstop implemented + registered |

### Round 7 (4 P0 — all fixed)
| ID | Title | Disposition |
|---|---|---|
| F1 | Bash bypasses Edit/Write protection on artifact files | ACCEPT — Bash-level permissions.deny for protected paths |
| F2 | Audit-event missing scope_hash + review_type bind | ACCEPT — strict v1.9 event check + legacy fallback |
| F3 | Codex self-clears P1 via accepted_with_evidence | ACCEPT — IGNORED; all P0/P1 block until addressed |
| F4 | Backstop regex too narrow | ACCEPT — uses git diff --name-only |

### Round 8 (4 P0 — all fixed)
| ID | Title | Disposition |
|---|---|---|
| F1 | Bash mutating production .go pre-event | ACCEPT — PreToolUse Bash classifier |
| F2 | Audit checks don't bind to scope_hash + review_type | ACCEPT — strict obligation_completed match for v1.9 entries |
| F3 | Review completions poison v1.8 typed-exception gate | ACCEPT — filter v1.8 gate to typed-exception types only |
| F4 | Mechanical skip-through doc-drift | ACCEPT — docs aligned (skip-through removed in round 6) |

### Round 9 (4 P0 — all fixed)
| ID | Title | Disposition |
|---|---|---|
| F1 | Bash pretrigger misses test/plan paths | ACCEPT — pretrigger covers all gated path universe |
| F2 | Legacy audit fallback weakens v1.9 review-completions | ACCEPT — NO legacy fallback for v1.9 types; non-empty prev_audit_sha required |
| F3 | Drift completion shadowed by original | ACCEPT — drift scope_hash takes priority for THIS file |
| F4 | Revised production edits re-review stale payload | ACCEPT — pending entry's proposed_payload updated on each denied retry |

### Round 10 (4 P0 — 1 fixed, 3 deferred to v1.10)
| ID | Title | Disposition |
|---|---|---|
| F1 | First completion in fresh cycle rejected (REGRESSION from round 9 F2) | ACCEPT — allow chain-head case (empty prev_sha) for first audit line |
| F2 | Bash mutating-class regex too narrow | DEFER v1.10 — python/perl/ruby one-liners, dd of=, install, script execution. Operator manually uses Edit/Write for now |
| F3 | Test completion accepts any audit line with id | DEFER v1.10 — apply plan-trigger's strict model to test-trigger |
| F4 | Production granted fallback for v1.9 type | DEFER v1.10 — remove legacy fallback in production hook |

## v1.10 backlog

| Item | Severity | Source |
|---|---|---|
| Production hook: drop `granted` legacy fallback for v1.9 review-completion types | P0 | round-10 F4 |
| Test trigger: apply strict event+scope_hash+review_type+chain-head audit check (mirror plan-trigger) | P0 | round-10 F3 |
| Bash classifier: broaden mutating-command regex to cover python/perl/ruby one-liners, dd, install, shell-script invocation | P0 | round-10 F2 |
| External audit head pin (anti-tamper for last-line completeness) | P1 | v1.8.0 backlog carried forward |
| Operator disposition mechanism for `accepted_with_evidence` (not Codex self-clear) | P1 | round-7 F3 follow-up |
| Codex prompt context size budget (large diffs may exceed token limits) | P2 | not surfaced; latent |

## Acceptance summary

- **10 ACs from approved spec** — all GREEN.
- **10 review rounds processed.**
- **~37 P0/P1 findings** — 34 ACCEPTED + FIXED in cycle, 3 deferred to v1.10.
- **558 / 0 final smoke** (520 v1.8.0 baseline + 34 v1.9.0 acceptance tests + 4 round-1 RED→GREEN).
- **Transcript replay (T-28..T-34)**: all 7 tests GREEN — the four 2026-05-12 transcript bypasses are mechanically prevented.

## Known limits (operator should be aware)

1. **Bash mutating-class detection is incomplete** (round-10 F2). Use Edit/Write tools for plan/test/production paths to ensure primary triggers fire. Bash via heredoc/redirect to gated paths is caught for common patterns but not python/perl/etc.
2. **Test-trigger audit-chain check is less strict than plan-trigger** (round-10 F3). Forged direct edits to `post-red-test-edits.json` paired with an audit line containing the matching `exception_id` could theoretically pass the test trigger. Mitigation: artifact paths are deny-protected at Edit+Write+Bash level (rounds 7+8 fixes); requires combined permissions bypass to exploit.
3. **Production-trigger accepts `granted` legacy audit events for v1.9 completions** (round-10 F4). Same theoretical bypass as #2.
4. **Codex `accepted_with_evidence` is honored only as advisory** — runner ignores it; operator must address the actual finding (no separate disposition step yet).
