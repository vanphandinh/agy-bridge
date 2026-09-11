# Model contract

**English** · [Español](model-contract.md) · [← Back to README](../README.en.md) ·
[Architecture](architecture.en.md) · [Installer internals](installer-internals.en.md) ·
[Testing](testing.en.md)

## Flat shape (no `capabilities`)

The `agy-bridge` provider publishes each model in a flat shape:
`reasoning: true` at the model level plus `variants.*.reasoningEffort`, with
**no `capabilities` object**. This is verified through
`cat ~/.config/opencode/opencode.json | jq` and the test suite.

However, the `@ai-sdk/openai-compatible` SDK used by opencode enriches the
model and may leave `capabilities.reasoning` false or absent in the
TUI-visible `api.state.provider`. This is why the TUI compatibility patch
exists; see [installer internals](installer-internals.en.md#gentle-ai-tui-effort-patch).

## Effort variants

The plugin (`agy-bridge.ts` + `agy-bridge-helpers.ts`) groups catalog suffixes
`{-high,-medium,-low,-thinking}` into a base `auto-ro/rw-<base>` entry with
`variants` (for example, `auto-ro-gemini-3.7-flash` →
`high`/`medium`/`low`).

There is no client-side rewrite. The fetch wrapper around
`7421/v1/chat/completions` and the `chat.message` hook were removed. Every
entry path (TUI, direct API, subagent, SDD provider) sends the id verbatim and
the bridge validates it through fail-closed `resolveWireModel`: it resolves
only to a declared `<base>-<effort>` slug.

The bridge accepts variant selection from all supported POST-body signals and
passes them to the same consensus logic: (1) flat `reasoning_effort`, (2)
nested `reasoning.effort`, (3) `variant`, and (4) an effort suffix already
present in the wire-model slug. If all present signals agree, the suffixed slug
is selected. Conflicts, multi-effort bare models without a signal, and unknown
slugs return 400 with the available suffixed slugs; there are no silent
defaults. opencode's `default` value is treated as an absent signal.

Wire pin: opencode **1.18.29** maps a `/variant` choice to the flat
`reasoning_effort` POST key (live-captured 2026-09-09). `thinking` does not
exist in opencode's `reasoningEffort` enum (`none…max`), so the map advertises
it as `reasoningEffort: "max"`; the bridge applies the bounded reverse alias
`max → thinking` only when `thinking` is actually declared for that base.

## Map version and cache

`MODEL_MAP_VERSION = 4` in `plugins/agy-bridge-helpers.ts` invalidates
downstream variant caches. `install.sh` removes the `agy-bridge` row from
`~/.gentle-ai/cache/model-variants.json`, and `scripts/sync-models.ts` stamps
the version into its result. The generated bundle preserves the masked map
byte-for-byte, verified by hash in `plugins/agy-bridge.bundle.test.ts`.

## Effort masking contract (model map v4)

Every reasoning model pre-populates the full generic effort set so runtime
merging cannot introduce unmasked entries:

- `GENERIC_EFFORTS = ["high", "medium", "low"]` in
  `plugins/agy-bridge-helpers.ts`. `thinking` is agy-specific and is never
  injected by runtime merging, so it is not part of the generic set.
- Declared efforts remain enabled as `{reasoningEffort}`. `thinking` is
  advertised as `reasoningEffort: "max"`, and the bridge maps `max → thinking`
  back only when declared for that base.
- Generic-but-undeclared efforts are emitted as exactly `{disabled: true}` with
  no `reasoningEffort` next to it.
- Each reasoning model also carries
  `reasoning_options: [...declared].sort()`, the machine-readable declaration
  used by the downstream filter. Singletons without variants are untouched:
  no masking and no `reasoning_options`.

Example — `auto-ro-gemini-3.1-pro` declares only `high`/`low`:

```json
{
  "high": { "reasoningEffort": "high" },
  "low": { "reasoningEffort": "low" },
  "medium": { "disabled": true },
  "reasoning_options": ["high", "low"]
}
```

Downstream, the global
`~/.config/opencode/plugins/model-variants.ts` cache writer (patched by
`install.sh`, marker `agy-bridge-mask-v1`) drops every `{disabled: true}`
entry, intersects remaining entries with `reasoning_options` when present, and
skips the row if nothing remains. This is fail-closed: offering no effort is
better than offering the wrong effort. The TUI therefore shows only declared
efforts, every offered selection resolves with 200, and `resolveWireModel`
continues to return 400 for truly unknown variants.

## Catalog snapshot and id rule

- Current grouped fallback, live-verified against `GET /v1/models` on
  2026-09-07 after upstream removal of `gemini-3.5-flash`: **7 bases × 2
  profiles = 14 ids** with variants.
- Any new Antigravity model or reasoning effort such as `high`, `medium`,
  `low`, `thinking`, or `ultra` is inferred and grouped dynamically under
  `auto-ro-<base>` / `auto-rw-<base>` with
  `variants.<effort>.reasoningEffort`.
- **Never expose bare `gemini-*`/`claude-*` ids in the provider.** Stateless
  bare ids were removed from provider discovery; the bridge keeps the
  `raw`/bare path as a direct-API escape hatch.
