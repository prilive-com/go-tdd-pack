# Proposal — Grounding-adapter interface for sibling-pack support

> Status: **proposal — implementation-ready slice plan**.
> Author: maintainer (2026-06-08).
> Closes pending task #107.
> Slogan: **the language-specific bits are an adapter, not a fork.**

---

## 0. Origin and the sibling-pack problem

v2.0.0–v2.2.0 has made the pack architecture mature: code review, four
false-positive rails, FDTDD foundation, ops-risk-triage rail, Codex
deep ops-preflight. All of that is language-agnostic — except
`runner/tool-grounding.sh`. That script is Go-only by design:

```bash
# runner/tool-grounding.sh (excerpt)
run_tool "${mod}" "gofmt -l ." gofmt -l .
run_tool "${mod}" "go vet ./..." go vet ./...
run_tool "${mod}" "staticcheck -checks=all ./..." staticcheck -checks=all ./...
run_tool "${mod}" "golangci-lint run --enable-all" golangci-lint run --enable-all --timeout=50s ./...
run_tool "${mod}" "govulncheck ./..." govulncheck ./...
run_tool "${mod}" "gosec -no-fail -quiet ./..." gosec -no-fail -quiet ./...
```

A sibling Python or TypeScript pack would have to either fork the
entire runner (then carry every v2.x.y upgrade by hand) or hack
around this one script. Neither is sustainable.

This proposal defines a small interface so sibling packs ship only
their language-specific tool-grounding adapter; everything else stays
shared.

---

## 1. The problem (concretely)

`runner/tool-grounding.sh` does three jobs jammed into one file:

1. **Discover affected modules** — walk changed files up to the
   nearest non-empty `go.mod`, dedupe by directory.
2. **Run the tools** — six Go-specific binaries per module.
3. **Format output** — emit a single markdown block with status
   sections, output caps, and "skipped: not installed" markers.

Jobs 1 and 3 are LANGUAGE-AGNOSTIC patterns expressed in Go-specific
terms. Job 2 is the only language-specific work.

A `py-dev-pack` adapter would want to:
1. Discover affected packages — walk changed files up to the
   nearest `pyproject.toml` or `setup.py`, dedupe.
2. Run `ruff`, `mypy`, `bandit`, `pytest --co`, `pip-audit`.
3. Format the same way.

Jobs 1 and 3 are basically identical. We're re-inventing them
per-language for no reason.

---

## 2. Goals + non-goals

**Goals.**

- Sibling packs ship JUST a `runner/grounding-adapters/<lang>.sh`
  (or equivalent) — every other runner script is shared.
- Backward-compatible: existing `runner/tool-grounding.sh` keeps
  working unchanged for Go-only adopters who never install a
  sibling pack.
- Polyglot repos work: if a diff touches `.go` + `.py`, both
  adapters run; their outputs compose into one tool-grounding
  block, respecting the total cap.
- Adapter contract is documented + versioned so future packs can
  rely on it.

**Non-goals.**

- Rewrite the Go grounding logic. Slice 1 just extracts the
  language-specific part into a `go.sh` adapter behind the new
  interface; behavior stays identical.
- Define adapters for non-Go languages in this pack. That's the
  job of sibling packs (`py-dev-pack`, `ts-dev-pack`).
- Change Codex's prompt-side handling of the grounding block. The
  output format is unchanged; only the producer is.

---

## 3. Adapter contract

Each adapter is a shell script (or executable) at
`runner/grounding-adapters/<lang>.sh`. The main runner discovers
adapters, invokes each with a structured input, and concatenates
their outputs into the final grounding block.

### 3.1 Input contract (stdin JSON)

```json
{
  "project_dir":   "/abs/path/to/project",
  "changed_files": ["pkg/foo/bar.go", "pkg/foo/baz_test.go"],
  "lang_hint":     "go",
  "total_char_cap": 30000,
  "per_tool_char_cap": 4000,
  "per_tool_timeout_s": 60,
  "tdd_grounding_race": false,
  "adapter_interface_version": 1
}
```

Each adapter reads stdin, parses the JSON, decides whether any of
`changed_files` are relevant to its language (e.g. Go adapter filters
to `*.go` + `go.mod` + `go.sum`), and produces output if so. If
nothing is relevant, the adapter MUST emit an empty string + exit 0
(not a "no relevant files" markdown section — the main runner handles
the cross-adapter empty case).

`adapter_interface_version` is the contract version. Adapters MUST
fail loud if they receive an unsupported version.

### 3.2 Output contract (stdout markdown)

Each adapter emits a markdown block like:

```markdown
## Tool grounding — go (2 modules, 3 files affected)

### Module: `pkg/foo`

#### gofmt -l .
(clean)

#### go vet ./...
(clean)

#### staticcheck -checks=all ./...
```
pkg/foo/bar.go:42:5: SA4006: this value of err is never used
```

### Module: `internal/baz`

#### gofmt -l .
(clean)
```

