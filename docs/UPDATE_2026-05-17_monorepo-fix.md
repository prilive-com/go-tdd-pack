# Update Patch — 2026-05-17 (monorepo-aware tool grounding)

Same-day follow-up patch to `UPDATE_2026-05-17.md`. Apply this if your
project already pulled the original 05-17 update (commit `12eceb8`) and
your repo layout has any of:

- a monorepo with multiple `go.mod` files at different depths
- no `go.mod` at the repo root (modules live in subdirectories)
- a polyglot repo where Go code is one of several languages
- a `vendor/` directory that shouldn't be linted

If your project is a flat single-module Go repo with `go.mod` at root,
this patch is still safe to apply (behavior is unchanged for that case),
but you can skip it if you want.

---

## What this patch fixes

**The bug:** `runner/tool-grounding.sh` checked for `go.mod` at
`PROJECT_DIR` root and silently no-opped if absent. Monorepos with
`services/api/go.mod`, `services/lib/go.mod`, etc. got zero tool
grounding without any indication something was wrong — Codex reviewed
without lint/vet/staticcheck/govulncheck evidence and didn't know the
evidence was missing.

**The fix:** discovery is now diff-driven. The script walks each
changed file up to its nearest non-empty `go.mod`, dedupes the result,
and runs tools per affected module. Works for any Go repo layout:
single-module, monorepo, nested modules, polyglot, no-Go-at-all.

**Cardinal principle now enforced:** never silently skip. The script
always emits a status section telling Codex what it did (or did not)
analyze, so absent tool grounding is visible signal rather than missing
signal.

---

## Files to update

**Modified:**
```
runner/tool-grounding.sh
docs/UPDATE_2026-05-17.md        # has a "FOLLOW-UP PATCH" section appended
```

**New:**
```
test/smoke-tool-grounding.sh     chmod +x after copy
```

No changes to any other file. No schema changes. No prompt changes. No
config changes. No `.claude/settings.json` changes.

---

## Step-by-step

Assuming the starter is at `~/go-projects-claude-starter` and your
project is `~/myproject`:

```bash
cd ~/myproject

cp ~/go-projects-claude-starter/runner/tool-grounding.sh           runner/
cp ~/go-projects-claude-starter/test/smoke-tool-grounding.sh       test/
chmod +x runner/tool-grounding.sh test/smoke-tool-grounding.sh

# Verify the new fixture smoke (12 assertions, no Codex calls, ~2s)
bash test/smoke-tool-grounding.sh

# Verify the existing Phase 2 unit smoke didn't regress (25 checks)
bash test/smoke-v2-phase2.sh
```

Expected output from the new smoke:
```
================================================================
  TOOL-GROUNDING SMOKE — PASS (12 checks)
================================================================
```

---

## What changes in observable behavior

### For monorepos (the bug case)

**Before:** silent. The `## Tool grounding` block was missing from
Codex's prompt entirely. Codex reviewed without static-analysis
evidence and didn't know it was missing.

**After:** one section per affected module. Example for an edit to
`services/api/main.go` in a multi-module repo:

```
## Tool grounding (pre-executed before this review)

**Summary:** 1 affected Go module(s), 1 affected file(s).

## Module: `services/api`

### gofmt -l ./...
(clean)

### go vet ./...
(clean)

### staticcheck ./...
(clean)

### golangci-lint run
internal/handler.go:42:3: ineffective assignment (ineffassign)

### govulncheck ./...
(clean)
```

Untouched modules (e.g. `services/worker`) are not analyzed — no
wasted tool runs.

### For flat single-module repos (no behavior change)

You still get one `## Module: \`.\`` section with the same tool output
as before. The new code path collapses to the old behavior when there
is one `go.mod` at root.

### For non-Go diffs (README, docs, configs only)

**Before:** ran tools at PROJECT_DIR anyway, producing noise.

**After:** explicitly says so:
```
## Tool grounding (pre-executed before this review)

(no module-affecting files in this diff)

Diff includes 3 changed file(s); none matched the tool-grounding
predicate (no .go, go.mod, go.sum, go.work, or .golangci.yml
changes outside vendor/testdata/node_modules).

Codex should review the diff without tool-derived evidence.
```

Codex now knows the absence of findings is intentional, not a tool
failure.

### For orphan Go files (no enclosing go.mod)

**Before:** silent skip (couldn't find root `go.mod`).

**After:** explicit report:
```
## Tool grounding (pre-executed before this review)

(Go files changed but no enclosing go.mod found)

Could not walk any changed file up to a non-empty go.mod. Either
the project is not Go, the relevant go.mod is missing, or the
enclosing go.mod is empty (Grab "exclude this subtree" marker).

Orphan Go files in this diff:
  - example/orphan.go

Codex should investigate the repo layout.
```

### Other edge cases handled

| Layout | Behavior |
|---|---|
| `vendor/` change only | Excluded from predicate → "no module-affecting files" |
| Empty `go.mod` (Grab-style exclude marker) | Walk stops at the marker → no module registered for that subtree |
| `testdata/` change only | Excluded |
| `node_modules/` change only | Excluded |
| `.golangci.yml` change | Treated as module-affecting (lint policy change) |
| `go.mod` / `go.sum` / `go.work` change | Treated as module-affecting (dependency change) |

---

## What the AI doing the coding should do differently

**Nothing.** The runtime behavior of the cycle is unchanged — runner
still fires, findings still inject, Stop hook still captures responses,
escalation still works. The only difference is that Codex's prompt now
contains richer tool grounding on monorepos that previously got none.

If you happen to be reviewing a diff in a monorepo, you may see Codex
cite findings from specific tools (`staticcheck` / `golangci-lint` / etc.)
more often, with higher confidence scores. That's expected — Codex has
real evidence now.

---

## What this patch deliberately does NOT do

Listed explicitly so future updates don't re-add scope by accident:

| Not included | Why |
|---|---|
| Bazel / Buck2 / Pants build-system orchestration | We're a review-grounding script, not a build orchestrator. Native Go tools work in Bazel-managed Go repos that keep their `go.mod` files. |
| `go.work` GOWORK=on/off mode toggle | Niche. Add when a real user hits the case. |
| `go test -race ./...` per cycle | 30s–10min per affected module. Would make cycles unusable even on a free subscription. Tests are the developer's responsibility, not the reviewer's. |
| `gosec` security scanning | High false-positive rate. Codex flags real security issues with full file access. |
| `.prilive/config.toml` escape hatch | We already have `tdd-pack.toml`. Don't add a second config file. |
| Self-bootstrap tool installer | Surprising side effect; user environment should stay under user control. |
| `merge-base HEAD origin/main` BASE_REF | Wrong model. The pack reviews working-tree edits during a Claude session, not PR-vs-base. `git diff HEAD` is correct. |
| 22-fixture test matrix | Excessive. 6 essential fixtures cover the real failure modes. |

If any of these become real problems on your project, that's the
trigger to revisit — driven by evidence, not speculation.

---

## Rollback

If anything breaks:

```bash
cd ~/myproject
git -C ~/myproject revert <commit-of-this-patch>
```

Or restore the previous `runner/tool-grounding.sh` from your last
working checkout. The change is contained to one script + one new test
file; the runner contract is unchanged.

---

## Pin

This patch brings adopter projects to **commit `4005167`** of the
starter (script + smoke). To verify:

```bash
[[ -f test/smoke-tool-grounding.sh ]] && echo "patch applied" || echo "not yet"
```

Or inspect `runner/tool-grounding.sh` for the string
`nearest_gomod_dir` — present means patched, absent means pre-patch.
