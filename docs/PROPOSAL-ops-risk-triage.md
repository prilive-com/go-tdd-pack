# Proposal — Ops Risk Triage (v2.2)

> Status: **proposal — implementation-ready slice plan, with one
> must-test-first risk on the `ask` UX channel**.
> Authors: combined consultant-v3 design + maintainer verification
> (2026-06-05).
> Supersedes: an earlier proposal (`PROPOSAL-ops-preflight-rail`,
> never merged) that violated the project's "no hardcoded commands"
> rule. Branch deleted; this doc is the live design.
>
> Slogan: **tiny agent classifies risk; Codex reviews risk; hooks
> enforce the handoff.**

---

## 0. Origin and how this differs from the earlier proposal

This proposal combines:

- A third consultant's design (delivered 2026-06-05 in
  `archive/files.zip`), which **correctly solves the "no hardcoded
  commands in starter pack" rule** that the first two designs
  violated.
- Maintainer verification of every load-bearing technical claim,
  performed via parallel research agents against current public
  sources. Three of twelve claims hold completely; five hold
  partially; one is unverifiable; two are wrong with consequence;
  one (the highest-stakes) is a real risk that must be empirically
  tested before shipping.
- Maintainer fixes for missing pieces (session-tags writer hook,
  Stop-hook ops-debt gate, smoke tests, hook-script parser bugs,
  catastrophic denylist gaps).

The architecture is the third consultant's. The empirical citations
and risk register are the maintainer's verification pass.

### Why the earlier proposal was wrong

The earlier `PROPOSAL-ops-preflight-rail` hardcoded specific command
patterns in the classifier (`docker compose --build`, `chown -R`,
`helm upgrade`, `kubectl delete namespace`, etc.) into a fixed
R0/R1/R2/R3 tier table. That directly violates the maintainer's
stated rule:

> "we decide to not check any command in starter pack, it should be
> in devopspoint but not in starter pack"
> "we don't hardcoded any commands"

The R0/R1/R2/R3 design failed this on every line. This proposal
does not.

---

## 1. The "no hardcoded commands" problem, solved

This design hardcodes **only two tiny user-editable lists at the
safe and catastrophic extremes**. The LLM owns the entire open
middle.

| List | Contents | Size | Owner | Purpose |
|---|---|---|---|---|
| Safe allowlist | obviously read-only command **names** (`ls`, `pwd`, `cat`, `git status`, …) | ~10 lines | adopter | fast-path: skip the model |
| Catastrophic denylist | truly irreversible **patterns** (`rm -rf /`, `terraform destroy`, force-push to protected refs, `DROP DATABASE`, …) | ~10 lines | adopter | fail-closed backstop under the model's miss tail |
| **Everything else** | the entire open middle | unbounded | **the LLM classifier** | classify → allow / ask / escalate |

Both lists ship as `*.example` files. Adopters copy and edit. The
**pack itself ships zero opinionated commands.**

### The safety rule that lets us drop the big trigger list

> **Unknown is not safe.** The classifier may return `allow` ONLY
> when it is confidently certain the command has no side effect.
> Anything uncertain, mutating, or unrecognized → escalate.

This is the inversion that makes the design work. Instead of
enumerating risky commands (an open set we cannot enumerate), we
let the model classify as **safe** only with high confidence, and
escalate everything else — including novel dangerous commands a
static list could never have caught.

---

## 2. Three layers