Header line MUST be `## Tool grounding — <lang> (...)`. Use the
`<lang>` from `lang_hint` if you accept it, or your own name if you
override.

Each tool MUST emit its section even if clean (`(clean)`), if skipped
(`(skipped: <tool> not installed)`), or if timed out
(`(timed out after Ns)`). Never silently skip — the v2.0 lesson.

Per-tool output cap and per-tool timeout come from the input JSON;
the main runner enforces the total cap by truncating the
concatenation.

### 3.3 Exit codes

- `0` = success (output may be empty if no relevant files).
- non-zero = adapter error. Main runner logs the failure and
  continues with other adapters; the failed adapter's section in
  the final block reads `(adapter <name> failed: see runner log)`.

### 3.4 Discovery

Main runner reads from `tdd-pack.toml`:

```toml
[grounding]
adapters = ["go"]   # ordered list of adapter names; main runner
                    # invokes runner/grounding-adapters/<name>.sh
                    # for each, in order, concatenating outputs.
total_char_cap = 30000
per_tool_char_cap = 4000
per_tool_timeout_s = 60
```

Default: `adapters = ["go"]` (preserves v2.x behavior for adopters
who never edit the config). Sibling-pack install script edits this
list to add its adapter (e.g. `adapters = ["go", "python"]`).

---

## 4. Options for discovery mechanism

The adapter contract above assumes config-driven discovery (Option B
below). For completeness, three discovery designs were considered:

| Option | Discovery | Pro | Con |
|---|---|---|---|
| A — auto-detect | Scan repo for marker files (`go.mod`, `pyproject.toml`, etc.); invoke all matched adapters | Zero config | Magic; surprises adopters who don't realize a sibling pack just enabled itself |
| **B — config-driven** | `[grounding] adapters = [...]` in `tdd-pack.toml`; sibling install script edits the list | Explicit; matches the rest of the pack's "opt-in everything" pattern | One extra config step during sibling install |
| C — file-extension routing | `*.go` → go adapter, `*.py` → python adapter (hardcoded in main runner) | Predictable | Adds a hardcoded routing table to the starter pack; violates the "no hardcoded commands" rule (it's not commands but it's the same spirit) |

**Recommendation: Option B.** Same explicit-opt-in shape as
`[ops_triage]`, `[pre_review]`, `[tiers]`. Sibling-pack install
scripts edit one config field; pack itself ships zero adapter
references beyond Go.

---

## 5. Polyglot composition

For polyglot repos (diff touches `.go` + `.py`), the main runner
invokes each configured adapter in order, concatenates their outputs,
and enforces the total char cap on the concatenation. If
concatenated output exceeds the cap, the runner truncates at the cap
and appends:

```markdown
(... total tool grounding output truncated at 30000 chars across N adapters)
```

Adapters MUST NOT coordinate. Each gets the full input independently
and produces its own block. This keeps adapters simple at the cost
of some redundant work (each re-walks the changed-files list to
filter to its language).

If two adapters both claim relevance for the same file (e.g. a
`.proto` file with both a Go-protobuf and a Python-protobuf
adapter), both run; that's intended behavior.

---

## 6. Build slices

| Slice | Scope |
|---|---|
| **1** | Define + document the adapter contract (`docs/GROUNDING_ADAPTER_INTERFACE.md` based on §3 of this proposal). No code change yet. |
| **2** | Extract the Go-specific bits of `runner/tool-grounding.sh` into `runner/grounding-adapters/go.sh`. Refactor `runner/tool-grounding.sh` to be the orchestrator: reads `[grounding] adapters` from `tdd-pack.toml`, builds input JSON, invokes each adapter, concatenates, enforces total cap. Default `adapters = ["go"]` so behavior is unchanged for existing adopters. |
| **3** | Smoke: counterfactual — feed the orchestrator a fake adapter that returns a known string; assert the orchestrator concatenates correctly + enforces the total cap. |
| **4** | Sibling-pack reference adapter: `runner/grounding-adapters/python.sh.example` (NOT shipped active; just an example file showing the shape, with `ruff` / `mypy` / `pytest` / `pip-audit`). This is documentation, not feature work. |
| **5** | Adopter doc update: how to wire a sibling-pack adapter into your config. Lives in `docs/ADOPTION_GUIDE.md` as a new section "Adding a sibling-pack adapter". |

Slices 1+2 are the actual interface work. Slices 3–5 are
verification + docs.

---

## 7. Smoke tests

- **Adapter discovery smoke**: with `[grounding] adapters = ["go",
  "fake"]` and a sentinel `runner/grounding-adapters/fake.sh` that
  emits `## Tool grounding — fake\n(sentinel-marker-12345)`,
  invoke the orchestrator, assert both blocks appear and the
  sentinel string is in the output.
- **Cap enforcement smoke**: configure `total_char_cap = 100`; have
  the fake adapter emit 200 chars; assert orchestrator truncates +
  appends the truncation notice.
