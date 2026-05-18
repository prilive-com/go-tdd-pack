# Release Guide — Prilive Go TDD Pack v2.0

> **Audience:** The pack maintainer (and any future co-maintainers).
>
> Process for cutting a release. Follow in order; skip none.

---

## Pre-release one-time setup (before v2.0.0 public tag)

These are governance prerequisites for OSS launch. Each is one-time.

### 1. Enable GitHub Private Vulnerability Reporting

1. Settings → Security → Code security and analysis
2. Under "Private vulnerability reporting", click **Enable**
3. Verify in incognito: `https://github.com/prilive-com/go-tdd-pack/security/advisories/new` should show the new-advisory form

### 2. Install cncf/dco2 GitHub App

1. https://github.com/apps/dco → **Configure**
2. Select `prilive-com` → choose `go-tdd-pack` (or "All repositories")
3. Add `.github/dco.yml`:
   ```yaml
   require:
     members: true
   ```
4. Commit signed: `git add .github/dco.yml && git commit -sm "Add DCO config"`
5. Test by opening a PR with an unsigned commit — DCO check should fail

### 3. Fill placeholders in governance files

Search/replace across `LICENSE`, `SECURITY.md`, `CODE_OF_CONDUCT.md`,
`CONTRIBUTING.md`, `README.md`:

| Placeholder | Replace with |
|---|---|
| `<MAINTAINER_NAME>` or `<MAINTAINER>` | `Prilive` |
| `<MAINTAINER_GH>` | `prilive-com` |
| `<SECURITY_EMAIL>` | `prilive.company@gmail.com` |
| `<YEAR>` | `2026` |

The README badge URLs reference `prilive-com/go-tdd-pack`. If you pick
a different GitHub org or repo name, update both `README.md` and
`.claude-plugin/plugin.json`.

### 4. Apply for OpenSSF Best Practices Badge (optional, post-launch OK)

1. https://www.bestpractices.dev/en/projects/new
2. Sign in with GitHub
3. Submit `https://github.com/prilive-com/go-tdd-pack`
4. Fill the questionnaire (save partial progress; can take a week)
5. After award, add the badge to `README.md`

Not blocking for v2.0.0 launch.

---

## Per-release checklist

For every release, run in order. Each step is small; skipping any of
them is how broken releases happen.

### Phase 1 — Code freeze and verification

- [ ] All planned features merged to `main`.
- [ ] Working tree clean: `git status` shows no uncommitted changes.
- [ ] Run the full smoke suite:
  ```bash
  bash test/smoke-v2-phase2.sh        # 25 unit checks
  bash test/smoke-tool-grounding.sh   # 12 fixture checks
  bash test/smoke-v2-mvp.sh           # 1 real Codex call
  bash test/smoke-v2-phase2-live.sh   # 2 real Codex calls, multi-round
  ```
  All four must PASS.
- [ ] Validate every JSON file parses:
  ```bash
  for f in $(find . -name '*.json' -not -path './.git/*'); do
    jq empty "$f" || echo "BROKEN: $f"
  done
  ```
- [ ] Validate every shell script parses:
  ```bash
  for f in hooks/*.sh runner/*.sh test/smoke-*.sh; do
    bash -n "$f" || echo "BROKEN: $f"
  done
  ```

### Phase 2 — Documentation

- [ ] `CHANGELOG.md` has a new entry under `[Unreleased]` describing
  every notable change.
- [ ] Move `[Unreleased]` entries into a new `## [vX.Y.Z] - YYYY-MM-DD`
  section.
- [ ] Reset `[Unreleased]` to `_No unreleased changes._`
- [ ] Update `.claude-plugin/plugin.json` `version` field to match.
- [ ] If hook contract changed, behaviorally-relevant config changed,
  or schema changed: write a dated update note under `docs/`
  (`UPDATE_YYYY-MM-DD.md`) for adopters to apply the patch.
- [ ] Cross-link the new update note from `README.md`'s Documentation
  table.

### Phase 3 — Version bump and tag

```bash
# Update plugin.json version
jq '.version = "X.Y.Z"' .claude-plugin/plugin.json > /tmp/plugin.json
mv /tmp/plugin.json .claude-plugin/plugin.json

# Commit
git add .claude-plugin/plugin.json CHANGELOG.md
git commit -sm "release: vX.Y.Z"

# Tag (signed if you have a GPG key set up)
git tag -a vX.Y.Z -m "vX.Y.Z release notes" # or -s for signed tag

# Push
git push origin main
git push origin vX.Y.Z
```

### Phase 4 — GitHub release

1. Go to `https://github.com/prilive-com/go-tdd-pack/releases/new`
2. Choose tag `vX.Y.Z`
3. Title: `vX.Y.Z — short headline`
4. Body: copy the CHANGELOG.md section for this version
5. Mark pre-release if vX.Y.Z is `-rc.N`, `-beta.N`, etc.
6. Publish

### Phase 5 — Marketplace sync (if registered)

If the pack is registered in a Claude Code plugin marketplace, bump the
version in that marketplace's manifest as well so adopters pick up
`/plugin upgrade go-tdd-pack` correctly.

---

## Versioning policy (SemVer 2.0)

- **Major (X.0.0):** breaking change to hook contract, runner state
  shape, or config schema that requires adopter intervention.
  Example: v1.x → v2.0 (ceremony model removed; new state files).
- **Minor (0.X.0):** new feature, new hook, new optional config knob.
  Example: adding a new tool to grounding (gosec, etc.).
- **Patch (0.0.X):** bugfix or doc-only change.
  Example: monorepo-aware tool grounding fix from 2026-05-17.

When in doubt: if a v1.x project picks up your change without doing
anything, it's a patch. If they need to copy files, it's a minor. If
they need to delete or rename state, it's a major.

---

## Hotfix process

If a production-affecting bug surfaces:

1. Reproduce on `main` and write a failing test (or update an existing
   smoke to catch it).
2. Fix and verify the test passes.
3. Bump patch version, follow Phase 2-5 above.
4. If the bug affects already-released versions in adopter projects,
   write a dated `UPDATE_YYYY-MM-DD_fix.md` describing the patch and
   how to apply it without re-installing.

---

## Yanking a release

If a release ships with a critical bug that can't be hotfixed quickly,
add a banner to `CHANGELOG.md`:

```markdown
## [X.Y.Z] - YYYY-MM-DD — **YANKED**

> Do not use this version. <reason>. Use vX.Y.(Z+1) or roll back to
> vX.Y.(Z-1).
```

Do not delete the git tag (would break links). Mark the GitHub release
as a draft / pre-release.

---

## Recovery: what if the maintainer is unavailable

The project should be recoverable by any contributor with repo access:

- `MAINTAINERS.md` (create if missing) lists current maintainers + GH
  handles.
- `CONTRIBUTING.md` documents the build/test/release path so an
  outside contributor can produce a release candidate without secret
  knowledge.
- All secrets (Codex API keys, OpenSSF tokens) live outside the repo;
  release process does not require them.

---

## Release cadence

There isn't a fixed cadence. Cut a release whenever:

- A behavior-affecting bugfix lands (within days)
- A new feature is ready and tested (within a week)
- It's been 4+ weeks since the last release and there are
  uncommitted-but-merged changes worth tagging

Don't release for trivial doc-only changes.

---

_Last updated: 2026-05-18 for v2.0._
