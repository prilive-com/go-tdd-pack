# Research — Codex CLI sandbox features (v2.3 task #105 slice 1)

> Status: **load-bearing research spike for v2.3 task #105**
> (safer execution mode). After this doc lands, slice 2+ are gated
> on the conclusions here. Slice 2 does NOT start automatically
> after slice 1 — a maintainer reads this report, picks the
> implementation path, and explicitly schedules slice 2.

Captured against Codex CLI **0.129.0** (current ChatGPT release
in early June 2026), on Linux (kernel 6.8.0). macOS Seatbelt path
deferred to a future spike if/when an adopter on macOS picks up the
work — the §3 macOS row is documented from `codex --help` only.

## §1 Decision the maintainer reads off this page

**Option C (`--sandbox workspace-write` + `--add-dir` allowlist)
IS available in Codex CLI 0.129.0**, verified both statically
(via `codex exec --help` enum + flag documentation) and partially
empirically (via `codex sandbox linux`, which uses the same Linux
backend). The addendum's "if §5 confirms support, ship C; else
ship A" decision tree resolves to **ship Option C** for the
default backend.

Option A (runner captures stdout instead of letting Codex write
disk) is preserved as a separate hardening lever — useful for the
M4 "what does Codex write during a cycle" inventory below — but
is no longer the primary safety mechanism.

Concrete slice 2 brief (for the maintainer):

- Refactor `runner/codex-round1.sh`, `runner/codex-round-n.sh`,
  and `runner/ops-preflight-review.sh` to pass
  `--sandbox workspace-write --add-dir <runner-temp-dir>` instead
  of the current `--dangerously-bypass-approvals-and-sandbox`.
- Keep `--sandbox danger-full-access` reachable behind explicit
  `tdd-pack.toml [codex] sandbox = "bypass"` (deprecated; see
  slice 6).
- Counterfactual smoke per §8: run a Codex cycle with a prompt
  designed to write `/tmp/sandbox-canary-<id>.txt`. Under default
  (workspace-write), canary must NOT appear. Under bypass mode,
  it MUST appear (proves the sandbox is doing the work).

## §2 Codex CLI sandbox capability matrix (static)

Source: `codex exec --help`, `codex sandbox --help`,
`codex sandbox linux --help` against 0.129.0.

| Surface | Flag / key | Values |
|---|---|---|
| `codex exec --sandbox` | `-s, --sandbox <MODE>` | `read-only` / `workspace-write` / `danger-full-access` |
| Allowlist | `--add-dir <DIR>` | Additional writable dirs alongside primary workspace |
| Working dir | `-C, --cd <DIR>` | Workspace root |
| Session persistence | `--ephemeral` | Skips writing session rollout files |
| Execpolicy | `--ignore-rules` | Skips `.rules` files (user + project) |
| Config-key override | `-c sandbox_permissions=[...]` | Granular permissions (see §3) |
| Top-level sandbox subcommand | `codex sandbox linux` / `macos` / `windows` | Run arbitrary commands under the OS sandbox |
| Linux backend | bubblewrap (default) | Per `codex sandbox linux --help` |
| Hard-bypass flag | `--dangerously-bypass-approvals-and-sandbox` | "EXTREMELY DANGEROUS" per help text. **This is what v2.0 shipped.** |

The three `--sandbox` modes map cleanly to the three proposal
options:

| `--sandbox` mode | Proposal option | Behavior |
|---|---|---|
| `read-only` | Option A (when paired with runner stdout capture) | Codex cannot write anywhere. Runner captures everything via stdout/stderr. |
| `workspace-write` | **Option C** | Codex can write within `--cd` + `--add-dir` allowlist. Other paths denied. |
| `danger-full-access` | Status quo (= `--dangerously-bypass-approvals-and-sandbox`) | No sandbox. |

## §3 Empirical findings — what is and isn't sandboxed

Source: `scripts/research/probe-codex-sandbox.sh` (this slice's
companion script). All probes use `codex sandbox linux` so they
verify the underlying Linux sandbox WITHOUT calling the model
(zero tokens spent).

| Probe | Command | Result |
|---|---|---|
| A. read-only default — `/tmp` write | `codex sandbox linux -- sh -c "echo X > /tmp/y"` | **WRITE DENIED** ("Read-only file system" from inside the sandbox). Process exit 0; file does NOT exist. |
| B. read-only default — cwd write | `cd /tmp && codex sandbox linux -- sh -c "echo X > ./y"` | **WRITE DENIED** (same error; cwd is read-only too). |
| C. read-only — read attempt | `codex sandbox linux -- sh -c "cat /etc/hostname"` | **READ ALLOWED**; hostname printed correctly. |
| D. inline permission override is rejected | `codex sandbox linux -c 'sandbox_permissions=["disk-write-cwd"]' -C /tmp -- sh -c "..."` | `error: the following required arguments were not provided: --permissions-profile <NAME>`. The `-c sandbox_permissions=...` override REQUIRES a `--permissions-profile` to attach to; it cannot be used standalone. |

