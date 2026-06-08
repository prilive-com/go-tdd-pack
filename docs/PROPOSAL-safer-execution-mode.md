# Proposal — Safer default execution mode for Codex (drop `--dangerously-bypass`)

> Status: **proposal — implementation-ready slice plan, with one
> codex-CLI feature-support question to verify before slice 3**.
> Author: maintainer (2026-06-08).
> Closes pending task #105.
> Slogan: **trust the prompt AND verify the sandbox — defense-in-depth,
> not trust-only.**

---

## 0. Origin and how this differs from v2.0.0's decision

v2.0.0 deliberately chose `--dangerously-bypass-approvals-and-sandbox`
for every `codex exec` call. The rationale was "match Claude's
environment; the prompt enforces no-writes; smokes verify
empirically." That was a defensible call in May 2026 — the alternative
sandbox modes were less mature, the prompt approach worked, and the
smokes caught violations.

Three things changed since:

1. **The "trust-then-verify" pattern has now demonstrably failed in
   adjacent AI tooling** (multiple prompt-injection bypasses across
   the industry in 2025–2026; see §7 references). The smokes are
   detection, not prevention.
2. **The v2.1.0 incident** taught us that one wrong default ships
   blindly to every adopter. `--dangerously-bypass` is exactly that
   kind of default — invisible until something goes wrong.
3. **Codex CLI sandbox features have matured** since 0.125 (the v2.0
   floor). Modern Codex CLI supports `--sandbox` with finer-grained
   permission controls (verifiable in §5).

This proposal does NOT undo the v2.0 decision casually — it preserves
the empirical verification AND adds structural prevention. Defense in
depth.

---

## 1. The problem

`runner/codex-round1.sh`, `runner/codex-round-n.sh`, and (via slice 2
of v2.2) `runner/ops-triage-classify.sh` + `runner/ops-preflight-review.sh`
all invoke `codex exec` with
`--dangerously-bypass-approvals-and-sandbox`. This grants Codex full
process-level access to the project tree and beyond.

The runner relies on **two safety layers** today:

| Layer | Mechanism | Failure mode |
|---|---|---|
| **Prompt** | `prompts/codex-system.md` says "do not write project files" | Prompt injection in diff/grounding/recent-files context; model drift; novel jailbreak |
| **Smoke** | `smoke-v2-mvp.sh` and `smoke-v2-phase2-live.sh` check file hashes before/after cycle | Detection-only; the violating cycle already ran by the time the smoke fails |

Both layers can fail. Neither is preventive. The
`--dangerously-bypass-approvals-and-sandbox` flag is the load-bearing
trust assumption underneath both — if it goes, the whole safety
story collapses.

The v2.1.0 schema-strict-mode bug and the model-default crash taught
us: **defaults that depend on invisible trust ship blind to adopters**.
This is the same class.

---

## 2. Goals + non-goals

**Goals.**

- Replace `--dangerously-bypass-approvals-and-sandbox` with a sandbox
  that PREVENTS unintended writes outside `.tdd/reviews/<cycle>/`,
  not just detects them after the fact.
- Preserve every current capability: Codex can still read the whole
  project tree, run `git log/diff/show`, and write its
  round-1/round-N artifacts.
- Zero observable behavior change for adopters in the happy path.
- Keep the smokes — they remain valuable detection, just no longer
  the only line.

**Non-goals.**

- Restrict what Codex can READ. The whole point of grounding is to
  give Codex full repo context.
- Add a per-call approval prompt. We're not asking the operator to
  approve each Codex call — the model still runs autonomously.
- Sandbox Claude itself. Claude's safety story is separate (it lives
  inside Claude Code's own sandboxing).

---

## 3. Options

Three viable shapes. They differ on isolation strength, runner-code
churn, and dependency on Codex CLI feature support.

### Option A — `codex exec --sandbox read-only`

Run Codex in a read-only sandbox. Codex sees the whole project tree
but cannot write anywhere. The runner captures Codex's stdout
(`--output-schema` already produces structured JSON on stdout) and
writes artifacts itself.

| | |
|---|---|
| Trigger | `codex exec --sandbox read-only --output-schema <file> -o /dev/stdout` |
| Isolation | full — no writes possible anywhere |
| Runner churn | medium — `runner/codex-round1.sh` already uses `-o /dev/stdout` for some paths; need to audit all callers |
| Dep on Codex CLI | minimal — read-only sandbox shipped in Codex 0.125 |
| Pro | strongest isolation; simple to verify (any write = error) |
| Pro | runner writes artifacts under its own controlled paths; no codex tee |
| Con | breaks any future Codex-side workflow that wants to write debug logs to disk |