```
Bash PreToolUse  (command-type hook — see §3 for why)
  │
  ├─ LAYER 1: deterministic syntax parser (no AI)
  │     allow ONLY if: safe command NAME on the user allowlist
  │                    AND safe SHAPE
  │                      (no >, >>, <, |  into a mutator, no &&/||/;,
  │                       no $()/`/<()/>(), no sudo/doas/su,
  │                       no secret-like paths: .env, *.pem, *.key,
  │                       *secret*, *credential*, id_rsa, .kube/config)
  │     → allow, no model call, no prompt    [e.g. `pwd`, `git status`]
  │
  ├─ LAYER 1b: tiny user-owned CATASTROPHIC denylist (no AI)
  │     extended-regex patterns, fail-closed backstop
  │     → deny, no model call                [e.g. `rm -rf /`, `DROP DATABASE`]
  │
  └─ LAYER 2: tiny isolated classifier (fast LLM, no conversation context)
        forced question: "certainly safe/read-only, or escalate?"
        cached by hash, temperature 0, "unknown is not safe"
          ├─ safe_readonly / local_read (high confidence ≥4/5) → allow
          ├─ external_read (may leak data)                     → ask
          ├─ code_mutation (edits source/tests)                → defer to Rail 1 (TDD/file review)
          ├─ local_mutation / infra_mutation                   → ask + recommend Codex preflight
          ├─ destructive                                       → deny / require review
          └─ unknown                                           → escalate (ask)
        │
        └─ LAYER 3: Codex ops-preflight (deep review, only on escalation)
              "Will it break service? Lose data? Change ownership/auth?
               Rollback known? Required post-checks?"
              Strict-mode JSON schema (v2.1.0 Bug 1 lesson applied).
