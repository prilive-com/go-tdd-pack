# Monorepo Adoption Guide — Prilive Go TDD Pack v2.0

> **Audience:** Adopters with Go monorepos, multi-module repos, nested
> modules, or polyglot layouts.
>
> If you have a flat single-module Go repo (`go.mod` at root), this
> guide is optional. The pack works out of the box for that case. Read
> [`ADOPTION_GUIDE.md`](ADOPTION_GUIDE.md) instead.

---

## Supported layouts

| Layout | Status |
|---|---|
| Single-module repo (`go.mod` at root) | ✓ Fully supported |
| Monorepo with multiple `go.mod` files at any depth | ✓ Fully supported (one section per affected module) |
| Nested modules (child `go.mod` inside parent module) | ✓ Walked nearest-first per Go semantics |
| Polyglot monorepo (Go + non-Go) | ✓ Only Go-affected modules are tooled |
| Repo with no Go code at all | ✓ Pack emits "no Go modules touched" status |
| `vendor/`, `testdata/`, `node_modules/` | ✓ Excluded from analysis |
| Empty `go.mod` (Grab-style exclude marker) | ✓ Honored — walk stops at the marker |

**Not in scope** (no plans unless real demand):

- Bazel / Buck2 / Pants build system orchestration — out of scope as a
  review-grounding script; native Go tools still work inside Bazel
  repos that keep `go.mod` files.
- `go.work` workspace mode toggle (auto-on vs auto-off via env var) —
  niche; the pack runs per-module regardless of workspace mode.
- Git submodule recursion — the submodule's `.git` and contents are
  excluded; sub-pipelines are not invoked.

If your project hits one of these and the workaround is unacceptable,
open an issue with specifics.

---

## How the affected-module algorithm works

When you make changes and the runner fires, `runner/tool-grounding.sh`
does the following:

### Step 1 — Collect changed files

```bash
git diff --name-only HEAD            # staged + unstaged
git ls-files --others --exclude-standard   # untracked
```

Union, deduplicate. This is the candidate set.

### Step 2 — Filter to module-affecting files

A file passes if any of these match:

- `*.go` (including `*_test.go`)
- `go.mod`, `go.sum`, `go.work`, `go.work.sum`
- `.golangci.yml` / `.yaml` / `.toml` / `.json`

And is **not** under:

- `vendor/`, `*/vendor/*`
- `testdata/`, `*/testdata/*`
- `.git/`, `*/.git/*`
- `node_modules/`, `*/node_modules/*`

### Step 3 — Walk to nearest non-empty `go.mod`

For each surviving file, walk up the directory tree looking for the
nearest `go.mod`. Stop at the repo root. Two special cases:

- **Empty `go.mod`** (zero bytes): treated as the Grab "exclude this
  subtree" marker. The walk stops and the file is NOT mapped to any
  module.
- **No `go.mod` found** all the way up: the file is recorded as an
  orphan Go file and reported.

Deduplicate. Result: the **affected module set**.

### Step 4 — Emit status section

Three possible outcomes:

1. **`AFFECTED_MODULES` is empty AND no Go-y files matched** (e.g., the
   diff is README-only):

   ```
   ## Tool grounding (pre-executed before this review)

   (no module-affecting files in this diff)

   Diff includes N changed file(s); none matched the tool-grounding
   predicate. Codex should review the diff without tool-derived evidence.
   ```

2. **Go files matched but no enclosing `go.mod` found**:

   ```
   ## Tool grounding (pre-executed before this review)

   (Go files changed but no enclosing go.mod found)

   Orphan Go files in this diff:
     - example/orphan.go
     ...
   ```

3. **One or more modules affected**:

   ```
   ## Tool grounding (pre-executed before this review)

   **Summary:** 2 affected Go module(s), 7 affected file(s).

   ## Module: `services/api`

   ### gofmt -l ./...
   (clean)

   ### go vet ./...
   (clean)

   ### staticcheck ./...
   ...

   ## Module: `services/lib`

   ### gofmt -l ./...
   ...
   ```

The pack **never silently no-ops**. Codex always sees a status line
explaining what happened — visible degradation beats silent skip.

### Step 5 — Per-module tool invocation

For each module in the affected set, the runner cd's into the module
directory and runs:

```bash
gofmt -l ./...
go vet ./...
staticcheck ./...
golangci-lint run --timeout=50s ./...
govulncheck ./...
```

Each tool:
- Times out at 60s (configurable via `TOOL_GROUNDING_TIMEOUT_S`)
- Output capped at 4000 chars (configurable via `TOOL_GROUNDING_CHAR_CAP`)
- Skipped silently if not installed; the section shows `NOT INSTALLED`

Total output cap: 30000 chars (configurable via `TOOL_GROUNDING_TOTAL_CAP`).
On overflow, truncated with explicit notice.

---

## Layout examples

### Single-module repo

```
your-project/
├── go.mod
├── main.go
└── internal/
    └── service/
        └── service.go
```