### Option B — Per-cycle git worktree

Each cycle creates a fresh `git worktree add` into a temp directory,
runs Codex inside the worktree, throws the worktree away. Codex still
runs with `--dangerously-bypass` but the worktree IS the project tree
it sees — writes don't propagate to the live tree because the runner
only consumes the artifacts it explicitly copies back.

| | |
|---|---|
| Trigger | runner shell: `git worktree add /tmp/cycle-<id> HEAD; cd ...; codex exec ...; git worktree remove` |
| Isolation | strong — writes happen in the worktree, never the live tree |
| Runner churn | medium — wrap every codex call in worktree-create/destroy; handle cleanup on error paths |
| Dep on Codex CLI | none — works on any Codex CLI version |
| Pro | strong isolation without depending on Codex CLI sandbox features |
| Pro | preserves git context (Codex can `git log` the cycle's HEAD) |
| Con | ~100ms setup per cycle (negligible) + ~50MB disk per cycle (matters for adopters with monorepos) |
| Con | adds error-path complexity: cleanup-on-crash, cleanup-on-Ctrl-C, cleanup-on-SIGKILL |
| Con | doesn't prevent reads outside the project — Codex can still read `~/.ssh/id_rsa` if its prompt is jailbroken (lower-stakes failure than writes, but real) |

### Option C — Read-only sandbox + writable allowlist for `.tdd/reviews/`

Run Codex with `--sandbox` and a permissions config that says "read
anywhere, write only to `.tdd/reviews/<cycle>/`". If Codex CLI
supports this shape (the `disk-write-folder` / similar permission), it
gives us BOTH the strong isolation of Option A AND the existing
codex-tees-to-disk runner workflow.

| | |
|---|---|
| Trigger | `codex exec --sandbox-permissions disk-read-all,disk-write-folder=.tdd/reviews/<cycle>` (exact flag TBD by §5) |
| Isolation | strong — only writes to `.tdd/reviews/<cycle>/` succeed |
| Runner churn | minimal — exact same call shape as today, just different flags |
| Dep on Codex CLI | **MUST verify support** (see §5) |
| Pro | cleanest middle: strong sandbox AND preserves all existing runner workflows |
| Pro | semantically tightest — codifies exactly what we want |
| Con | depends on Codex CLI permission-shape support; if not supported, this option dies |
| Con | per-cycle path means the permission config has to be templated; small dynamic-config overhead |

---

## 4. Recommendation

**Verify Option C feasibility first (§5). If supported, ship Option C.
If not, ship Option B (worktree).**

Rationale:

- **Option A is too disruptive.** Refactoring all four runner scripts
  to capture stdout instead of disk artifacts is real work, and we'd
  lose the ability to debug failed cycles by reading the partial
  artifacts left on disk.
- **Option B is the safe fallback.** It works on every Codex CLI
  version, doesn't depend on feature flags, and gives strong
  isolation. Cost: per-cycle setup overhead + error-path cleanup
  code.
- **Option C is the cleanest if supported.** It says exactly what we
  mean ("Codex can read anything, write only the cycle's artifacts")
  in the sandbox, not in the prompt. Verification cost is low (§5).

---

## 5. MUST-VERIFY-FIRST: Codex CLI sandbox-permissions feature

Before slice 3 commits to Option C, verify against current Codex CLI
(`codex --version` ≥ 0.135 as of June 2026):

```bash
# Question 1: does --sandbox accept a per-permission flag?
codex exec --help 2>&1 | grep -iE 'sandbox|disk-write|permission'

# Question 2: does the config TOML support a writable-folder list?
# Check ~/.codex/config.toml shape or codex --help for -c overrides:
codex exec --help 2>&1 | grep -A2 sandbox

# Question 3: try it empirically — does this run, and does the
# write to /tmp/elsewhere fail while the write to /tmp/allowed
# succeeds?
mkdir -p /tmp/allowed
echo 'write to /tmp/elsewhere/x and /tmp/allowed/x' \
  | codex exec --sandbox read-only \
               -c 'sandbox_workspace_write_roots=["/tmp/allowed"]' \
               --dangerously-bypass-approvals-and-sandbox-NO \
               - 2>&1
ls /tmp/elsewhere/x 2>/dev/null && echo "FAIL: write outside happened"
ls /tmp/allowed/x   2>/dev/null && echo "OK: write to allowed succeeded"
```

(The exact config key is the unknown — `sandbox_workspace_write_roots`,
`disk_write_folders`, or some other shape. The §5 verification's job
is to find the right one.)

**If Question 1+2 return a config knob AND Question 3's empirical
test passes** → ship Option C.

**If they don't** → ship Option B.

**Either way, NEVER ship the status quo.** Both options eliminate the
load-bearing trust assumption.

---

## 6. Modes

```toml
[codex]
sandbox = "auto"   # auto | strict | worktree | bypass
```

| Mode | Behavior | When |
|---|---|---|
| `auto` | **Default.** If Codex CLI supports writable-allowlist sandbox (Option C check passes at install), use it. Else fall back to worktree (Option B). | Adopters get the strongest available option without thinking. |
| `strict` | Force Option C (read-only sandbox + writable allowlist). Fail loud if Codex CLI doesn't support it. | Adopters who want to verify their Codex CLI version is current enough. |
| `worktree` | Force Option B (per-cycle git worktree). Skip the Codex CLI feature probe. | Adopters with monorepos where worktree-create is fast and predictable. |
| `bypass` | **DEPRECATED.** Restore the v2.0 `--dangerously-bypass` behavior. Logs a loud deprecation warning at session start. Documented escape hatch only. | Emergency recovery during the v2.3 transition; removed in v2.4. |

Default `auto`. The deprecation of `bypass` is documented but not
silent — operator will see a warning every session start until they
remove it.

---

## 7. Build slices

Six slices. Slices 1–4 are the MVP; 5–6 are migration/deprecation.

| Slice | Scope |
|---|---|
| **1** | §5 verification work: empirically test Codex CLI sandbox flags + permission shapes. Document findings in `docs/RESEARCH-codex-sandbox-features.md`. |
| **2** | Implement Option B (worktree). This is the no-CLI-dependency fallback that becomes `mode = "worktree"` permanently. Refactor `runner/codex-round1.sh` + `codex-round-n.sh` + ops-triage runners to wrap codex calls in worktree-create/destroy. Add cleanup-on-error paths. Smoke: counterfactual — a deliberate "try to write outside" Codex call must result in no leaked files. |
| **3** | (Only if §5 passes) Implement Option C (read-only + writable allowlist). New `runner/lib/codex-sandbox.sh` helper that builds the right flags. Same smoke counterfactual. |
| **4** | Implement `sandbox = "auto"` selection logic. Probe at session start; cache the result for the session. Smoke: simulate Codex CLI old (no Option C) and new (Option C OK) and confirm auto picks the right one. |
| **5** | Flip default `sandbox` from missing (= bypass) to `auto`. Update `tdd-pack.toml` shipped default. Update `smoke-config-default-consistency.sh` with a new check. |
| **6** | Deprecate `bypass` mode: emit a deprecation warning at session start when it's selected. Plan removal in v2.4. |

Slices 1–4 are the safety win. Slices 5–6 are the cleanup.

---

## 8. Smoke tests

Per the v2.1.1 counterfactual discipline: every "is sandboxed"
assertion paired with "would NOT be sandboxed if the option failed".

- **§5 research smoke** (slice 1): probes Codex CLI for the
  sandbox-permissions shape; emits a small JSON record at
  `.tdd/research/codex-sandbox-features.json`. Smoke is
  documentation, not pass/fail.
- **Worktree isolation smoke** (slice 2):
  - Set up a fixture project with a sentinel file at
    `/tmp/sandbox-canary-<id>.txt` (outside the project).
  - Trigger a runner cycle with a prompt designed to try to write
    that file.
  - Assert: after cycle, the canary file does NOT exist.
  - Counterfactual: with `sandbox = "bypass"`, the SAME runner
    cycle DOES create the canary file (proves the sandbox is the
    thing preventing it, not just the prompt).
- **Allowlist sandbox smoke** (slice 3): same pattern as the
  worktree smoke, asserting reads succeed and writes outside the
  allowlist fail.
- **Auto-detection smoke** (slice 4): stub Codex CLI versions with
  and without sandbox-permissions support; assert auto picks the
  right backend.
- **Bypass deprecation smoke** (slice 6): set `sandbox = "bypass"`;
  assert session start emits a deprecation warning containing the
  literal string "v2.4 removal".

---

## 9. Honest limits

- **Sandbox is one layer, not the whole story.** The prompt rule
  remains. The smokes remain. The sandbox is preventive; the prompt
  is conversational; the smokes are auditing. Defense in depth.
- **Option B (worktree) costs disk.** ~50MB per cycle for typical
  Go monorepos. For adopters running 100 cycles a day, that's
  ~5GB/day in /tmp churn. Filesystem-level cleanup happens
  automatically (worktree removed at cycle end), but `/tmp` should
  have headroom. Document this in the adopter guide.
- **Option C depends on Codex CLI features that may regress.** If
  upstream removes the permission shape in a future Codex release,
  Option C breaks. `sandbox = "auto"` defends against this by
  falling back to worktree. Per the v2.1.1
  [`UPSTREAM_DEPENDENCY_POLICY.md`](UPSTREAM_DEPENDENCY_POLICY.md):
  pin verified versions in CI, monitor upstream changelogs.
- **A determined model-jailbreak can still attempt mischief.** The
  sandbox prevents most write categories but not 100% of attack
  surfaces — e.g. a model that figures out it can `chmod` an
  allowlisted file to be world-readable still has a residual
  exfiltration path. The smokes catch *most* of these by
  before/after hashing; we accept residual risk as the cost of
  letting Codex be useful.
- **This proposal does NOT add a per-call approval gate.** Codex
  still runs autonomously per cycle. That's intentional —
  prompting on every call is exactly the approval-fatigue failure
  mode the v2.2 ops-triage rail tried to avoid for Bash.

---

## 10. Open questions for slice 1

1. **Exact Codex CLI flag/config shape for writable allowlist** —
   §5 work to verify. Without this we can't ship Option C.
2. **`.tdd/reviews/<cycle>/` is the runner's chosen artifact path;
   should the allowlist also include `.tdd/queue/` (pre-review
   verdicts) + `.tdd/ops-preflight/` (ops verdicts)?** Probably yes
   — they're all "runner-owned write paths" semantically. Easy to
   over-grant; better to grant explicitly and audit later.
3. **Worktree cleanup on SIGKILL** — if the runner script is killed
   between `worktree add` and `worktree remove`, the orphan
   worktree pollutes `git worktree list`. Need a startup-scan
   sweep that removes orphans older than 24h.
4. **Polyglot repos** — does Codex need to be able to read
   `~/.cargo`, `~/.npmrc`, etc. for tool-grounding? Worktree
   doesn't restrict reads. Allowlist (Option C) might. Verify in
   slice 1.

---

## 11. Recommendation

**Approve and start slice 1 (§5 verification work) now.** Slice 1 is
~half a day; it tells us whether the recommended Option C is
feasible. If not, we have Option B as the proven fallback. Either
way, v2.3.0 ships with `--dangerously-bypass` gone from the default
path.

This is the v2.0 trust-assumption being closed, not opened —
exactly the kind of defense-in-depth retrofit that the v2.1.0
postmortem (Bug 1 / Bug 2) and the v2.2 ops-triage rail are also
examples of.

---

## 12. Related

- [`POSTMORTEM-v2.1.0.md`](POSTMORTEM-v2.1.0.md) — the v2.1.0
  incident; the "defaults that depend on invisible trust ship
  blind" lesson.
- [`PROPOSAL-ops-risk-triage.md`](PROPOSAL-ops-risk-triage.md) —
  the v2.2 rail; same "harness prevents, model judges within"
  pattern this proposal applies to Codex itself.
- [`UPSTREAM_DEPENDENCY_POLICY.md`](UPSTREAM_DEPENDENCY_POLICY.md)
  — pinning policy that applies to Codex CLI sandbox-permissions
  features (don't bet the farm on a flag upstream might remove).
- `prompts/codex-system.md` — the "no project writes" rule that
  remains the conversational layer of the defense.
- `test/smoke-v2-mvp.sh`, `test/smoke-v2-phase2-live.sh` — the
  empirical-verification layer that stays in place.

---

## References

- [Anthropic Claude Code: sandboxing](https://code.claude.com/docs/en/sandbox)
  — the model for how Claude Code itself sandboxes; Codex CLI is
  catching up to similar shape.
- [OpenAI Codex CLI changelog](https://developers.openai.com/codex/changelog)
  — sandbox-permissions feature evolution from 0.125 onward.
- [Sophos — Blast-radius reduction in AI agent deployments](https://www.sophos.com/en-us/blog/inside-the-lethal-trifecta-blast-radius-reduction-in-ai-agent-deployments)
  — industry framing for the trust-only failure mode that
  motivates this proposal.
- arXiv:2508.13465 (COLM 2025) — "LM Agents May Fail to Act on
  Their Own Risk Knowledge". Why trust-the-prompt fails under
  realistic load.
