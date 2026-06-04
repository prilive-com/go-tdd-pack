# Proposal — structural coupling between live smoke and Release publish

> Status: **proposal**. Not implemented.
> Action item A4 from [`POSTMORTEM-v2.1.0.md`](POSTMORTEM-v2.1.0.md).
> Decision needed: implement, defer with a trip-wire, or reject.

The postmortem listed A4 as "consider gating the GitHub Release
publish on a `LIVE_SMOKE_PASSED` workflow artifact stamped against
the same SHA as the tag." This document explores the options and
recommends a path. The author's recommendation is at the bottom.

---

## Problem

After [A1+A2](RELEASE_GUIDE.md#phase-3a--pre-tag-live-smoke-gate-non-negotiable),
the release workflow looks like this:

```
PR merged → main → maintainer runs pre-tag-smoke.sh locally
                → maintainer reads artifact verdict
                → maintainer chooses to tag (or not)
                → maintainer pushes tag
                → maintainer creates GitHub Release
```

The bolded link between "smoke passed" and "Release published" is
**maintainer discipline**. There is no mechanical block.

If the maintainer:

- forgets to run the script, or
- runs it on the wrong SHA, or
- runs it, sees a fail, and ships anyway (deadline pressure,
  optimism, "this fix is trivial"), or
- runs it, sees a pass, edits one file before tagging, and the edit
  invalidates the proof…

…the Release is published with no live-smoke proof and we are back
to the v2.1.0 failure mode.

A4 asks: can we make the smoke → release link structural rather
than disciplinary?

---

## Goal and non-goals

**Goal.** Make it **mechanically impossible** to publish a GitHub
Release for tag `vX.Y.Z` without a verifiable artifact showing the
two live smokes passed against the exact commit `vX.Y.Z` points at.

**Non-goal.** Replace the local pre-tag-smoke script. The script
stays as the fast loop maintainers use during a release. A4 adds the
trip-wire above it; it does not remove it.

**Non-goal.** Run the live smokes inside hosted CI on every merge.
The smokes cost real API tokens and need `codex login` auth; running
them per-merge is not justified.

---

## Options

Three viable shapes. They differ in where the smokes run and how the
proof crosses the local-to-CI boundary.

### Option A — Run live smokes in CI on tag push

A GitHub Actions workflow triggers on `push: tags: ['v*']`. The
workflow runs `bash test/smoke-v2-mvp.sh` and
`bash test/smoke-v2-phase2-live.sh` against the tag SHA. If both
pass, the workflow creates the GitHub Release via the API. If either
fails, the workflow leaves the tag alone and opens an issue.

| | |
|---|---|
| Trigger | `push: tags: ['v*']` |
| Auth | `CODEX_API_KEY` GitHub secret (Codex CLI supports API-key mode) |
| Cost | one live-smoke run per tag, paid by maintainer's API quota |
| Pro | fully automated; tag → Release is one push |
| Con | requires a Codex API key as a CI secret; that key has costs and a risk surface (token compromise via Action supply-chain attack) |
| Con | live smokes test API-key auth, not subscription auth; the v2.1.0 Bug 2 was specifically a subscription-auth crash. Pure-CI live smoke would NOT have caught Bug 2. |
| Con | not all adopters run on API-key auth; CI signal does not necessarily match adopter experience |

**Disqualifying issue:** A would not have caught v2.1.0 Bug 2. The
proof we want is "this release works on the same auth backend our
adopters use", and that is mostly subscription, not API key.

### Option B — Manual upload of a local artifact, validated by CI

The maintainer runs `pre-tag-smoke.sh` locally. The script (extended
for A4) signs the artifact with the maintainer's GPG key or computes
a SHA-256 over `(SHA + verdict + codex_cli_version)`. The maintainer
uploads the artifact as a release asset under a draft Release.

A GitHub Actions workflow triggers on the draft-Release event,
verifies the asset is present, the signature/hash is valid against
maintainer's published key, the SHA matches the tag, and the verdict
is PASS. If valid, the workflow flips the Release from draft to
published.

| | |
|---|---|
| Trigger | draft GitHub Release created via `gh release create --draft` |
| Auth | no Codex secrets in CI; maintainer's GPG key (already a release prerequisite if we sign tags) |
| Cost | one local live-smoke run per tag; zero CI runtime |
| Pro | uses the real adopter auth backend (whatever the maintainer ran locally) |
| Pro | no Codex secrets in CI; smaller attack surface |
| Con | requires GPG key management (some maintainers do not have one set up) |
| Con | maintainer can still spoof the artifact by signing whatever they want; the signature only proves the maintainer attested, not that the smoke actually ran |
| Con | "draft Release → published Release" is a less natural workflow than `gh release create` directly |

### Option C — Hybrid: tag push triggers a CI workflow that looks for a local-uploaded artifact

The maintainer runs `pre-tag-smoke.sh` locally, then uploads the
unsigned artifact to the tag as a release asset:

```bash
bash scripts/release/pre-tag-smoke.sh && \
  gh release create vX.Y.Z --draft --notes-file <(awk ...) && \
  gh release upload vX.Y.Z .tdd/release/pre-tag-smoke-$(git rev-parse --short HEAD).txt
```

A GitHub Actions workflow triggers on `push: tags: ['v*']`. It:

1. Waits up to 60 seconds for the artifact to appear (the maintainer
   may upload after pushing the tag).
2. Downloads the artifact for that tag.
3. Validates: SHA in artifact matches the tag's commit, verdict line
   says PASS, run timestamp is within the last 24 hours.
4. If valid, flips the draft Release to published.
5. If invalid or missing after timeout, opens an issue and leaves
   the Release as a draft.

| | |
|---|---|
| Trigger | `push: tags: ['v*']` + draft Release with asset |
| Auth | no Codex secrets in CI; no GPG required |
| Cost | one local live-smoke run per tag; one fast CI run per tag |
| Pro | uses real adopter auth; no CI secrets |
| Pro | no GPG dependency |
| Con | the artifact is unsigned; a determined attacker with push access could fake it. But anyone with push access can also bypass everything else (they could push directly to main, edit the script, etc.). The threat model here is "maintainer mistake", not "malicious actor". |
| Con | the 24-hour staleness check is a heuristic, not a proof |

---

## Recommendation

**Implement Option C. But not yet.**

Rationale:

- **The current process (A1+A2) is sufficient for the v2.1.0 failure
  mode.** The failure was "maintainer skipped a step that wasn't
  written down" plus "no smoke caught it". Both are fixed. A4 only
  helps if the maintainer ALSO bypasses the now-written-down A1+A2
  step.
- **A4 has real cost.** Option C is ~150 lines of GitHub Actions
  YAML, a script extension to upload the artifact, and ongoing
  workflow maintenance.
- **There is no current evidence the discipline is failing.** v2.1.1
  shipped cleanly with the new process. We have N=1 evidence the
  process works.

But we should be ready to flip the switch. The proposal below
encodes the design now so the implementation is a small commit, not
a fresh design exercise, when the trip-wire fires.

### Trip-wire (when to implement)

Implement A4 (Option C) on the first occurrence of any of:

1. A release ships that **skipped** `pre-tag-smoke.sh`.
2. A release ships with a `pre-tag-smoke.sh` artifact that recorded
   FAIL or PASS-against-wrong-SHA.
3. A multi-maintainer setup (we add a co-maintainer); discipline is
   harder to enforce across people.
4. Any third v2.x.z hotfix in a single quarter — that pattern
   suggests the lightweight gate is not catching enough.

Track the trip-wire status in the per-release retrospective if we
add one, or as a yearly "look at the last 4 releases" review.

### Defer with intent — what to write down now

This document. Plus a one-line note in
[`RELEASE_GUIDE.md`](RELEASE_GUIDE.md) at the bottom of Phase 3a
saying: "If maintainer discipline ever fails to catch a broken
release here, implement
[`PROPOSAL-release-gate-coupling.md`](PROPOSAL-release-gate-coupling.md)
Option C."

---

## Implementation sketch — Option C

If/when the trip-wire fires, here is the implementation. ~half a day
of work.

### 1. Extend `pre-tag-smoke.sh` to produce a uniform asset name

Already produces `.tdd/release/pre-tag-smoke-<SHORT_SHA>.txt`. Add a
flag `--for-release-asset` that copies the same content to
`.tdd/release/PRE_TAG_SMOKE_PASSED-<SHORT_SHA>.txt` only on success
(exit 0). The capitalized prefix is the asset name CI looks for.

### 2. Update the release-cut sequence in `RELEASE_GUIDE.md`

Phase 3b becomes:

```bash
# Run the gate (as today). Produces the asset if PASS.
bash scripts/release/pre-tag-smoke.sh --for-release-asset

# Tag.
git tag -a vX.Y.Z -m "vX.Y.Z release notes"
git push gh vX.Y.Z

# Create the Release as a DRAFT (do not publish yet).
gh release create vX.Y.Z --draft --notes-file <changelog-extract>

# Upload the asset.
SHORT=$(git rev-parse --short HEAD)
gh release upload vX.Y.Z ".tdd/release/PRE_TAG_SMOKE_PASSED-${SHORT}.txt"
```

The CI workflow takes over from here.

### 3. Add `.github/workflows/release-publish.yml`

```yaml
name: Publish release
on:
  push:
    tags: ['v*']
jobs:
  verify-and-publish:
    runs-on: ubuntu-latest
    permissions:
      contents: write   # to flip draft → published
    steps:
      - uses: actions/checkout@v6
        with:
          ref: ${{ github.ref }}
          fetch-depth: 0
      - name: Resolve tag SHA
        id: sha
        run: |
          full=$(git rev-list -n 1 "${{ github.ref_name }}")
          short=$(git rev-parse --short "$full")
          echo "full=$full"   >> "$GITHUB_OUTPUT"
          echo "short=$short" >> "$GITHUB_OUTPUT"
      - name: Wait for draft release + asset
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          # Try up to 5 minutes for the maintainer to upload the asset.
          for _ in $(seq 1 30); do
            if gh release view "${{ github.ref_name }}" \
                 --json assets --jq '.assets[].name' \
               | grep -q "^PRE_TAG_SMOKE_PASSED-${{ steps.sha.outputs.short }}\.txt$"; then
              exit 0
            fi
            sleep 10
          done
          echo "::error::no PRE_TAG_SMOKE_PASSED-${{ steps.sha.outputs.short }}.txt asset on release ${{ github.ref_name }}"
          gh issue create \
            --title "Release ${{ github.ref_name }} blocked: missing pre-tag-smoke proof" \
            --body "See PROPOSAL-release-gate-coupling.md"
          exit 1
      - name: Validate artifact
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh release download "${{ github.ref_name }}" \
            --pattern "PRE_TAG_SMOKE_PASSED-${{ steps.sha.outputs.short }}.txt" \
            --dir /tmp/release-asset
          asset=/tmp/release-asset/PRE_TAG_SMOKE_PASSED-${{ steps.sha.outputs.short }}.txt
          grep -q "sha:.*${{ steps.sha.outputs.full }}" "$asset" \
            || { echo "::error::asset SHA does not match tag SHA"; exit 1; }
          grep -q "verdict: OK to tag" "$asset" \
            || { echo "::error::asset verdict is not PASS"; exit 1; }
      - name: Publish draft release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: gh release edit "${{ github.ref_name }}" --draft=false --latest
```

### 4. Document the new flow in `RELEASE_GUIDE.md` Phase 4

Phase 4 was: "manually create the Release". Becomes: "publish happens
automatically when the workflow validates the artifact; the draft
release becomes the Latest release within ~5 minutes of the tag push
+ asset upload."

### 5. Counterfactual verification

Re-cut a throwaway test tag (e.g. `v0.0.0-test-release-gate`) and
verify:

- Without the asset uploaded, the workflow fails after the 5-minute
  wait and opens an issue, and the Release stays a draft.
- With a fake asset (SHA mismatch), the workflow fails on the SHA
  check.
- With a real PASS asset, the workflow publishes the Release.

---

## Open questions for the decision

If we are NOT implementing A4 today, the decision is "defer + write
the trip-wire". If we ARE implementing, the open questions are:

1. **Should the asset be signed?** Option B/C debate. Recommend
   unsigned for now (threat model is maintainer mistake, not
   malicious actor); revisit if the project grows.
2. **Should the workflow also fail the Release for a stale artifact**
   (e.g. older than 24 hours from the tag time)? Recommend yes,
   matches the "smoke ran against this tag, recently" intent.
3. **What does the trip-wire log look like?** Recommend: a short
   `docs/RELEASE_LOG.md` table with one row per release recording
   (tag, sha, pre-tag-smoke status, release-gate status). Three rows
   accumulated quickly is the signal to revisit A4 priority.

---

## Related

- [`POSTMORTEM-v2.1.0.md`](POSTMORTEM-v2.1.0.md) Bug 1 and Bug 2 —
  the failure modes that motivated this.
- [`RELEASE_GUIDE.md`](RELEASE_GUIDE.md) Phase 3a — the local gate
  this proposal would harden.
- [`UPSTREAM_DEPENDENCY_POLICY.md`](UPSTREAM_DEPENDENCY_POLICY.md) —
  drift detection mechanisms; A4 is one of them.
- `scripts/release/pre-tag-smoke.sh` — the script that already
  produces the artifact this proposal would validate.