```

Three layers, three speeds:

- Layer 1: microseconds (no AI)
- Layer 2: sub-second cached small-model call
- Layer 3: multi-second Codex review (runs ONLY on escalation)

Codex is never in the hot path.

### Why a SYNTAX parser, not just a name allowlist (Layer 1)

`pwd` is safe; `pwd > file.txt` writes a file; `git status && docker
compose restart app` restarts a service; `cat .env` leaks secrets;
`docker ps | xargs docker restart` mutates. The allowlist matches
**command name AND syntax shape**. A command fast-paths only when
its name is on the safe list AND it has none of: output redirection,
shell chaining, command substitution, a pipe into a non-safe
command, `sudo`, write-like flags, or a secret-like path.

### Reasoning-blind classifier (Layer 2)

The classifier receives **minimal structured facts**, NOT Claude's
prose narrative:

```json
{
  "command": "docker compose up -d --build ainews-processor",
  "cwd": "/srv/ainews",
  "environment_hint": "prod | staging | dev | unknown",
  "repo_files_present": ["docker-compose.yml", ".env"],
  "recent_operation_tags": ["auth", "container_uid", "config"],
  "safe_if_uncertain": false
}
```

This pattern matches Anthropic's own Auto Mode classifier, which
they call "reasoning-blind by design" precisely so the agent cannot
talk the classifier into making a bad call ([Anthropic Auto Mode
engineering post](https://www.anthropic.com/engineering/claude-code-auto-mode)).
The `recent_operation_tags` array (`auth`, `container_uid`, `config`)
drives the incident-specific escalation: a normally-`infra_mutation`
restart becomes `destructive` when those tags are present (the exact
outage pattern from the original incident).

---

## 3. Verified platform mechanisms (June 2026)

Every load-bearing platform claim was checked against current public
sources before this proposal was written.

| Mechanism | Verdict | Source |
|---|---|---|
| Bug #55889 (Bash context-injection drop) closed not-planned 2026-06-01 | **TRUE** | [#55889](https://github.com/anthropics/claude-code/issues/55889) |
| Bug #39344 (ask silently overrides settings.json deny) closed wontfix 2026-04-25 | **TRUE** | [#39344](https://github.com/anthropics/claude-code/issues/39344) |
| `permissionDecision: "deny"` + `permissionDecisionReason` reaches the model on Bash | **TRUE** | [#55889 carve-out language](https://github.com/anthropics/claude-code/issues/55889) |
| `permissionDecision: "ask"` itself fires on Bash | **TRUE** | hooks docs |
| `permissionDecisionReason` text on the `ask` path visibly reaches the **operator** on Bash | **MUST-TEST-FIRST** — verification surfaced uncertainty; see §10 | conflicting evidence between two verification rounds |
| Stop hook `{"decision":"block","reason":"..."}` reaches the model via continuation channel | **TRUE** | [hooks docs](https://code.claude.com/docs/en/hooks.md), [v2.1.163 changelog](https://github.com/anthropics/claude-code/releases) |
| Claude Haiku 4.5 valid model ID, temperature 0 supported, suitable for narrow classification | **TRUE** | [docs.claude.com models](https://docs.claude.com/en/docs/about-claude/models) |
| Hook types supporting `permissionDecision`: `command`, `http`, `mcp_tool` | **TRUE** (consultant said only `command`; that was oversold) | [hooks docs](https://code.claude.com/docs/en/hooks.md) |
| `disable-model-invocation: true` makes Skill manually-invoked only | **TRUE** | [skills docs](https://code.claude.com/docs/en/skills.md) |
| openai/codex #15451 (`--output-schema` dropped with MCP) closed | **TRUE** | [#15451](https://github.com/openai/codex/issues/15451) |

### Empirical evidence behind the design

The thesis that drives this whole proposal — **"the failure is a
triggering gap, not a knowledge gap"** — is supported by a real
published paper:

- [arXiv:2508.13465 (COLM 2025): "LM Agents May Fail to Act on
  Their Own Risk Knowledge"](https://arxiv.org/abs/2508.13465).
  Agents score >98% on direct risk questions, but accuracy drops
  >23% on scenario identification and <26% on avoiding risky
  execution. The model knows what is dangerous; it forgets to
  pause.

The classifier-miss-rate that motivates the catastrophic denylist
backstop is also real:

- Anthropic's own Auto Mode post reports a **17% false-negative
  rate** for the safety classifier on their curated incident set
  (Table 1, "the honest number"). Caveat: arXiv 2604.04978 found
  81% FNR on deliberately adversarial conditions. The 17% number
  is the realistic-operator-session baseline; the denylist needs
  to be slightly broader than the consultant's 10-line draft (see
  §7).

---

## 4. Empirical claims from the consultant that did NOT survive verification

The consultant explicitly refused to research, saying "design is
fully settled." Verification surfaced five issues. These are
flagged so the proposal does not inherit the consultant's false
precision.

| Consultant claim | Verdict | Replacement framing |
|---|---|---|
| "~25% of borderline prompts can flip across runs" | **UNVERIFIABLE specific number** (phenomenon is real: Atil et al. arXiv 2408.04667 reports up to 15% accuracy variation, up to 70% best-worst gaps; Thinking Machines blog explains batch-variance) | "LLM classifiers are nondeterministic on borderline cases; cache by hash to make repeats deterministic; temperature 0 and bias to escalate on low confidence." |
| "Recommendations ignored ~30% of the time" (CLAUDE.md compliance ~70%) | **COMMUNITY-BLOG-GRADE**, no Anthropic-official number; my earlier research found community evals 50–84% variable | "Prose guidance decays in long sessions (lost-in-distance, arXiv 2410.01985); the harness must trigger, not the model's memory." |
| "Anthropic's ~17% FNR" used to justify a tiny denylist | **TRUE but optimistic** for adversarial conditions | Same number, with adversarial-scenario caveat noted; denylist sized accordingly (see §7). |
| "Only `command`-type hooks can do allow/ask/deny" | **PARTIAL** — `command`, `http`, and `mcp_tool` all support `permissionDecision`; only `prompt` and `agent` are binary | Architecture choice (command-type calling Haiku via API) is correct; framing was oversold. |
| "Bias to escalate on low confidence" presented as 2025-2026 industry standard | **PARTIAL** — sensible design pattern, not a documented industry norm | Presented as a design choice, not consensus. |

These issues do not invalidate the architecture. They do mean the
proposal cannot cite the consultant's specific numbers without
qualification.

---

## 5. Modes

```toml
[ops_triage]
enabled = false              # off by default (opt-in)
mode = "ask"                 # off | observe | ask | governed
classifier = "haiku"         # haiku | codex | none(deterministic-only)
fail_closed = true           # classifier error/timeout → escalate, never allow
```

| Mode | infra/local mutation | destructive | Behavior |
|---|---|---|---|
| `off` | allow | allow | triage disabled (pack as before) |
| `observe` | log | log | classify + log, never interrupt (gather data) |
| `ask` | **ask** + recommend Codex | ask | **default** — soft gate, operator decides |
| `governed` | ask | **deny** until Codex preflight artifact exists | hard-gate the irreversible tier |

Default `ask`. Move to `governed` for unattended/CI sessions or
unrecoverable-blast-radius repos.

Default `enabled = false` per v2.1.1 lesson (shipped default must
match the "off by default" promise; `smoke-config-default-consistency.sh`
should be extended to assert this for the new key).

---

## 6. Components

```
hooks/
  ops-risk-triage.sh           PreToolUse Bash command-hook (the three layers)
  ops-debt-stop.sh             Stop hook → block while unresolved ops-debt exists
  ops-tag-postuse.sh           PostToolUse Bash hook → writes session-tags on auth/uid ops