Affected module set for any change is `{.}`. Tools run once at the
repo root.

### Top-level monorepo

```
monorepo/
├── services/
│   ├── api/
│   │   ├── go.mod
│   │   └── main.go
│   └── worker/
│       ├── go.mod
│       └── main.go
└── shared/
    ├── go.mod
    └── pkg.go
```

If you change `services/api/main.go` only, the affected set is
`{services/api}`. If you change both `services/api/main.go` and
`shared/pkg.go`, the affected set is `{services/api, shared}`.
Tools run independently in each module.

### Nested modules

```
parent/
├── go.mod
├── lib.go
└── examples/
    └── demo/
        ├── go.mod
        └── main.go
```

Changes to `examples/demo/main.go` map to `examples/demo` (nearest
`go.mod`). Changes to `lib.go` map to `.` (parent). Both can be in
the affected set if both change.

### Polyglot monorepo

```
project/
├── backend/
│   ├── go.mod
│   └── main.go
├── frontend/
│   ├── package.json
│   └── index.ts
└── infra/
    └── terraform/
        └── main.tf
```

Only `backend/` changes trigger tool grounding. Changes to `frontend/`
or `infra/` produce "no module-affecting files" because the predicate
filter doesn't match TypeScript or Terraform files. (If you want
multi-language adapter support, it would belong in a sibling plugin,
not this Go-specific pack.)

### Vendor changes

```
project/
├── go.mod
├── main.go
└── vendor/
    └── github.com/foo/bar/
        └── bar.go
```

Changes to `vendor/**` are excluded from the predicate. Result: "no
module-affecting files in this diff."

### Empty go.mod (Grab exclusion marker)

```
monorepo/
├── go.mod
├── main.go
└── tools/
    ├── go.mod          # ZERO bytes
    └── helper.go
```

Changes to `tools/helper.go` hit the empty `go.mod` on the walk-up
and produce "no enclosing go.mod found" with `tools/helper.go` listed
as orphan. Changes to `main.go` map to `{.}` normally.

This is the same convention Grab and some other large Go shops use to
keep linters from descending into subtrees they manage out-of-band.

---

## Verification

Verify monorepo behavior on your project before going live:

```bash
# Make a small change to a file in one module
echo '// smoke' >> services/api/main.go

# Run tool grounding manually
bash runner/tool-grounding.sh "$(pwd)" | head -30
```

Expected: `## Module: \`services/api\`` block with tool output, NO
section for other modules.

The pack's own fixture suite covers this and other cases:

```bash
bash test/smoke-tool-grounding.sh
```

Expected: `TOOL-GROUNDING SMOKE — PASS (12 checks)`.

Six fixtures cover single-module, monorepo (single touched), monorepo
(multiple touched), non-Go diff, orphan Go, vendor exclusion, and
empty-go.mod marker.

---

## Troubleshooting

**Symptom: "no module-affecting files" on every cycle, but I'm editing Go code.**

Likely you're invoking the runner from outside your project. The
runner uses `$CLAUDE_PROJECT_DIR` as the starting point. Make sure you
opened Claude Code from inside the Go project root, not from a parent
directory.

**Symptom: tool grounding shows the same module twice.**

Possible if you have unusual symlinks or a child `go.mod` that's
identical to its parent's path resolution. File an issue with your
repo layout if you hit this.

**Symptom: a module that should be analyzed is silently absent.**

Walk up by hand: `dirname` the changed file repeatedly looking for
`go.mod`. If a non-empty `go.mod` exists on the path, the script
should find it. Check that the file's actual path matches what
`git diff --name-only HEAD` reports (path normalization,
case-sensitivity).

**Symptom: a 5000-module monorepo runs too slowly.**

Each affected module runs all 5 tools serially. If you frequently
touch many modules at once, your cycles will be long. Mitigations:

- Drop tools you don't need (uninstall them; the pack will mark
  `NOT INSTALLED` and skip)
- Reduce `reasoning_effort` to `"high"` — that doesn't speed tool
  grounding, but does speed Codex reasoning
- Open an issue if you need per-module parallelization

---

## What was rejected from scope

For honesty about design choices: the original v2.0 implementation
checked for `go.mod` at `PROJECT_DIR` root only. It silently no-opped
on monorepos. The fix shipped on 2026-05-17 (commit `4005167`) is the
algorithm above.

The fix deliberately does NOT include:

- Bazel/Buck2/Pants auto-detection and target-graph queries
- `go.work` workspace mode toggles (`GOWORK=on/off`)
- Submodule recursion
- `.prilive/config.toml` repository override
- `--new-from-merge-base` filtering for golangci-lint
- A 22-fixture test matrix

These features were proposed by a consultant draft and rejected as
scope creep. If your project genuinely needs any of them, the right
path is to open an issue with evidence rather than re-architecting
the script preemptively. See `docs/UPDATE_2026-05-17_monorepo-fix.md`
for the full reasoning.

---

_Last updated: 2026-05-18 for v2.0._
