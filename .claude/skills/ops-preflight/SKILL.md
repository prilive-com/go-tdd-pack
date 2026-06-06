---
name: ops-preflight
description: Codex deep ops-safety review of a proposed Bash command BEFORE it executes. Invoke MANUALLY (via /ops-preflight) when the ops-risk-triage hook has emitted an `ask` for an infra_mutation, external_read, destructive, or unknown command and you want a second opinion on blast radius / rollback / required post-checks before approving. NOT for code review (use go-code-review). NOT auto-invoked.
disable-model-invocation: true
license: MIT
version: 1.0.0
---

# Ops Preflight — Codex deep review of a risky shell command

## When to use this skill

The ops-risk-triage hook (`hooks/ops-risk-triage.sh`) classifies every
Bash command via a fast Haiku classifier. When the classifier returns
an escalation-worthy verdict, the hook emits `permissionDecision:"ask"`
with the classifier's reason text. At that point you have three paths:

1. **Approve** — the operator is sure the command is safe; proceed.
2. **Deny** — the operator decides not to run it; rewrite or abort.
3. **Ops preflight (this skill)** — get a deep Codex review of blast
   radius, rollback, required post-checks, ownership/UID pitfalls,
   etc. BEFORE approving.

Use this skill when the ask was for a `local_mutation`,
`infra_mutation`, `external_read`, `destructive`, or `unknown` verdict
AND you want a deeper opinion. Skip for trivial cases.

## What this skill does

1. Reads the most recent classifier reason from
   `.tdd/ops-triage/pending-reason.txt` (the §9 fallback file written
   on every ask/deny). Use that to identify which command triggered the
   ask.
2. Builds a structured context object describing the command:
   - the command itself (the EXACT string the operator was about to run)
   - service / target (the service or target system being touched)
   - environment (dev / staging / prod / prod-like / unknown)
   - relevant compose / k8s / terraform files in the repo
   - recent operation tags (auth / container_uid / config — if known)
   - current container / service status (run `docker ps` etc. as input)
   - relevant recent log tail (last ~50 lines)
   - ownership / UID expectations (any container UID / GID constraints)
   - proposed rollback (a concrete rollback command if the change fails)
3. Pipes the context as JSON into
   `runner/ops-preflight-review.sh`, which calls
   `codex exec --output-schema schemas/ops-preflight-verdict.schema.json`.
4. Receives a STRICT JSON verdict (validated against the schema) with
   verdict, risk, findings, required_prechecks, required_postchecks,
   rollback, human_summary.
5. Writes the verdict to `.tdd/ops-preflight/<sha256(command)>.json`
   (the artifact governed mode (slice 5) will gate on for destructive
   commands).
6. Surfaces the human_summary + required_postchecks + rollback to the
   operator in chat for the approve/deny decision.

## Invocation

The operator types `/ops-preflight`. Claude (you) builds the context,
runs the script, and reports the verdict.

Example session:

```
operator: /ops-preflight

claude (you):
  Reading pending ask reason from .tdd/ops-triage/pending-reason.txt:
  "ops-triage (infra_mutation, conf=4): stub:infra restart/up — State
   blast radius + rollback, then approve or deny."

  Proposed command: docker compose up -d --build ainews-processor
  Target service: ainews-processor
  Environment: prod-like (based on cwd /srv/ainews)
  Recent ops tags: auth, container_uid  (from .tdd/ops-triage/session-tags.txt)
  Container status: running, healthy (just verified with docker ps)
  Relevant files: docker-compose.yml, .env present

  Calling Codex deep review...

  Verdict: approve_with_checks (risk: infra_mutation)

  Findings:
   - Rebuilding while auth changes are still in flight risks UID drift
     (the chown -R earlier this session targeted 1000:1000; container
     expects UID 1001)
   - Image rebuild loses any in-container state

  Required prechecks:
   - docker exec ainews-processor cat /etc/passwd | grep node  (verify UID)
   - Confirm .env values are the latest committed version

  Required postchecks:
   - docker ps                          (container actually started)
   - curl -fsS localhost:8080/health    (service responds)
   - docker logs --tail=100 ainews-processor  (no auth errors)

  Rollback:
   - docker compose up -d --no-build ainews-processor   (use previous image)

  Artifact written: .tdd/ops-preflight/<hash>.json

  My recommendation: run prechecks first; if the UID matches what the
  container expects, proceed; run postchecks immediately after.
```

## What you receive (the operator interface)

The skill is YOUR (Claude's) interface to the Codex deep review. You
build the context object, run the runner script, parse the verdict,
and report it in plain language. The operator does not need to see
JSON — they need:

1. The verdict word: approve / approve_with_checks / request_changes / block.
2. The risk tier.
3. The findings (what specifically worries the reviewer).
4. The prechecks they should run before the command (if any).
5. The postchecks they should run after (if approving).
6. The rollback command if it fails.
7. Your one-line recommendation: proceed / fix first / do not run.

## Failure modes

- **No pending ask** — `.tdd/ops-triage/pending-reason.txt` does not
  exist. Tell the operator there's no recent ask to preflight; ask
  what command they want reviewed.
- **codex CLI missing** — runner returns exit 1 with "codex CLI not
  on PATH". Tell the operator to install/authenticate Codex CLI per
  `docs/ADOPTION_GUIDE.md`.
- **codex auth failure** — runner returns exit 1, observe.log shows
  HTTP 400 / 401. Tell the operator to run `codex login`.
- **Malformed verdict** — runner returns exit 1 with "malformed
  verdict from reviewer". Rare; usually means the model returned
  prose instead of JSON. Retry once; if it persists, fall back to a
  manual blast-radius / rollback assessment with the operator.

## NOT this skill

- Code review of a Go file change → use `go-code-review`.
- Generating tests for a function → use `go-tdd-bugfix`.
- Reviewing the implementation correctness of the underlying service
  → that's Rail 1 (FDTDD), not this rail.

This skill exists for ONE purpose: a deep ops-safety opinion on
"will THIS shell command, run NOW, break THIS live system?"