runner/
  ops-triage-classify.sh       calls the fast model (Haiku), returns strict JSON (cached)
  ops-preflight-review.sh      Layer 3: codex exec --output-schema deep review
prompts/
  ops-risk-classifier.md       fast-classifier prompt (no code review)
  codex-ops-preflight.md       Codex ops-safety prompt
schemas/
  ops-triage-verdict.schema.json
  ops-preflight-verdict.schema.json
.claude/skills/ops-preflight/
  SKILL.md                     disable-model-invocation: true (advisory playbook)
config/
  ops-safe-allowlist.txt.example         ships as .example; adopter copies + edits
  ops-catastrophic-denylist.txt.example  ships as .example; adopter copies + edits
.tdd/
  ops-triage/cache/<hash>.json       classifier cache
  ops-triage/session-tags.txt        rolling list of recent operation tags
  ops-preflight/<hash>.json          accepted deep-review artifacts (governed mode)
  ops-debt/<hash>.json               risky commands that ran without preflight
```

**Gate 4 extension.** `hooks/protect-tdd-artifacts.sh`
PROTECTED_PREFIXES gets three new entries: `.tdd/ops-triage/`,
`.tdd/ops-preflight/`, `.tdd/ops-debt/`. One-line change per prefix.

**Pieces the consultant's deliverable was missing:**

- `hooks/ops-tag-postuse.sh` — the session-tags writer. The spec
  references `recent_operation_tags` driving the
  rebuild-after-chown escalation (the original outage pattern)
  but the consultant did not ship a hook that populates the file.
  Without it, the most important incident-specific lesson does not
  fire.
- `hooks/ops-debt-stop.sh` — referenced as "still applies from the
  prior Ops Preflight spec" but not delivered. Re-ship here.
- Smoke tests — zero in the deliverable. See §11.

---

## 7. Catastrophic denylist — broader than the consultant's draft

The 17% FNR baseline is on Anthropic's curated set, not adversarial
conditions. For the denylist (the fail-closed backstop), under-coverage
is a real risk. The consultant's draft has three known gaps:

1. **Force-push detection too narrow.** Their pattern
   `git[[:space:]]+push[[:space:]]+.*--force(...).*(main|master|prod)`
   does not catch `git push -f origin main` (short flag) or
   `git push --force origin refs/heads/main`.
2. **`kubectl delete` flag-order brittle.** Their pattern does not
   catch `kubectl -n prod delete namespace foo` (namespace flag
   before subcommand) or `kubectl delete pvc -A`.
3. **`dd` device patterns narrow.** Their pattern catches
   `dd of=/dev/sd*` but not `dd of=/dev/disk0` on macOS.

The denylist that ships should cover all variants. Counterfactual-
verify each pattern against both true-positives and obvious
near-misses, the same way `smoke-schema-strict-mode.sh` was
counterfactual-verified in v2.1.1.

Strawman list to refine:

```
# Recursive root destruction
rm[[:space:]]+(-[rRf]+|--recursive([[:space:]]|=)|--force([[:space:]]|=))+.*[[:space:]]+(/|~|\$HOME|\.\.|\$PWD)

# Filesystem destruction
mkfs(\.|[[:space:]])
dd[[:space:]]+.*[[:space:]]+of=/dev/(sd|nvme|disk|hd|mmcblk|vd)
shred[[:space:]]+.*/dev/(sd|nvme|disk)

