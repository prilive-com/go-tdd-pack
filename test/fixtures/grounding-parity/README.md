# Grounding parity fixtures

> Status: **load-bearing artifact for v2.3 task #107 slice 1**.
> See [`../../docs/GROUNDING_ADAPTER_INTERFACE.md`](../../docs/GROUNDING_ADAPTER_INTERFACE.md)
> for the contract these fixtures verify.

## What these are

Slice 1 of the grounding-adapter interface (task #107) ships these
fixtures so slice 2's refactor of `runner/tool-grounding.sh` can be
verified for **byte-for-byte parity** with current behavior. Without
the parity check, slice 2 could silently change Go-only adopters'
grounding output — and Codex (the reviewer) consumes that output
verbatim, so any change risks reviewer behavior drift.

The fixtures are NOT executed by CI in slice 1. Slice 2 will add
`test/smoke-grounding-parity.sh` that:

1. Reads the current host's tool inventory.
2. Compares against each fixture's `tool-inventory.txt`.
3. For each matching fixture, sets up a temp git repo from
   `project/`, applies the documented "change" pattern (untracked
   file with the expected name), runs the refactored runner, and
   compares stdout to `expected.md` byte-for-byte.
4. **Fails loud** on any divergence.

If the host's tool inventory does NOT match a fixture's, that
fixture's parity check is SKIPPED (with a clear note in the smoke
output). This keeps the smoke usable across heterogeneous developer
machines.

## Cases

| Case | What it covers | Tool inventory |
|---|---|---|
| `case-01-single-go-module/` | The default v2.x scenario: one Go module, one new file added in the diff. The minimum viable parity check. | go + gofmt installed; staticcheck/golangci-lint/govulncheck/gosec missing |

Future v2.3 slices may add more cases (multi-module monorepo,
no-go-mod-orphan-go-files, polyglot Go + Python once a sibling pack
ships). Slice 1 ships ONE case so the contract spike is concrete
without slipping into "build all the cases first".

## Per-case structure

```
case-XX-<short-name>/
  README.md                  # optional; case-specific notes
  capture.sh                 # regeneration script (also the procedure)
  project/                   # the fixture Go project (the "before" state)
    go.mod
    *.go
  expected.md                # captured runner output (the byte-for-byte target)
  tool-inventory.txt         # which tools were installed at capture time
  changed-files.txt          # the set of "changed files" the runner saw
```

`capture.sh` is the source of truth for how the fixture is built.
Reading it tells you exactly:

- How the temp git repo is set up.
- What "change" pattern produces the fixture's diff.
- Which `runner/tool-grounding.sh` invocation generates `expected.md`.

## How to regenerate expected.md

You should regenerate when ANY of these is true:

- `runner/tool-grounding.sh` changes its output format intentionally
  (rare; always paired with a CHANGELOG note).
- A fixture's `project/` files change.
- You're capturing on a NEW host whose tool inventory differs from
  the existing `tool-inventory.txt`.

To regenerate:

```bash
cd test/fixtures/grounding-parity/case-XX-<short-name>/
bash capture.sh
```

The script overwrites `expected.md`, `tool-inventory.txt`, and
`changed-files.txt` in place. Review the diff before committing:

```bash
git diff test/fixtures/grounding-parity/case-XX-*/
```

If the diff shows ONLY tool-inventory changes (e.g. you installed
staticcheck since the last capture), that's expected — commit it.
If the diff shows output format changes, decide whether they are
intentional (paired CHANGELOG note) or a regression (revert).

## Why a temp git repo, not the live repo

`runner/tool-grounding.sh` reads changed files via:

```bash
git diff --name-only HEAD
git ls-files --others --exclude-standard
```

Both are git-repo-dependent. Using the live repo would couple the
fixture to whatever's in the maintainer's working tree at capture
time. The temp-repo approach makes capture deterministic and
reproducible across hosts.

## What slice 2 must NOT change without a CHANGELOG note

After slice 2 lands, the fixtures' `expected.md` files become the
contract. Slice 2's refactor:

- **MUST** reproduce each fixture's `expected.md` byte-for-byte
  on hosts with matching tool inventory.
- **MAY** add support for sibling-pack adapters via the
  `[grounding] adapters` config, but the default `adapters = ["go"]`
  configuration must preserve fixture parity.
- **MUST NOT** change the output format for the single-adapter mode
  (header, per-tool sections, skipped/timeout/clean messages,
  truncation notices) without a paired CHANGELOG note AND a
  fixture refresh.

Slice 2's smoke is the load-bearing check on this contract. Don't
weaken it.