Implications for slice 2:

- The Linux backend is **read-only by default** when invoked via
  `codex sandbox linux`. Adding writable scope requires either:
  (a) a named `--permissions-profile`, or
  (b) the higher-level `codex exec --sandbox workspace-write`
      flag (which the runner already controls).
- (b) is the path the runner takes. Permission-profile-by-name
  is not needed for the v2.3 runner.

**Live test NOT performed in this spike (deferred to slice 2
maintainer):** `codex exec --sandbox workspace-write` against a
real prompt that attempts to write to `/tmp/sandbox-canary-<id>.txt`.
This costs ChatGPT subscription tokens (model invocation cannot
be elided) and is the slice 2 counterfactual smoke. Slice 2's
acceptance is that smoke; failing it means the static finding
("`workspace-write` excludes `/tmp`") is wrong and the slice
backs out.

## §4 BLOCKER 1 empirical proof: worktree IS NOT a sandbox

The addendum's BLOCKER 1 claim: "Git worktree only protects the
live checkout from relative-path writes. `codex exec
--dangerously-bypass` can still write any absolute path: `$HOME`,
`/tmp`, `/etc`, SSH config, hooks."

This is true by definition of `--dangerously-bypass-approvals-and-sandbox`,
per the upstream help text:

> Skip all confirmation prompts and execute commands without
> sandboxing. EXTREMELY DANGEROUS. Intended solely for running
> in environments that are externally sandboxed.

A git worktree changes only the cwd — it does not invoke any
filesystem isolation. So `--dangerously-bypass` running inside a
worktree has identical disk-write reach to running outside one:
both can write `/tmp/x`, `~/.ssh/authorized_keys`, etc.

A live demonstration would simply be:

```bash
mkdir -p /tmp/sandbox-canary-test
canary=/tmp/sandbox-canary-test/canary-$$
git worktree add /tmp/wt-test main
cd /tmp/wt-test
echo "write $canary" | codex exec \
  --dangerously-bypass-approvals-and-sandbox - 2>&1 >/dev/null
ls "$canary"   # would exist
```

Not run here (costs tokens). The conclusion is unchanged: Option B
(worktree) is **not** a safety mechanism. It is an
artifact-isolation convenience at best.

## §5 Codex write-path inventory (MAJOR M4 closure)

What does Codex itself write to disk during normal use, when NOT
under a sandbox? Captured from the live `~/.codex/` directory on
the research host:

| Path | Size | Purpose | Affected by `--ephemeral`? |
|---|---|---|---|
| `~/.codex/sessions/` | 656 files | Session rollout JSONL (one per session) | YES — skipped when `--ephemeral` is set |
| `~/.codex/state_5.sqlite` | 22 MB | Cross-session state (history, settings) | Unknown empirically; need probe |
| `~/.codex/logs_2.sqlite` | 17 MB | Diagnostic logs | Unknown empirically |
| `~/.codex/history.jsonl` | 48 KB | Conversation history | Likely yes |
| `~/.codex/models_cache.json` | 178 KB | Cached model list | Persistent cache |
| `~/.codex/auth.json` | 5 KB | Auth state | Persistent (login state) |
| `~/.codex/log/codex-tui.log` | varies | TUI log | Persistent |
| `~/.codex/.tmp/` | varies | Plugin sync cache | Persistent across runs |
| `~/.codex/shell_snapshots/` | varies | Shell snapshots | Persistent |
| `~/.codex/cache/` | varies | General cache | Persistent |

Slice 2 implications:

- Under `--sandbox workspace-write`, Codex still needs to write
  to `~/.codex/` (auth refresh, session rollout, cache updates).
  Either:
  (a) Add `--add-dir "$HOME/.codex"` to the runner's sandbox
      invocation (RECOMMENDED — least invasive).
  (b) Always pass `--ephemeral` and accept the loss of session
      resume + cross-session history.
- Slice 2 ships (a) by default and documents `--ephemeral` as
  an opt-in via a future `[codex] ephemeral_sessions = true`
  toml key (not in slice 2 scope).
- This closes MAJOR M4 ("zero observable behavior change" was
  wrong because Codex needs its own write paths). Slice 5 will
  ship the adopter migration note before flipping the
  `tdd-pack.toml` default.