# Fork bombs
:[[:space:]]*\(\)[[:space:]]*\{[[:space:]]*:[[:space:]]*\|

# Terraform irreversible
terraform[[:space:]]+(destroy|apply)[[:space:]].*-auto-approve

# Force-push to protected refs (both short and long flag)
git[[:space:]]+push[[:space:]]+(-[a-zA-Z]*[fF][a-zA-Z]*|--force([[:space:]]|=)[^[:space:]]*).*[[:space:]]+(main|master|prod|production|release/)
git[[:space:]]+push[[:space:]]+(-[a-zA-Z]*[fF][a-zA-Z]*|--force([[:space:]]|=)[^[:space:]]*).*refs/heads/(main|master|prod|production)

# Database / schema destruction
DROP[[:space:]]+(DATABASE|SCHEMA|TABLE)
TRUNCATE[[:space:]]+TABLE
drizzle-kit[[:space:]]+push[[:space:]]+.*--force

# Kubernetes namespace / PVC / CRD destruction (handle flag order)
kubectl([[:space:]]+--?[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+delete[[:space:]]+(namespace|ns|pv|pvc|crd|customresourcedefinition)
kubectl([[:space:]]+--?[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+delete[[:space:]]+--all
helm[[:space:]]+uninstall

# Secret/cert rotation patterns
(openssl|aws[[:space:]]+secretsmanager|gcloud[[:space:]]+secrets|vault[[:space:]]+kv)[[:space:]]+.*rotate
```

Each pattern needs a smoke that confirms (a) the pattern matches the
true-positive examples and (b) it does NOT match obvious
near-misses (`git push --force-with-lease`, `kubectl delete pod`,
`rm -rf /tmp/build`).

---

## 8. The `ask`-mode UX risk and the MUST-TEST-FIRST item

The single highest-risk item in this proposal.

**The risk:** the third consultant claimed `permissionDecision:"ask"`
with `permissionDecisionReason` works on Bash (bug #55889 is
"irrelevant because we gate via permissionDecision"). The
verification confirmed `permissionDecision` itself fires AND that
`permissionDecisionReason` reaches the model on `deny`. But one
verification round surfaced a specific concern that
`permissionDecisionReason` text on the `ask` path may not be
visible to the **operator** (different surface from "reaches the
model"). Evidence is conflicting between rounds.

**Why this matters:** if the operator gets an `ask` prompt with no
visible reason, the entire "soft middle layer" pitch breaks. The
operator either rubber-stamps (worse than no gate) or refuses
randomly (worse than allow-by-default).

**The test recipe** (5 minutes, copy-paste):

```bash
# 1. Create a sentinel hook in your project.
mkdir -p hooks
cat > hooks/test-ask-visibility.sh <<'EOF'
#!/usr/bin/env bash
INPUT=$(cat)
CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null)
if [[ "$CMD" == *__ops_triage_visibility_test__* ]]; then
  jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:"SENTINEL_REASON_STRING_12345 — does this text appear in the operator prompt?"}}'
fi
exit 0
EOF
chmod +x hooks/test-ask-visibility.sh

# 2. Register it as a PreToolUse Bash hook in .claude/settings.json
#    (merge into existing PreToolUse array; do not blind-overwrite).

# 3. Trigger from a Claude Code session:
#    bash -c "echo __ops_triage_visibility_test__"

# 4. Watch the ask prompt. Does "SENTINEL_REASON_STRING_12345" appear?
#    YES → proposal ships as designed.
#    NO  → fall back to the workaround in §9.

# 5. Clean up.
rm -f hooks/test-ask-visibility.sh
# revert the .claude/settings.json change.
```

**Do this on v2.1.165 (the version where #55889 is closed
not-planned) before slice 3 ships.** If the result is NO, the design
falls back to §9.

---

## 9. Workaround if the `ask` reason text does not surface

Two layers of fallback, both cheap:

1. **Write the reason to a well-known file.** The hook always writes
   the current pending-decision reason to
   `.tdd/ops-triage/pending-reason.txt`. The operator can
   `cat .tdd/ops-triage/pending-reason.txt` to see the rationale.
   Document this in `CLAUDE.md` so Claude itself surfaces the file
   when the operator asks "why did you ask?".
2. **Compose the reason into the command echo Claude sees.** The
   hook can also append a structured comment line that Claude will
   see in its own prior-turn context:
   `[ops-triage: <reason>]`. This does not require the broken Bash
   context channel — it goes through the model context that does
   work on `deny`. Caveat: this would only fire when the hook
   *converts* an `ask` into a `deny`, surfacing the reason to the
   model. For pure `ask` paths that stay `ask`, the file fallback
   is the operator's path.

These workarounds keep the design alive even if #55889 makes the
`ask` reason invisible. They are not as elegant as a working `ask`
+ reason path, but they are honest engineering.

---

## 10. Build slices

Six slices. Slices 1–3 are the MVP and would have caught every
command in the original incident at the moment of action.

| Slice | Scope | When to ship |
|---|---|---|
| **1** | Layer 1 deterministic parser + the two user-owned `.example` lists + `observe` mode | first; logs classifications, never interrupts; collect a week of real workload data before going further |
| **2** | Layer 2 classifier + caching + "unknown is not safe", still `observe` | after slice 1 has classification data; tune the prompt against the incident log before turning on `ask` |
| **3** | `ask` mode goes live, default | **only after the §8 must-test-first item passes** (or §9 workaround is in place) |
| **4** | Layer 3 Codex deep-review + `/ops-preflight` skill (`disable-model-invocation: true`) | once the `ask`-mode operator-experience data shows where deep review actually adds value |
| **5** | `governed` mode (R3 `deny` until artifact) + Stop-hook ops-debt gate + Gate 4 path extension | for adopters running unattended / CI sessions |
| **6** | Session-tags writer hook + R2→R3 auth/UID escalation (the specific fix for the original incident) | last; the most state-tracking-heavy piece |

Slice 6 sits last by design. The escalation pattern requires
slices 1–4 to be stable and producing real classifications; pulling
it forward is over-engineering before the foundation is real.

---

## 11. Smoke tests

Minimum set to ship slice 1. Each smoke is counterfactual-verified
the way `smoke-schema-strict-mode.sh` was in v2.1.1 — i.e. confirm
the smoke fails when you re-introduce the bug it guards against.

- **Layer 1 parser — positive cases.** `pwd`, `ls`, `git status`,
  `git diff`, `docker ps`, `kubectl get pods` → fast-path (exit 0,
  no JSON).
- **Layer 1 parser — negative cases.** `cat .env`, `pwd > file.txt`,
  `git status && docker compose restart app`, `echo "x" | sudo tee
  /etc/foo`, `git status; rm -rf .` → all fall through to Layer 2
  (no fast-path allow).
- **Catastrophic denylist — true-positive matches.** Each pattern
  in `config/ops-catastrophic-denylist.txt` matches at least one
  example from the §7 strawman.
- **Catastrophic denylist — near-miss does NOT match.** `git push
  --force-with-lease origin main`, `kubectl delete pod my-pod`,
  `rm -rf /tmp/build`, `terraform plan` (not destroy) → all fall
  through, NOT denied by the denylist.
- **Schema strict-mode regression** — the existing
  `test/smoke-schema-strict-mode.sh` (shipped in v2.1.1) covers
  `schemas/ops-triage-verdict.schema.json` and
  `schemas/ops-preflight-verdict.schema.json` automatically. No
  new smoke needed.
- **Cache write/read.** Same command in same context produces same
  verdict from cache on second invocation; no model call on second
  invocation.
- **Fail-closed.** `classifier=haiku` with no `ANTHROPIC_API_KEY` set
  → Layer 2 fails → emit `ask` with "fail-closed" reason (never
  allow).
- **Disabled-safe.** `PRILIVE_REVIEW_DISABLE=1` → hook exits 0
  immediately, no JSON, no classification (pack-as-before
  invariant).
- **§8 ask-reason-visibility** — the sentinel test from §8 is run
  manually before slice 3, with the result recorded in
  `docs/RESEARCH-ask-visibility-v2.1.165.md`.

---

## 12. Where this lives

This design respects the "no hardcoded commands in starter pack"
rule (§1). It can land in **starter (opt-in)** or in **devopspoint**.
Trade-offs:

- **Starter opt-in (recommended).** The framework ships in starter.
  Adopter configs (`config/ops-*.txt.example`) ship as examples.
  Code-review-only adopters never enable the feature; the
  hardcoded surface in the pack is zero opinionated commands.
  Default `enabled = false`.
- **devopspoint.** Pure separation. The framework moves out of
  starter entirely. Adopters who do not run devopspoint cannot
  access the feature.

**Recommendation: starter opt-in.** The framework is generic
(parser + Haiku + Codex + Stop-hook + Gate 4 extension), the
adopter configs are user-editable examples, and the disabled-
default keeps the rule honoring honest. devopspoint can layer
domain-specific configs on top later if useful.

---

## 13. Honest limits

- **The §8 `ask`-reason-visibility test is the highest-risk
  unknown.** If it fails, the design degrades to §9 workarounds
  (write reason to file, operator `cat`s it). The workarounds are
  honest engineering but less elegant.
- **The model classifier has a real false-negative tail.** Anthropic
  publishes 17% on curated incidents; arXiv 2604.04978 reports 81%
  under adversarial conditions. The catastrophic denylist is the
  floor under the miss; it must be broader than the consultant's
  10-line draft (see §7).
- **LLM nondeterminism is bounded, not eliminated.** Caching makes
  repeats deterministic; genuinely novel commands stay
  probabilistic. That is the price of dropping the static list, and
  it buys coverage of novel dangerous commands the static list
  could not have caught.
- **Approval fatigue is the real failure mode.** If `ask` fires too
  often you will rubber-stamp. Tune by **widening Layer 1's safe
  fast-path** (more provably-safe shapes), never by lowering the
  classifier's bar. Watch the rate.
- **Latency cost.** Layer 2 adds ~300-800ms of cached Haiku call to
  non-fast-pathed commands. Acceptable. Routing every command
  through Codex would not be (30-60s) — that is why Codex is Layer
  3 only.
- **External API dependency.** Layer 2 with `classifier = "haiku"`
  requires `ANTHROPIC_API_KEY`. Adopters on Codex subscription
  only can use `classifier = "codex"` (slower) or `classifier =
  "none"` (deterministic-only; escalates everything not in Layer 1).
- **The 25% nondeterminism number and the 30% prose-ignored number
  are NOT cited** in this proposal because verification could not
  find primary sources. The phenomena they describe are real; the
  specific numbers were the consultant's false precision.
- **#55889 is permanent.** Anthropic closed it not-planned 2026-06-01.
  The design routes around it for `deny` (works), and §8/§9 manage
  the residual risk for `ask`.

---

## 14. Open questions for the slice-1 PR

1. The lists ship as `*.example`. Should the slice-1 install step
   include a check that says "no `config/ops-*.txt` present —
   ops-triage is enabled but will fall back to escalate-everything
   until you create the lists"? Or is the fail-closed escalation
   itself sufficient signal?
2. The `cache by hash` key currently includes
   `{command, cwd, environment_hint, mode}`. Should it also
   include the SHA of the user's
   `config/ops-safe-allowlist.txt` + `config/ops-catastrophic-denylist.txt`,
   so an adopter editing those files invalidates the cache? Probably
   yes; missing detail to add to slice 2.
3. Should `external_read` (curl GET, api fetch) be `ask` or
   `observe-and-allow`? Curl to a known internal endpoint is
   different from curl to an attacker-controlled URL. Tune after
   slice 2 data.
4. The session-tags writer (slice 6) — what writes the
   `auth`/`container_uid`/`config` tags into `.tdd/ops-triage/session-tags.txt`?
   A PostToolUse hook on Bash that pattern-matches on the executed
   command is the natural place but adds a second Bash hook (cost:
   small; complexity: low).
5. Should this proposal merge or stay open until the §8 test runs?
   Recommend: merge now (the design is solid even with §9
   fallback); add a follow-up doc
   `RESEARCH-ask-visibility-v2.1.165.md` once the test runs.

---

## 15. Recommendation

**Merge this proposal. Build slices 1–2 in observe mode. Run the §8
test before slice 3. Then proceed to slices 3–6 with the trip-wire
patterns we used in `PROPOSAL-release-gate-coupling.md` and
`RESEARCH-A5-dynamic-model-selection.md`.**

The design is the best of the three iterations:

- It correctly honors the "no hardcoded commands" rule.
- It empirically grounds the design in real published evidence
  (arXiv 2508.13465, Anthropic Auto Mode).
- It applies the v2.1.0 Bug 1 lesson without being told (strict-
  mode schema).
- It is testable in small slices, with the highest-risk item (§8
  `ask` UX) deferred behind an explicit gate.

The verification fixes:

- Pruned five false claims (specific numbers, hook-type framing,
  "industry standard" overreach).
- Identified the missing pieces (session-tags writer, Stop-hook,
  smokes).
- Broadened the catastrophic denylist beyond the 10-line draft.
- Surfaced the §8 risk that the consultant glossed.

---

## 16. Related

- [`POSTMORTEM-v2.1.0.md`](POSTMORTEM-v2.1.0.md) — the v2.1.0
  incident whose lessons (strict-mode schema, model pin, smoke
  counterfactual verification) shaped this proposal.
- [`UPSTREAM_DEPENDENCY_POLICY.md`](UPSTREAM_DEPENDENCY_POLICY.md) —
  Haiku 4.5 model pin should be added to the table after slice 2
  ships.
- [`RELEASE_GUIDE.md`](RELEASE_GUIDE.md) Phase 3a — the live-smoke
  gate that will protect the v2.2.0 release from a v2.1.0-style ship.
- [`PROPOSAL-release-gate-coupling.md`](PROPOSAL-release-gate-coupling.md)
  — the "defer-with-trip-wire" pattern this proposal also uses.
- [`RESEARCH-A5-dynamic-model-selection.md`](RESEARCH-A5-dynamic-model-selection.md)
  — same honest research style.
- `test/smoke-schema-strict-mode.sh` — will validate
  `schemas/ops-triage-verdict.schema.json` and
  `schemas/ops-preflight-verdict.schema.json` automatically; no new
  smoke needed for that surface.

---

## References

### Verified platform issues

- [#55889 — Bash context-injection dropped, closed not-planned 2026-06-01](https://github.com/anthropics/claude-code/issues/55889)
- [#39344 — ask shadows permissions.deny, closed wontfix 2026-04-25](https://github.com/anthropics/claude-code/issues/39344)
- [#10412 — plugin Stop hooks exit-2 quirk, closed 2025-11-12](https://github.com/anthropics/claude-code/issues/10412)
- [openai/codex #15451 — --output-schema dropped with MCP, closed](https://github.com/openai/codex/issues/15451)

### Primary empirical sources

- arXiv:2508.13465 (COLM 2025), Tang et al., [*LM Agents May Fail to Act on Their Own Risk Knowledge*](https://arxiv.org/abs/2508.13465).
- Anthropic, [Claude Code Auto Mode](https://www.anthropic.com/engineering/claude-code-auto-mode) — 17% FNR, reasoning-blind classifier.
- arXiv:2410.01985 — lost-in-distance (context-distance accuracy decay).
- arXiv:2408.04667 (Atil et al.) — LLM nondeterminism, up to 15% accuracy variation, up to 70% best-worst gap.
- [Thinking Machines: Defeating Nondeterminism in LLM Inference](https://thinkingmachines.ai/blog/defeating-nondeterminism-in-llm-inference/).

### Skill auto-invocation reliability (community evals, no Anthropic official)

- [Scott Spence — measuring Claude Code skill activation with sandboxed evals](https://scottspence.com/posts/measuring-claude-code-skill-activation-with-sandboxed-evals).
- [Stack AI — audited 214 Claude Code skills, 73 silently broken](https://dev.to/thestack_ai/i-audited-214-claude-code-skills-73-were-silently-broken-2m9a).

### Industry sources for AI-agent risk classification

- Tian Pan, [Agent blast radius: bounding worst-case impact in production](https://tianpan.co/blog/2026-05-05-agent-blast-radius-bounding-worst-case-impact-production), May 2026.
- Sophos, [Inside the lethal trifecta: blast-radius reduction in AI agent deployments](https://www.sophos.com/en-us/blog/inside-the-lethal-trifecta-blast-radius-reduction-in-ai-agent-deployments).
- MindStudio, [Classify AI agent actions by risk](https://www.mindstudio.ai/blog/classify-ai-agent-actions-by-risk).
- [Software Analyst Substack: Runtime security for AI agents](https://softwareanalyst.substack.com/p/runtime-security-for-ai-agents-an).
- [Cloud Security Alliance: Control the chain, secure the system](https://cloudsecurityalliance.org/blog/2026/03/25/control-the-chain-secure-the-system-fixing-ai-agent-delegation), 2026-03-25.
