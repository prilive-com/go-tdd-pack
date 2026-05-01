---
name: new-module-scaffold
description: Scaffold a new Go service, package, or subsystem following the existing repo conventions (matches existing structure, names, entry points, test layouts). Use when the user asks to scaffold, create, or set up a new package / module / service / binary / worker / handler.
license: MIT
version: 1.1.0
---

# New Module Scaffold

Create a new logical unit (service, package, module, subsystem) in this
repo without guessing at structure or leaving missing pieces.

## Step 1: Before writing anything, ask

- What kind of unit is this?
  - Standalone binary (CLI tool, worker, HTTP server)
  - Library / internal package (not separately deployed)
  - Shared module (used by multiple binaries)
- Where do other units like this live in the repo?
- What's the naming convention — find 2–3 existing examples and match
  them.

Do not propose a layout before reading existing code. Every repo has
conventions; guessing violates them.

## Step 2: Match existing conventions

Read 2–3 existing modules of the same kind. Specifically note:

- Directory structure (`cmd/<name>/`, `internal/<area>/<name>/`)
- File naming conventions
- Entry point conventions (`main.go`, package init)
- Test file locations and naming
- Configuration loading pattern
- Logging setup pattern (`log/slog`)
- Error handling pattern

## Step 3: Propose the layout

State explicitly:

- Directory path
- Each file to create and its one-line purpose
- Which existing files/packages will import this new module
- Which tests will be created alongside

Wait for user confirmation before creating files. Do not create and ask
forgiveness; scaffolding is irreversible in practice.

## Step 4: Create, but minimally

- One entry-point file with a skeletal implementation
- At least one smoke test (confirms it builds and loads)
- A doc comment at the top of the main file stating the module's purpose
- Any necessary build-system registration

Do NOT scaffold:

- Empty utility files that might be needed later
- Speculative interfaces for features not yet designed
- Full CRUD/handler sets before the caller actually needs them

## Step 5: Verify the scaffold builds

After creating, run:

```bash
go build ./...
go test -race -run TestSmoke ./...
```

Report the result. If the scaffold doesn't compile, fix it before
handing off.

## Anti-patterns

- Generating 20 boilerplate files because "a service usually has these."
  Most don't.
- Copy-paste from a similar module without adapting names, imports, and
  tests — the result compiles but is structurally wrong.
- Skipping the smoke test because "it's just a scaffold."
