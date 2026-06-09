# Grounding Adapter Interface — v1

> Status: **authoritative contract** (slice 1 of v2.3 task #107).
> See [`PROPOSAL-grounding-adapter-interface.md`](PROPOSAL-grounding-adapter-interface.md)
> + its §12 Codex-review addendum for the design rationale.
> Slogan: **the language-specific bits are an adapter, not a fork.**

This file is the binding contract that v2.3+ grounding adapters
implement and that sibling packs (`py-dev-pack`, `ts-dev-pack`,
etc.) consume. The proposal is the design doc; this is the spec
implementers must conform to.

---

## 1. Adapter discovery

The main runner (slice 2 will refactor `runner/tool-grounding.sh`
into an orchestrator) reads `[grounding]` from `tdd-pack.toml`:

```toml
[grounding]
adapters = ["go"]           # ordered list of adapter names
total_char_cap = 30000
per_tool_char_cap = 4000
per_tool_timeout_s = 60
```

For each adapter name in `adapters`, the orchestrator invokes
`runner/grounding-adapters/<name>.sh`. Names MUST match the regex
`^[a-z][a-z0-9_-]*$`; the orchestrator rejects any other shape with
a clear error (path-traversal protection, per §3.4 of the
proposal's Codex addendum).

**Default**: `adapters = ["go"]`. Preserves v2.x behavior for
adopters who never edit the config. Sibling-pack install scripts
edit this list to add their adapter.

---

## 2. Input contract — JSON on stdin

Each adapter receives a JSON object on stdin:

```json
{
  "project_dir":         "/abs/path/to/project",
  "changed_files":       ["pkg/foo/bar.go", "pkg/foo/baz_test.go"],
  "lang_hint":           "go",
  "total_char_cap":      30000,
  "per_tool_char_cap":   4000,
  "per_tool_timeout_s":  60,
  "tdd_grounding_race":  false,
  "adapter_interface_version": 1
}
```

| Field | Type | Notes |
|---|---|---|
| `project_dir` | string (abs path) | The project root. Adapters cd into this before running tools. |
| `changed_files` | string[] | Repo-root-relative paths. May include test files, manifest files, config files. Adapter filters to its relevance. |
| `lang_hint` | string | The adapter name from `[grounding] adapters`. Adapter may use this as its display name. |
| `total_char_cap` | integer | The TOTAL output cap across ALL adapters. Individual adapters do NOT enforce this; the orchestrator does after concatenation. |
| `per_tool_char_cap` | integer | Each tool's output is truncated to this. Adapter enforces. |
| `per_tool_timeout_s` | integer | Each tool's timeout. Adapter enforces. |
| `tdd_grounding_race` | bool | Mirror of `TDD_GROUNDING_RACE=1` opt-in for heavy tests. Adapter decides what this means for its tool set. |
| `adapter_interface_version` | integer | Currently `1`. Adapters MUST fail loud on unsupported versions. |

The orchestrator's own env vars (`TOOL_GROUNDING_TIMEOUT_S`,
`TOOL_GROUNDING_CHAR_CAP`, etc., as currently used by
`runner/tool-grounding.sh`) become inputs in the JSON payload —
adapters MUST NOT read them from the environment directly.

### Parser dependency

Adapters MUST use `jq` to parse the input JSON. `jq` is already
listed in `plugin.json` `requires` (≥ 1.6). Adapters MAY assume
`jq` is present; if missing, they fail loud with a clear error and
exit non-zero. The orchestrator does the same.

---

## 3. Output contract — markdown on stdout

### 3.1 Single-adapter mode (backward-compat with v2.x)

When `[grounding] adapters` has exactly one entry, the adapter
SHOULD emit the legacy header to maintain byte-for-byte parity
with v2.x output:

```markdown
## Tool grounding (pre-executed before this review)

**Summary:** N affected module(s), M affected file(s).

## Module: `<path>`

### gofmt -l .
(clean)

### go vet ./...
(clean)
```

This is the contract slice 2's parity smoke verifies against
`test/fixtures/grounding-parity/case-01-single-go-module/expected.md`.

### 3.2 Polyglot mode (multiple adapters configured)

When `[grounding] adapters` has more than one entry, each adapter
SHOULD emit a per-language header:

```markdown
## Tool grounding — go (N modules, M files affected)

### Module: `pkg/foo`

#### gofmt -l .
(clean)

...
```

The per-language header IS a user-visible output change in polyglot
mode. v2.3 CHANGELOG MUST document this. Single-language mode keeps
the legacy header.

### 3.3 Status sections — never silently skip

Every tool MUST emit a status section even when:

- The tool is clean: `(clean)`
- The tool is not installed: `(skipped: <bin> not installed)`
- The tool timed out: `(timed out after Ns)`
- The tool errored (non-zero exit): a brief reason or the raw stderr tail

Never silently skip. The v2.0 lesson is load-bearing here: if the
reviewer (Codex) does not know a tool ran and produced no output vs
did not run at all, it will overreact to or underreact to the
diff in ways the reviewer's prompt cannot fix.

### 3.4 Truncation rules

Per-tool output is truncated at `per_tool_char_cap` (default 4000)
INSIDE the adapter. The adapter appends:

```
(... truncated; full output was <N> chars)
```

Total-output truncation happens AFTER concatenation in the
orchestrator. The orchestrator MUST:

- Truncate at SECTION boundaries (` `, `#`, `##`, `###`, `####`,
  `(clean)`, `(skipped: …)`, `(timed out after …s)`) when possible
- Close any open markdown code fences (```` ``` ````) before
  appending the truncation notice
- Reserve a small per-adapter status budget (~200 chars per
  configured adapter) so every configured adapter at least surfaces
  its name + first status line even when an earlier adapter
  consumed the cap with verbose output

Truncation notice format:

```
(... total tool grounding output truncated at <cap> chars across <N> adapter(s))
```

---

## 4. Adapter exit codes + failure visibility

| Code | Meaning |
|---|---|
| `0` | Success. Output on stdout may be empty if no language-relevant files were in the diff. |
| Non-zero | Adapter error. The orchestrator MUST log the failure AND include the last ~500 chars of the adapter's stderr in the final grounding block. |

When an adapter fails, the orchestrator includes the failure
inline in the grounding block:

```markdown
## Tool grounding — go (adapter `go` FAILED, exit 1)

(... last 500 chars of adapter stderr ...)
```

"See runner log" alone is NOT sufficient — the reviewer (Codex)
needs to see the failure to know it should not assume "clean tools"
when in fact the tools never ran. This is the §3.3 "never silently
skip" principle extended to adapter-level failures.

---

## 5. Adapter metadata — per-block self-description

Each adapter's emitted block MUST include the following metadata
in its first non-header line, to help the reviewer (and humans)
distinguish overlapping language claims in polyglot mode:

```markdown
## Tool grounding — <lang> (<adapter_name>, <N> modules, <M> files affected; discovery: <basis>)
```

- `<adapter_name>` — the value of `lang_hint` from input.
- `<N> modules` — count of distinct module directories the adapter
  discovered.
- `<M> files affected` — count of `changed_files` the adapter
  classified as relevant to itself.
- `<basis>` — one short phrase describing the discovery walk
  (e.g. `walked to nearest go.mod`, `walked to nearest
  pyproject.toml`).

For single-language mode (legacy header), this metadata is
folded into the existing `**Summary:**` line.

---

## 6. Installation + ownership model

Adapter files live at `runner/grounding-adapters/<name>.sh` in
the adopter's project tree. Ownership is split:

- **Base pack** (`go-tdd-pack`) ships `runner/grounding-adapters/go.sh`
  by default (slice 2's deliverable). The base pack's upgrade
  procedure overwrites `runner/grounding-adapters/go.sh` like every
  other `runner/*.sh` file.
- **Sibling packs** (`py-dev-pack`, `ts-dev-pack`, etc.) ship their
  own adapter via their install script. The sibling install MUST:
  1. Write `runner/grounding-adapters/<sibling-name>.sh`.
  2. Edit `tdd-pack.toml` `[grounding] adapters` to append the
     sibling name (preserving any existing entries).
  3. Abort with a clear error if `runner/grounding-adapters/<sibling-
     name>.sh` already exists from a different source.

The base pack's upgrade procedure MUST NOT overwrite any file in
`runner/grounding-adapters/` other than `go.sh`. Other files in
that directory are sibling-pack-owned.

Upgrade / uninstall conflicts:

| Situation | Behavior |
|---|---|
| Base pack v2.3 install + no siblings | Ships `go.sh` only. Default `adapters = ["go"]`. |
| Base pack upgrade with sibling adapters present | Overwrites `go.sh`. Does NOT touch sibling-pack adapter files. Does NOT touch `tdd-pack.toml`. |
| Sibling pack install over existing config | Sibling install reads current `adapters` list, appends if not present. |
| Sibling pack install conflict (same name from different source) | Install aborts with a clear error referencing both source URLs. Adopter resolves manually. |
| Sibling pack uninstall | Removes `runner/grounding-adapters/<sibling>.sh` + removes the entry from `tdd-pack.toml` `adapters`. Does NOT touch base pack files. |

---

## 7. Versioning the interface

Current contract: `adapter_interface_version = 1`.

Adapters declare their supported version range in a comment header:

```bash
# Adapter interface version: 1
# (supports versions [1])
```

If the orchestrator sends an unsupported version, the adapter:

1. Emits a status block to stdout:
   ```markdown
   ## Tool grounding — <lang> (adapter requires interface v<N>, got v<X>)
   (adapter does not support interface version <X> — please upgrade the base pack or the sibling pack)
   ```
2. Exits with status code 64 (the conventional Unix "command line
   usage error" code, signaling a contract mismatch rather than a
   tool failure).

The orchestrator catches exit 64 specifically and includes the
adapter's stdout in the grounding block AND logs the version
mismatch to `runner.log`.

Migration policy: each contract version supports `v(N-1)` for one
major release, then is removed. v2.3 ships v1; v2.4+ that wants to
change the input shape bumps to v2; adapters declaring `[1, 2]`
remain compatible during the transition.

---

## 8. What this contract does NOT cover

These are explicit non-goals for v1 of the interface:

- **Async / parallel adapter execution.** Adapters run serially in
  the order listed in `adapters`. Parallel-adapter execution is a
  v2.4 candidate, not v1.
- **Adapter sandboxing.** Adapters run with the same permissions
  as the orchestrator (i.e. same as the user). Trust the source
  of any sibling pack you install, same as any package manager.
  The `safer execution mode` proposal (#105) is a separate concern.
- **Per-adapter input customization beyond the JSON schema above.**
  Adapters MAY accept additional environment variables for tuning
  (e.g. `MYADAPTER_LINTER_PATH`), but those are adapter-specific
  extensions, not part of the base contract.
- **Polyglot policy for multi-language single files** (e.g. `.proto`
  with both a Go-protobuf and a Python-protobuf adapter
  configured). Both adapters run; the orchestrator does not
  deduplicate or pick a winner. The reviewer reading the output
  decides what's overlapping.
- **Runtime detection of available tools.** Each adapter decides
  whether to invoke each of its tools. The orchestrator does not
  introspect tool availability.

---

## 9. Slice 2 acceptance criteria (forward-looking, NOT in slice 1)

Slice 2 ships:

1. `runner/grounding-adapters/go.sh` — extracted Go tool-running
   logic from current `runner/tool-grounding.sh`. Reads the JSON
   contract above.
2. `runner/tool-grounding.sh` becomes the orchestrator. Reads
   `[grounding] adapters` from `tdd-pack.toml`. Builds per-adapter
   input JSON. Invokes each adapter. Concatenates outputs. Enforces
   total cap with the §3.4 truncation rules.
3. `test/smoke-grounding-parity.sh` — a parity smoke that:
   - Sets up the fixture at
     `test/fixtures/grounding-parity/case-01-single-go-module/`
     in a temp git repo.
   - Compares current host's tool inventory against the fixture's
     `tool-inventory.txt`; skips the smoke (with a clear note) if
     they differ.
   - Runs the orchestrator + adapter.
   - Compares output byte-for-byte against `expected.md`.
   - **Fails loud** on any divergence — this is the load-bearing
     "we didn't regress Go-only adopters" check.

The fixture under `test/fixtures/grounding-parity/` is slice 1's
load-bearing artifact. Slice 2 MUST reproduce its `expected.md`
byte-for-byte to be acceptable for merge.

---

## 10. Related

- [`PROPOSAL-grounding-adapter-interface.md`](PROPOSAL-grounding-adapter-interface.md)
  + its §12 Codex addendum — the design + the review findings.
- `runner/tool-grounding.sh` — the script being refactored in
  slice 2 to use this interface.
- `test/fixtures/grounding-parity/README.md` — explains how the
  fixture works + the procedure to re-capture `expected.md` on
  a different host.
