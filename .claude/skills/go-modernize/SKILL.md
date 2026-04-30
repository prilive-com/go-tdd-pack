---
name: go-modernize
description: Apply Go 1.26 modernization analyzers to bring code up to current idioms. Use after dependency bumps, during cleanup passes, or when reviewing a stale module.
license: MIT
version: 1.0.0
---

# Go Modernize

Run Go 1.26's modernization analyzers to bring a package or module up to
current idioms. This is not a required cleanup — it's a periodic pass
that reduces cognitive load for the next reader.

## Prerequisites

- Go 1.26.0 or newer (`go version`). This skill assumes the rewritten
  `go fix` that ships with 1.26. If on 1.25 or older, stop — the old
  `go fix` only handles API migrations, not idiom modernization.
- Clean working tree. Commit or stash pending changes first.
- Working CI (`go test ./...` passes) before starting.

## Step 1: Survey

```bash
go version   # confirm 1.26+
go fix -diff ./... | head -200
```

Skim the diff for:

- **Surprises**: any change you wouldn't want (rare, but possible in
  generated code or hand-tuned hot paths). These go on a skip list.
- **Volume**: if it's hundreds of files, split the modernization across
  multiple PRs by package/subtree rather than one megadiff.

## Step 2: Know which analyzers run

Go 1.26's `go fix` runs the modernize analyzer set. Key transformations:

| Pattern                                  | Becomes                              |
|------------------------------------------|--------------------------------------|
| `var x = new(T); *x = v`                 | `x := new(v)` (Go 1.26 `new(expr)`)  |
| `interface{}`                            | `any`                                |
| `fmt.Sprintf("%s", x)` where x is string | `x`                                  |
| Manual `min(a, b)` / `max(a, b)` helpers | Built-in `min` / `max`               |
| Manual map-clearing loops                | `clear(m)`                           |
| Manual slice-clearing loops              | `clear(s)`                           |
| `sort.Slice` + comparison func           | `slices.SortFunc`                    |
| `reflect.DeepEqual` on slices            | `slices.Equal` / `slices.EqualFunc`  |
| `reflect.DeepEqual` on maps              | `maps.Equal` / `maps.EqualFunc`      |
| `for i := 0; i < len(s); i++`            | `for i := range s` (when i-only)     |

## Step 3: Apply in scope

Work package-by-package, not module-wide.

```bash
go fix ./internal/orders/...
go test -race -count=1 ./internal/orders/...
```

After each package:

- Run tests including `-race`.
- Run `go vet ./...` (no new warnings).
- If tests pass and vet is clean, commit.
- If tests fail, `git diff` the package and find the transformation that
  changed semantics. Revert just that file and file an issue.

## Step 4: Post-modernize review

After the modernize commits, look for things `go fix` can't do:

- **Struct fields that should be private**: exported fields with no
  external callers.
- **Unused exports**: run
  `go run golang.org/x/tools/cmd/deadcode ./...`.
- **Overly-broad interfaces**: interfaces with more methods than any
  caller actually uses. Consider splitting.
- **`context.TODO()` or `context.Background()` in handler paths**:
  modernize won't touch these — fix manually if obvious, else file a
  follow-up.

## Step 5: Commit hygiene

One commit per logical change. Do NOT mix modernize with functional
changes in the same commit. If you notice a real bug during modernize,
file it and fix it in a separate PR.

## What modernize does NOT do

- It does not upgrade dependencies.
- It does not refactor architecture.
- It does not fix `go vet` findings.
- It does not run `gofmt` or `goimports` (the post-edit hook does that).

## Anti-patterns

- **Running `go fix ./...` on the whole module in one commit.**
- **Ignoring `-race` failures that only appear after modernize.** If a
  race test fails now but passed before, the modernize change likely
  exposed an existing race, not introduced one. Fix the race.
- **"While I was modernizing, I also refactored…"** Separate PR.
