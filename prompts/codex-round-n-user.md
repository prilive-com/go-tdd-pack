This is round {{ROUND}} of {{MAX_ROUNDS}}.

In round 1 you returned these findings that were not yet resolved
(blocker/major only — minor/nit findings don't block convergence):

{{OPEN_FINDINGS}}

Claude has now responded:

{{CLAUDE_RESPONSE}}

The current diff (after Claude's response) is:

```diff
{{CURRENT_DIFF}}
```

## Your task this round

For each still-open finding:
  - Did Claude address it correctly? Mark resolved.
  - Did Claude push back with sound reasoning? Downgrade or retract.
  - Did Claude push back weakly? Hold the finding.

You may run commands, read files, and search the web — same access
as round 1. The no-write rule still applies; do not modify any
project file.

Return your reply with this exact ending block, on its own lines:

----
VERDICT: APPROVE
----

OR

----
VERDICT: REQUEST_CHANGES
----

Above the verdict line, write at most 8 sentences explaining which
findings remain open and why. If REQUEST_CHANGES, list each remaining
finding with a one-line `[severity] title: what's still wrong` format.

Stay terse. Claude reads this; the human does not.
