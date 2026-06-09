# PreToolUse payload fixtures

> Status: **load-bearing artifact for v2.3 task #133 slice 1** (MAJOR M2
> closure from the Codex addendum, 2026-06-08).
> See [`../../../docs/FDTDD-SLICE1-PRECHECKLIST.md`](../../../docs/FDTDD-SLICE1-PRECHECKLIST.md)
> Claim 4 for context.

## What these are

The FDTDD Stage 1 proposal originally specified Gate 1 / Gate 3 to
"check ALL files" of a `MultiEdit` invocation. Codex's adversarial
review flagged this as likely wrong — `MultiEdit` is single-file in
Claude Code (one `file_path` plus an `edits` array). Slice 1 settles
the question with documented payload fixtures so slice 2's Gate 1
parser has a concrete spec to write against, and slice 4's Gate 3
parser inherits the same shape.

These fixtures are NOT executed by CI in slice 1. They are
specification artifacts. Slice 2 will refine them by capturing
literal payloads from a live PreToolUse hook running against a real
Edit / Write / MultiEdit invocation and noting any divergence.

## Fixtures

| File | Tool | Shape |
|---|---|---|
| `edit.json` | `Edit` | Single `file_path`, single replacement (`old_string` → `new_string`). |
| `write.json` | `Write` | Single `file_path`, full `content`. |
| `multi-edit.json` | `MultiEdit` | **Single** `file_path`, array of `edits` (each `{old_string, new_string, replace_all?}`). |

## Source

Each fixture's `_source` field cites the Claude Code tool reference
docs (`code.claude.com/docs/en/tools`) used to construct the
payload. Slice 1 fixtures are spec-driven; slice 2 fixtures will
be capture-driven.

## Gate parser implications (slice 2 + slice 4)

**Single-file tools (`Edit`, `Write`, `MultiEdit`):**
Gates read `tool_input.file_path` directly as a single string.
There is NO per-edit fan-out. The proposal §5 line 389–393 spec
"check ALL of them" is **dropped** — replaced with single-file
canonicalization + comparison against `test_files` / `prod_files`
in the active marker.

**Content scanning (for future content-based gates):**
- `Edit` content: `tool_input.new_string`.
- `Write` content: `tool_input.content`.
- `MultiEdit` content: `tool_input.edits[].new_string`. Iterate.

## How to refine in slice 2

1. Install a temporary PreToolUse hook that JSON-dumps stdin to
   `/tmp/pretooluse-capture/<tool>-<timestamp>.json`.
2. Run each of: an `Edit`, a `Write`, a `MultiEdit` from a Claude
   Code session.
3. Compare the captured JSON to the spec fixtures here. Note any
   divergence in the slice 2 PR description.
4. If MultiEdit's `tool_input` shape differs from the
   `multi-edit.json` here, update the fixture AND the gate
   parser. The fixture is the contract.

## Canonicalization (M1)

The fixtures show repo-root-absolute `file_path` values. The Gate
1 / Gate 3 parser must canonicalize before comparison to
`test_files` / `prod_files`:

- `./x/../y` → `y` (path cleaning).
- Symlinks resolved via `pwd -P`-style realpath (same pattern as
  Gate 4's §6 canonicalization in `hooks/protect-tdd-artifacts.sh`).
- Repo-root-relative form is stored in the marker; the gate
  compares post-canonicalization repo-root-relative forms.

The fixtures show absolute paths because that is how Claude Code
emits them — the gate's first transformation step is the
absolute → repo-root-relative reduction.