- **Failed adapter smoke**: fake adapter returns exit 1; assert
  orchestrator logs the failure, the failed-adapter section reads
  "(adapter fake failed: ...)", and OTHER adapters' output still
  appears.
- **No-relevant-files smoke**: trigger orchestrator with a diff
  touching only `.md` files; assert Go adapter emits empty +
  orchestrator emits an explicit "(no language-relevant files in
  this diff)" section instead of silently emitting nothing.
- **Interface version mismatch smoke**: orchestrator sends
  `adapter_interface_version: 99`; fake adapter checks the version
  and exits non-zero with "unsupported interface version 99";
  orchestrator surfaces this in the failed-adapter section.
- **Backward-compat smoke**: existing Go-only adopter config
  (`[grounding]` block absent OR `adapters = ["go"]`) produces the
  EXACT SAME markdown output as the current pre-refactor
  `tool-grounding.sh` for a fixed diff fixture. Byte-for-byte
  equality, except for timestamps. This is the load-bearing
  zero-regression check.

---

## 8. Honest limits

- **Polyglot redundancy.** Each adapter independently re-walks
  `changed_files`. For a 1000-file diff this is ~5ms per adapter,
  negligible. For pathological 100k-file diffs, it adds up. Mitigate
  by passing only files that match the adapter's relevance filter
  (would require the orchestrator to know each adapter's relevance
  rules — adds coupling). Not worth solving for v2.3.
- **Adapter sandboxing.** Adapters run with the same permissions
  as the orchestrator (which means: same as the user). A malicious
  sibling-pack adapter could exfiltrate `~/.ssh`. Defense:
  adopters install sibling packs from sources they trust, same as
  any package manager. This is industry-standard residual trust.
- **Versioning the interface.** `adapter_interface_version: 1`
  ships in v2.3. v2.4+ that wants to change the input shape bumps
  to 2; adapters declare their supported versions. Migration
  policy: support N-1 for one major version, then deprecate.
- **No async adapters.** Adapters are serial. For 10+ language
  polyglot repos, this could matter (each adapter takes a few
  seconds of tool-running time). For v2.3, accept the sequential
  cost. Parallel-adapter execution is a v2.4 candidate.
- **Adapter discovery is config-driven, not registry-driven.** We
  don't run a global discovery scan. If an adopter installs a
  sibling pack but forgets to edit `[grounding] adapters`, the
  adapter doesn't fire. The install script should write the config
  edit; adopters editing by hand should read the sibling pack's
  README.

---

## 9. Open questions for slice 1

1. **Adapter format: bash script vs. WASM vs. arbitrary executable?**
   Recommend bash for v2.3 — matches every other runner script,
   trivial to debug, no extra dependency. WASM/native could be a
   v2.5+ option if we ever want platform-portable adapters.
2. **Does the input JSON include the diff itself, or just changed-
   file paths?** Today's `tool-grounding.sh` doesn't see the diff —
   it just runs tools on the affected modules. Recommend keeping
   it that way; if an adapter wants the diff, it can read
   `${PROJECT_DIR}/.tdd/queue/<hash>.submission.json` directly.
3. **Does the orchestrator pass through `TDD_GROUNDING_RACE=1`** (the
   opt-in heavy-test flag from v2.1 PR #28) **as an input field, or
   leave it as an env var the adapter can read directly?**
   Recommend: input field. Cleaner contract; the orchestrator
   should own all env-var interpretation.
4. **What about non-go.mod monorepo discovery?** The current Go
   adapter walks to nearest `go.mod`. Python adapter would walk to
   `pyproject.toml`. Each adapter implements its own discovery.
   Don't try to share it.

---

## 10. Recommendation

**Approve and start slice 1.** Slice 1 is documentation work
(formalize the contract). Slice 2 (extract `go.sh` adapter) is the
real refactor; ~half a day with careful smoke setup to ensure
byte-for-byte parity with current output. Slices 3–5 are testing +
docs.

After v2.3 ships this, sibling packs (`py-dev-pack`, `ts-dev-pack`,
etc.) can ship a single `runner/grounding-adapters/<lang>.sh` and
a one-line config edit. The 80% of the runner stays shared.

---

## 11. Related

- `runner/tool-grounding.sh` — the script being refactored.
- [`PROPOSAL-ops-risk-triage.md`](PROPOSAL-ops-risk-triage.md) —
  same "config-driven explicit opt-in" pattern as this proposal's
  Option B discovery.
- [`UPSTREAM_DEPENDENCY_POLICY.md`](UPSTREAM_DEPENDENCY_POLICY.md)
  — sibling packs introduce dependency on adapter-shipped tools
  (ruff, mypy, etc.); the policy applies to those too.
- `CHANGELOG.md` § 2.1.0 — the original aggressive-tool-grounding
  PR (#28) that this proposal generalizes.
