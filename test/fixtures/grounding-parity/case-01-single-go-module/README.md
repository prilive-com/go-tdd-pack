# case-01-single-go-module

Smallest meaningful grounding-parity case: one Go module, one new
file added as the "change".

## What this case covers

- **Discovery**: changed-files walk to nearest non-empty `go.mod`.
  The fixture has `go.mod` at the project root, so the only
  affected module is `.` (the root).
- **Output structure**: header (legacy single-adapter mode),
  summary, one `## Module:` section, one `### <tool>` line per
  tool, status section per tool.
- **Tool inventory mismatch handling**: the fixture documents
  which tools were installed at capture time; slice 2's parity
  smoke compares against the current host's inventory and skips
  this case if they differ.

## What this case does NOT cover

These are intentional gaps for v2.3 slice 1:

- Multiple modules (covered by a future case).
- No-go-mod orphan Go files (covered by a future case).
- Polyglot Go + Python output composition (waits on a sibling-pack
  adapter shipping).
- A change that triggers actual tool findings (e.g. a deliberate
  staticcheck violation). The current case captures clean output
  for everything available; covering tool-violation output requires
  staticcheck installed at capture time, which is not the case in
  v2.3 slice 1.

Slice 2 may add a `case-02-with-violations/` if it has access to
the full tool set. For slice 1's purposes, the clean-output case
is sufficient to prove byte-for-byte parity on the structural
contract.

## Files

| File | Purpose |
|---|---|
| `project/go.mod` | Single-module Go project root. |
| `project/calculator.go` | Initial source file (committed before the "change"). |
| `project/calculator_test.go` | Test file (committed before the "change"). |
| `capture.sh` | Regeneration script. Run on any host to refresh the captured artifacts. |
| `expected.md` | The byte-for-byte parity target. |
| `tool-inventory.txt` | Which tools were installed at capture time. |
| `changed-files.txt` | What the runner saw as the "changed" file set. |

## The "change"

The `capture.sh` script:

1. Commits `project/` as the initial state.
2. Creates a new file `calculator_div.go` (untracked).
3. Runs `runner/tool-grounding.sh` on the temp repo.

The runner's `collect_changed_files()` picks up `calculator_div.go`
via `git ls-files --others --exclude-standard`. That's the
fixture's "change".

To regenerate: see [`../README.md`](../README.md) §"How to regenerate
expected.md".
