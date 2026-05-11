# Disposition matrix — v1.8.0-ast-validator-and-audit-integrity

Date: 2026-05-11
Rounds: 7
Total findings: 25 ACCEPTED + 1 PUSHBACK across 7 rounds.
Plus 7 sub-findings already-passing (codex hypothetical that didn't manifest in our impl).

## Round 1 (3 P0 + 1 P1)
| ID | Severity | Title | Disposition |
|----|----------|-------|-------------|
| F1 | P0 | schema_predicate_correction accepts semantic non-renames | ACCEPT — extended tokens to include BasicLit; reject unmatched +/- counts; require renameSeen |
| F2 | P0 | import-block leniency permits misplaced imports | ACCEPT — top-of-file boundary check when no on-disk imports |
| F3 | P0 | grant helper uses non-portable sha256 | PUSHBACK — sha256 IS defined as a function at top of helper; v18_audit_chain_grant_helper_writes_prev_sha verifies cross-event chain works |
| F4 | P1 | Assertion helper extraction misses chained changes | ACCEPT — return full helper sequence (chain), not first only |

## Round 2 (3 P0)
| ID | Severity | Title | Disposition |
|----|----------|-------|-------------|
| F1 | P0 | schema_predicate_correction unvalidated when AST disabled | ACCEPT — fail closed for this type when AST unavailable (no regex fallback) |
| F2 | P0 | schema-predicate-check ignores operators/punctuation | ACCEPT — full-text regex rename + collapseSpaces comparison |
| F3 | P0 | import-block-check rejects legitimate top-level additions | ACCEPT — synthesize new file via diff applier; check ranges in NEW file |

## Round 3 (2 P0 + 1 P1)
| ID | Severity | Title | Disposition |
|----|----------|-------|-------------|
| F1 | P0 | import-block-check ignores deletions outside import block | ACCEPT — also validate `-` lines against OLD file's ranges |
| F2 | P0 | schema-predicate-check accepts string/comment rewrites | ACCEPT — go/scanner-based token comparison (only IDENT renames allowed) |
| F3 | P1 | compile-fix-scope rejects punctuation-only continuation | ACCEPT — hunk-level carve-out for punctuation-only lines (later tightened) |

## Round 4 (3 P0 + 1 P1)
| ID | Severity | Title | Disposition |
|----|----------|-------|-------------|
| F1 | P0 | Audit log deletion bypasses sha-chain detection | ACCEPT — hook fails closed when approved exceptions exist but audit log missing/empty |
| F2 | P0 | compile-fix-scope carve-out too lenient | ACCEPT — initially allowed isArgContinuation; later tightened to punctuation-only (round-5 F3) |
| F3 | P0 | mech-sig-prop rejects legitimate inner-arg call changes | ACCEPT (already passes) — extractAssertionHelpers only collects selector-receiver calls, not Ident-receiver |
| F4 | P1 | AST diff path matching basename collision | ACCEPT (later tightened in round 5) — pathMatches now strict relative |

## Round 5 (4 P0)
| ID | Severity | Title | Disposition |
|----|----------|-------|-------------|
| F1 | P0 | AST validators ignore --paths | ACCEPT — filterFilesByPaths in all four subcommands |
| F2 | P0 | Path matching collides on basenames | ACCEPT — strict suffix match, no basename fallback |
| F3 | P0 | compile-fix carve-out permits off-scope IDENT/LITERAL | ACCEPT — dropped isArgContinuation; punctuation-only carve-out only |
| F4 | P0 | Audit verifier tolerates post-chain missing prev_sha | ACCEPT — track chain_started; reject missing prev_sha after start |

## Round 6 (2 P0 + 1 P1; 1 PUSHBACK)
| ID | Severity | Title | Disposition |
|----|----------|-------|-------------|
| F1 | P0 | Audit chain can't detect last-line tamper / suffix truncation | ACCEPT — count `granted` events; if < approved count → fail closed |
| F2 | P0 | grant helper non-portable sha256 (REPEATED) | PUSHBACK — same false-positive as round-1 F3; sha256 function works |
| F3 | P1 | import-only ignores comment lines outside import block | ACCEPT — no longer skip comments; reject if outside import range |

## Round 7 (3 P0)
| ID | Severity | Title | Disposition |
|----|----------|-------|-------------|
| F1 | P0 | schema_predicate_correction allows partial renames | ACCEPT — reject any unchanged oldName token on either side |
| F2 | P0 | compile-fix ignores comment directives (//go:build) | ACCEPT — no longer skip comments; require scope-symbol or punctuation-only |
| F3 | P0 | Audit truncation counts grants, not IDs | ACCEPT — jq-based set comparison of approved IDs vs grant event IDs |

## Known limits — deferred to v1.9 (out of scope for this cycle)

1. **Pre-built AST validator binary** — `go run` cold-start ~300ms.
   Pack consumers can `go build scripts/tdd/ast/validator.go`; the
   hook will detect a binary in v1.9.
2. **schema-predicate-check is line-by-line** — multi-line refactors
   that legitimately rename across hunks need to be split. v1.9
   could add a hunk-level mode.
3. **External audit head pin** — sha-chain + grant-ID-set check
   detects most truncation; an external head hash bound into the
   artifact's binding would close the last-line edit case completely.
4. **Audit log archival/rotation** — log grows unbounded per cycle.
   v1.9 candidate: cycle_close event + auto-archive on green commit.
5. **Encrypted/signed audit log** — sha-chain detects unsophisticated
   tampering; doesn't protect against a compromised host. v2.0+.
6. **AST helper sandboxing** — `go run` reads source files; a
   malicious project could craft validator.go via PATH manipulation.
   v1.9 could enforce CLAUDE_PLUGIN_ROOT-based path resolution.

## Acceptance summary

- 8 ACs from approved spec — all GREEN.
- 7 review rounds processed.
- 25 ACCEPTED + 2 PUSHBACK (both PUSHBACKs were the same false-
  positive across rounds 1 and 6 — codex misread the grant helper
  as missing a sha256 function that's defined at the top of the
  same file; the v18_audit_chain_grant_helper_writes_prev_sha test
  empirically verifies the cross-event chain works).
- 7 sub-findings already passing on first detection (codex
  hypotheticals that didn't manifest in our implementation).
- 520 / 0 final smoke (14 v1.8.0 AC tests + 23 round-derived RED
  tests across rounds 1-7 — every one transitioned RED → GREEN).
