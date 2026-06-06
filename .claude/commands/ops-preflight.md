---
description: Codex deep ops-safety review of the command in .tdd/ops-triage/pending-reason.txt (or one you provide). Invoke after the ops-risk-triage hook emitted an `ask` and you want a second opinion on blast radius / rollback before approving. NOT for code review.
---

Run the `ops-preflight` skill (`.claude/skills/ops-preflight/SKILL.md`).

Steps:

1. Read `.tdd/ops-triage/pending-reason.txt` — the most recent
   classifier reason. If absent, ask the user which command to review.
2. Identify the proposed command from the classifier reason (or ask
   the user if the reason is ambiguous).
3. Build the structured context (service, environment, files, tags,
   status, logs, UID notes, proposed rollback). Use real shell
   inspection — `docker ps`, `docker logs --tail=50`, `git log -1`,
   etc. — to fill in the facts. Do NOT make up context.
4. Pipe the context as JSON into
   `runner/ops-preflight-review.sh`. The script writes the verdict
   artifact to `.tdd/ops-preflight/<sha256(command)>.json` and
   returns the verdict on stdout.
5. Parse the verdict and present it to the user in plain language —
   verdict, risk, findings, prechecks, postchecks, rollback, your
   one-line recommendation.

Failure modes are documented in `.claude/skills/ops-preflight/SKILL.md`
§ "Failure modes". Read that section if anything goes wrong.