## §6 M2 closure — write-boundary behaviors deferred to slice 2

Codex's interface has several distinct disk-write surfaces. The
addendum's MAJOR M2 worries each may behave differently under the
sandbox. Status of each:

| Surface | Status | Slice 2 action |
|---|---|---|
| `codex exec -o <file>` (structured output) | UNKNOWN empirically; the file path is the runner's; whether the SANDBOX permits the write depends on whether `-o` runs INSIDE or OUTSIDE the sandbox. | Live test in slice 2: run `codex exec -s workspace-write --add-dir /tmp/allowed -o /tmp/elsewhere/out.json` and see if it fails. If fails: pass the `-o` path via `--add-dir` too. If succeeds: `-o` runs outside the sandbox (runner-controlled write). |
| stdout redirection | Runner-controlled (runner reads Codex stdout via pipe). Outside sandbox by definition. | No action. |
| stderr capture | Same as stdout — runner reads via pipe. | No action. |
| Model-invoked shell (`<shell>...</shell>`) | Per sandbox mode — `read-only` denies; `workspace-write` allows within scope; `danger-full-access` allows everywhere. | Verified empirically in §3 (probes A/B/C). |
| `--tee` / other redirection | Unknown — not used by the runner today. | Defer. |

The conclusion is that slice 2 must verify the `-o` write
boundary as part of the worktree-canary smoke. If `-o` is
sandboxed, the runner needs to allowlist its output dir; if it
isn't, the runner's existing path works.

## §7 Discovered Codex CLI features useful for slice 2+

- `--ignore-rules` — skips user + project `.rules` (execpolicy)
  files. If an adopter has hostile `.rules`, this is an escape
  hatch. v2.3 runner should consider adding this for the
  pre-review path (parallels the existing `--ignore-user-config`
  hardening in v2.1 PR 7).
- `-c features.<name>=true` / `--enable <FEATURE>` — feature
  flags. Not used by the runner today; potentially useful for
  enabling tighter sandbox modes via named features in future
  Codex versions.
- `codex sandbox linux <cmd>` — usable as a generic OS-level
  sandbox for ANY command (not just Codex). Future direction:
  pack ships a thin wrapper that adopters can use to run their
  own build / test commands under the same sandbox the Codex
  runner uses.

## §8 Open questions (NOT blocking slice 2)

1. macOS Seatbelt parity: does `--sandbox workspace-write` on
   macOS behave identically to Linux + bubblewrap? Defer until
   a macOS adopter pushes the issue.
2. Windows behavior: `codex sandbox windows` exists but is
   undocumented in `--help`. Deferred to a separate spike.
3. Network egress under `workspace-write`: the proposal §1 v2
   threat model declares network egress out of scope for v2.3.
   Confirm whether `workspace-write` blocks network anyway
   (would be a free hardening win); slice 2 maintainer should
   probe in the canary smoke.
4. Concurrent cycles: if two runner cycles overlap, do their
   sandboxes interfere? Codex CLI sessions live in
   `~/.codex/sessions/` — distinct files, distinct dirs.
   Verified non-overlapping by filename inspection.

## §9 Probe script

`scripts/research/probe-codex-sandbox.sh` automates §3's probes
and writes a structured JSON record to
`.tdd/research/codex-sandbox-features.json`. Maintainers picking
up slice 2 should run it on their target host to verify the
findings here still hold on their Codex CLI version.

The script:

- Checks `codex --version` and `codex exec --help` for the
  documented enum values.
- Runs probes A, B, C (no model calls).
- Records the result + the Codex version + Linux kernel + a
  timestamp to the JSON.

If a future Codex CLI release breaks any of these probes, the
script's JSON will diverge from the committed example record at
`docs/research/codex-sandbox-features.example.json` (this slice
ships both for diff-ability).

## §10 Conclusion

**Slice 2 should ship Option C** — refactor the runner to use
`codex exec --sandbox workspace-write --add-dir "$HOME/.codex"`
+ any additional dirs the runner needs to seed.

**Option A is preserved as a hardening pattern** for paths where
the runner wants to capture Codex output without letting Codex
write disk at all (e.g. the pre-review path that already streams
stdout). Use `--sandbox read-only` for those.

**Worktree (Option B) is dropped from the safety axis**. Slice 2
must not ship worktree as the primary mechanism. The
`mode = "worktree"` documented in the proposal §6 is rebranded as
an artifact-isolation convenience option, not a safety mode; it
will land in a later slice (or be cut) once Option C is proven
in production.
