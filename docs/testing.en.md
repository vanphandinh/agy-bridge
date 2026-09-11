# Testing

**English** · [Español](testing.md) · [← Back to README](../README.en.md) ·
[Architecture](architecture.en.md) · [Model contract](model-contract.en.md) ·
[Installer internals](installer-internals.en.md)

## Suite

Run the current suite with:

```sh
deno task test
```

The pass count changes as regressions are added, so run the command before
citing a concrete number.

Coverage includes the Host guard (403), Bearer auth (401), routing and 400
errors, SSE streaming, deadline kill (502), transcript salvage, session retry,
harness hermeticity with `usage.jsonl` under a temporary `STATE_DIR`,
three-level model resolution (`scripts/sync-models.ts`), and fallback models.

For bare/multimodal behavior, the suite also verifies: isolated per-request
workspace, child `cwd`, data-URI staging with generated names and SHA-256,
text/attachment ordering, rejection of remote URLs and unsupported MIME/content
parts, 413 file/request limits, cleanup across buffered/SSE/disconnect paths,
safe raw-agent migration, `AGY_REUSE` with attachments, and
abort/deadline/stdin/concurrency regressions that could otherwise remove a
workspace while `agy` is still running.

Service tests use a hermetic mock `agy`. After installing on a real machine,
also run a smoke test with the official CLI to confirm actual `view_file`
behavior for the file types you plan to use.

For the standard post-install smoke test (live bridge, variant → wire id), see
[Verification](installer-internals.en.md#verification), step 5 (`POST auto-ro-*`).

## Diagnostics

```sh
systemctl --user status agy-bridge
journalctl --user -u agy-bridge -f
tail ~/.local/state/agy-bridge/usage.jsonl
# Smoke test: see Verification step 5 (POST auto-ro-*)
```

If `agy` changes flags/events in `stream-json` or changes `view_file` behavior,
the bridge can break while the hermetic mock suite remains green. Check
`agy --help`, run the real smoke test, adjust integration as needed, and rerun
the suite.

## SDD

Development follows Spec-Driven Development under `openspec/`. The TUI patch
that keeps `/sdd-model` working with `agy-bridge` is documented under
[gentle-ai TUI effort patch](installer-internals.en.md#gentle-ai-tui-effort-patch).
