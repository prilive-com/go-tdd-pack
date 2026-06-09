# Codex models_cache.json fixture set

> Status: **load-bearing artifact for v2.3 task #138 slice 1**.
> See [`../../../docs/PROPOSAL-model-auto-select.md`](../../../docs/PROPOSAL-model-auto-select.md)
> §11 (addendum) for the BLOCKER + MAJOR findings these fixtures
> exist to close.

## What these are

Fixture caches that simulate every shape `~/.codex/models_cache.json`
can present to `runner/lib/resolve-model.sh`. Slice 1 uses them to
prove the resolver's fallback paths work. Slice 2 will use them to
prove the real cache reader picks the right slug and falls back
loudly on broken caches.

## Why fixtures

Empirical research (PROPOSAL §3.1, docs/RESEARCH-codex-sandbox-features.md)
captured ONE real cache shape from Codex CLI 0.129.0 on one host.
That is not enough evidence for a runner contract (Codex addendum
MAJOR M4). The fixtures here represent the schema space the
resolver MUST handle — including failure modes that have not been
observed on any single host but are valid per the JSON Schema
(or invalid in ways the resolver must catch).

## Each fixture

| File | Purpose | Resolver expectation |
|---|---|---|
| `valid-typical.json` | The default 0.129.0 shape. Five models, `gpt-5.5` highest priority (lowest number). | Slice 2: returns `gpt-5.5`. |
| `valid-role-filter-edge.json` | `codex-auto-review` planted at priority 1 (top of cache). Role-suitability filter must drop it before priority sort. | Slice 2: filters `codex-auto-review`, returns `gpt-5.5`. Closes BLOCKER 1's risk that a high-priority but role-inappropriate model wins. |
| `valid-hide-edge.json` | Top-priority model has `visibility: "hide"`. | Slice 2: skips hidden, returns next-priority `list`-visible. |
| `valid-api-only-edge.json` | Top model has `supported_in_api: false`. Under api_key auth, must skip. Under subscription auth, must return. | Slice 2: subscription → returns it; api_key → skips it. |
| `missing-priority.json` | Top model omits `priority`. | Slice 2: drops the entry (treat-as-unsortable), continues with the rest. |
| `string-priority.json` | `priority` is a string, not integer. | Slice 2: drops the entry. |
| `duplicate-priority.json` | Two entries share `priority: 9`. | Slice 2: deterministic tiebreaker (slug lexicographic, document choice). |
| `null-fields.json` | Optional fields (`display_name`, `description`) are `null`. | Slice 2: ignores nulls — resolver only depends on `slug`/`priority`/`visibility`. |
| `empty-models.json` | `"models": []` — valid JSON, empty list. | Slice 2: fallback with warning. |
| `not-json.txt` | Cache file present but not parseable as JSON. | Slice 2: fallback with warning. |
| `missing-required.json` | Missing top-level `client_version` or `fetched_at`. | Slice 2: fallback with warning. |

## What slice 1 actually tests

Slice 1's resolver is a STUB for the `auto` path. The fixtures are
**still validated** in slice 1 against
[`../../../schemas/codex-models-cache.schema.json`](../../../schemas/codex-models-cache.schema.json):

- `valid-*.json` fixtures MUST pass schema validation.
- `missing-priority.json`, `string-priority.json`,
  `missing-required.json`, `empty-models.json`, `not-json.txt`
  MUST fail schema validation in the documented way.

This locks the contract for slice 2 to consume. If slice 2 changes
the schema, the fixture diffs make the change visible.

## How to regenerate the typical fixture

The `valid-typical.json` fixture is a redacted copy of a real
captured cache. Regenerate after a Codex CLI minor-version bump:

```bash
# (on a host with the new Codex CLI version installed + authed)
cp ~/.codex/models_cache.json /tmp/captured-cache.json
# Redact host-specific fields, then commit:
jq '{client_version, fetched_at, models: [.models[] | {slug, display_name, description, default_reasoning_level, priority, visibility, supported_in_api}]}' \
  /tmp/captured-cache.json \
  > test/fixtures/codex-models-cache/valid-typical.json
```

Keep only the fields the resolver uses + a few descriptive ones.
Drop tenant-specific identifiers (etag, internal cache hashes, etc.).

## Slice 2 acceptance

Slice 2 ships when:

1. The real resolver correctly handles every fixture per the table
   above.
2. `test/smoke-resolve-model.sh` (extended in slice 2) covers
   every fixture as a separate test case.
3. `valid-typical.json` resolves to `gpt-5.5` (or whatever the
   current frontier slug is when the fixture is regenerated).
4. No fixture causes the resolver to return a slug NOT present in
   that fixture's `.models[].slug` set (no fabrication).
