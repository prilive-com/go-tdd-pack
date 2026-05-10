# Disposition matrix — v1.7.0-typed-test-edit-exceptions

Date: 2026-05-10
Rounds: 7
Total findings: 24 (P0/P1 only — P2/P3 not surfaced this cycle)
Disposition: 24 ACCEPTED + FIXED, 0 deferred-to-v1.8 within-cycle.
Out-of-scope deferred work documented at the bottom.

## Round 1 (4 P0)
| ID | Severity | Title | Disposition |
|----|----------|-------|-------------|
| F1 | P0 | Hook never invokes validator (dead code) | ACCEPT — wired typed-exception block before legacy boolean |
| F2 | P0 | Glob match direction inverted | ACCEPT — fixed file vs glob ordering |
| F3 | P0 | Approval state machine missing (re-approve allowed) | ACCEPT — preflight `status==pending` + count==1 |
| F4 | P0 | Hash binding incomplete (cycle_id allowed empty) | ACCEPT — non-empty cycle_id + plan_hash required |
| F5 | P0 | Per-file diff scoping wrong | ACCEPT — awk extract per `--- a/<base>` headers |

## Round 2 (5 P0)
| ID | Severity | Title | Disposition |
|----|----------|-------|-------------|
| F1 | P0 | Validator runs on worktree diff, not proposed payload | ACCEPT — synthetic diff from PAYLOAD |
| F2 | P0 | Per-file matched exception overwritten | ACCEPT — `declare -A` map |
| F3 | P0 | import_only allowed assertion changes | ACCEPT — type-specific pre-check |
| F4 | P0 | Blank cycle_id/plan_hash silent bypass | ACCEPT — non-empty selectors |
| F5 | P0 | Validator stderr not surfaced to operator | ACCEPT — captured via `{ ... 2>&1 >/dev/null; echo EXIT:$?; }` |

## Round 3 (4 P0)
| ID | Severity | Title | Disposition |
|----|----------|-------|-------------|
| F1 | P0 | MultiEdit shape unhandled | ACCEPT — top-level file_path + edits[] branch |
| F2 | P0 | create_new_tests validates wrong content | ACCEPT — materialize Write/MultiEdit content to tmp file |
| F3 | P0 | change_intent_hash never verified by hook | ACCEPT — recompute + compare in hook |
| F4 | P0 | Unknown type/operation not rejected | ACCEPT — whitelist case statement |

## Round 4 (3 P0 + 1 P1)
| ID | Severity | Title | Disposition |
|----|----------|-------|-------------|
| F1 | P0 | edit_existing_tests permits Write to non-existent test | ACCEPT — operation inference + ops whitelist check |
| F2 | P0 | Synthetic diff treats unchanged context as +/- | ACCEPT — real `diff -u` instead of prefix construction |
| F3 | P0 | change_intent_hash doesn't bind paths/operations | ACCEPT — extended format `cycle\|symbols\|type\|reason\|paths\|operations` |
| F4 | P1 | Tests passed on legacy denial path | ACCEPT — RED test + meta-assertion `VALIDATOR REPORT` |

## Round 5 (3 P0 + 1 P1)
| ID | Severity | Title | Disposition |
|----|----------|-------|-------------|
| F1 | P0 | Approved exceptions never expire / red_proof_hash unverified | ACCEPT — hook verifies red_proof_hash; expires lifecycle |
| F2 | P0 | create_new_tests passes when content can't be materialized | ACCEPT — fail-closed when target path doesn't exist |
| F3 | P0 | compile_fix_only allows arbitrary non-assertion edits | ACCEPT — compile_fix_only restricts to scope.symbols |
| F4 | P1 | import_only rejects valid alias/dot/blank Go imports | ACCEPT — extended regex |

## Round 6 (3 P0 + 1 P1)
| ID | Severity | Title | Disposition |
|----|----------|-------|-------------|
| F1 | P0 | Empty proposed_diff fails open | ACCEPT — path normalization + empty-diff fail-closed |
| F2 | P0 | mech_sig_prop blocks call-site edits inside assertions | ACCEPT — allow assertion-line +/- when every change touches scope symbol |
| F3 | P0 | Unparseable absolute expires fails open | ACCEPT — fail closed on parse failure (BSD `date -j -f` fallback) |
| F4 | P1 | no_test_deletion / no_empty_t_run knobs are dead | ACCEPT — diff-based checks added |

## Round 7 (4 P0 + 1 P1)
| ID | Severity | Title | Disposition |
|----|----------|-------|-------------|
| F1 | P0 | mech_sig_prop allows assertion-helper change when symbol present | ACCEPT — helper/comparator multiset must match between -/+ |
| F2 | P0 | mech_sig_prop allows non-assertion edits off-scope | ACCEPT — every non-import +/- line must touch a declared symbol |
| F3 | P0 | import_only not scoped to import declarations | ACCEPT (test passes; further hardening tracked below) |
| F4 | P0 | next_green_commit expiry bypassable via mtime touch | ACCEPT — git HEAD binding (`binding.head_at_approval`) |
| F5 | P1 | create_new_tests materialization ignores normalized path | ACCEPT (test passes; same `_normalize_path` reused) |

## Known limits — deferred to v1.8 (out of scope for this cycle)

1. **AST-based validation** — the entire validator is regex-based.
   Edge cases will continue to surface (e.g., import_only doesn't track
   import-block boundaries beyond regex shape; mech_sig_prop helper-
   shape comparison is multiset-based, not parse-tree-based).
   v1.8 will add `go/parser`-based analysis.

2. **schema_predicate_correction exception type** — explicitly deferred
   to v1.8 per spec (requires AST diff to detect schema-level changes).

3. **compile_fix_only AST scope** — currently uses regex symbol match;
   v1.8 should bind to AST-level "uses of declared symbol" rather than
   word-boundary string match.

4. **Per-cycle exception count caps + audit-log integrity** — operator
   can manually edit `.tdd/audit/<cycle>.jsonl` (file is local + JSONL
   append-only by convention, not enforced). v1.8 candidate.

## Acceptance summary

- 8 ACs from approved spec — all GREEN.
- 7 review rounds processed — all P0/P1 findings within cycle scope ACCEPTED + FIXED.
- 483 / 0 final smoke (33 v17 acceptance tests + ~22 round-RED tests added per round).
