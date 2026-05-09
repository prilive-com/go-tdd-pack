# Bugfix Plan: layer-0-rescue-cached-first — fold in F2-cycle leftover + close all bypass classes

Status: active
Cycle ID: layer-0-rescue-cached-first
Change type: bugfix (rescue cycle for prior cycle's missed work)
Tier: 1

<!-- TDD ceremony markers. Set each ONLY after the matching operator APPROVED reply. -->
Bug reproduced: yes
Human approved spec: yes
Red phase confirmed: yes
Green phase authorized: yes
Implementation reviewed: yes
Fix applied: yes
Regression tests added: yes
Bug-elsewhere check complete: yes

## Bug

The F2 commit message (758894a) advertised a Layer 0 false-positive
fix ("cached diff first; fall back to working-tree only when cached is
empty") but the actual code committed in 758894a still had the buggy
`{ git diff --cached; git diff } | awk` pattern. The Layer 0 fix and
its smoke test sat in the working tree, never committed.

Discovered while preparing the F1 commit: `git diff HEAD` against
gate-tier1-commit.sh showed the leftover. Layer 0's smoke test passed
locally only because tests run against the working-tree hook, not HEAD.
CI would have failed.

## Iteration history (8 rounds of /second-opinion)

The simple "ship the leftover fix" task expanded into 8 rounds because
Codex found progressively narrower bypass cases against any literal-
text parser of `git commit ...`:

  R1 P1: cached-emptiness was the wrong proxy → -a/--all detection
  R2 2× P2: word-splitting + end-of-options → xargs tokeniser, --, scan-after-commit
  R3 P1+3× P2: pathspec bypass + attached short args + weak tests + weak fixture
       → COMMIT_MODE_PATHSPEC + -m*/-F*/-c*/-C*/-S* + jq decision parsing
  R4 3× P1: bare -S, --interactive/--patch/-p, --pathspec-from-file
       → -S optional-arg, pathspec-mode triggers
  R5 P1: clustered -pm not detected → cluster scanning for 'p'
  R6 P1: abbreviated long opts (--intera = --interactive) → ARCHITECTURAL PIVOT:
       UNCERTAIN backstop classifies any unrecognised `--*` as conservative
       (uses diff HEAD --numstat). Closes the iteration loop by construction.
  R7 P1+P2: shell variable expansion, empty-index PLAIN fallback
       → unescaped $/backtick → UNCERTAIN; PLAIN with empty cached → CHURN=0
  R8 3× P0+P1: glob expansion, sh -c wrapping, git aliases, header docs
       → glob char (* ? [) → UNCERTAIN; sh -c and git aliases documented as
       gate-level limitations (deferred follow-up cycle)

## Reproduction

Stash the working-tree fix; run the false-positive smoke test against
the buggy HEAD code:

```
git stash push .claude/hooks/gate-tier1-commit.sh
bash scripts/tdd-test-hooks.sh 2>&1 | grep "false-positive closed"
# FAIL: 103 lines counted from unstaged WIP, denying small staged commit
git stash pop
```

## Acceptance criteria

1. `git commit -m` plain with small staged + large WIP → ALLOW (F2 preserved)
2. `git commit -am`, `-a -m`, `-pm` (cluster), pathspec, --interactive,
   --patch, --pathspec-from-file (both forms) → DENY on WIP
3. `git commit --amend --no-edit`, `--signoff`, `--reset-author` etc. → ALLOW
4. Abbreviated long opts (--intera, --patc, future flags) → DENY (UNCERTAIN backstop)
5. Shell expansion ($, backtick, glob *, ?, [) → DENY (UNCERTAIN backstop)
6. PLAIN mode with empty index → CHURN=0 (no working-tree fallback)
7. All 8 rounds of Codex findings closed or documented as out-of-scope

## Affected code

- `.claude/hooks/gate-tier1-commit.sh` — option parser + UNCERTAIN backstop
- `scripts/tdd-test-hooks.sh` — 12 new tests (R1-R8 closure + regressions)

## Non-goals

- Closing `sh -c 'git commit -a'` and `git -c alias.ci=commit ci` bypasses.
  These are gate-level (COMMITS_RE doesn't match), not parser-level.
  Documented in hook header; queued for follow-up cycle that broadens
  the gate's command-detection regex or moves to git pre-commit hooks.

## Risk register

| Risk | Mitigation |
|---|---|
| Future git release adds a new long opt that adds working-tree content; UNCERTAIN whitelist doesn't include it | Default-deny behavior is correct (fail closed). Add to whitelist when triggered. |
| Legitimate commit message contains $ or * (e.g., `git commit -m "fix: $5 bug"`) | UNCERTAIN → operator runs /second-opinion to bypass. Friction but safe. |
| Nested shell or git alias bypasses Layer 0 entirely | Documented as out-of-scope; follow-up cycle. |
