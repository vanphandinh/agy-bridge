# agy-bridge

**English** · [Español](README.md)

Local **OpenAI-compatible** bridge that exposes the models from your Google
Antigravity subscription to any client (especially opencode).

Non-negotiable rule: **all traffic to Google is performed by the official
`agy` binary (Antigravity CLI) in headless mode, using its own
authentication**. The bridge never reads or copies tokens, does not implement
its own OAuth flow, and listens only on `127.0.0.1`.

Service constraints (do not break):

- **Official binary only**, with **one call at a time** (`MAX_CONCURRENT=1`).
- **Three agents by cost/risk:** `raw` (expensive escape hatch, not
  recommended), `worker-ro` (autonomous read-only), `worker-rw` (autonomous
  read/write; never `commit`/`push` without an explicit request).
- **Keep `agy` up to date** (old versions are rejected server-side), and never
  expose the service outside localhost.

> Developer/operator deep dive (diagram, complete invariants, sessions, tool
> protocol, streaming): [`docs/architecture.en.md`](docs/architecture.en.md).

## Requirements

| Requirement | Details |
|---|---|
| Google Antigravity subscription + installed and authenticated `agy` CLI | `agy --help` and `agy models` must work (the bridge only spawns `agy`; it does not log in for you) |
| `deno` (v2.9.5+) | **Strict prerequisite**, including model synchronization (`deno --version`; discovered through `PATH` and standard locations) |
| `opencode` (v1.18+) | If `~/.config/opencode/opencode.json` does not exist, the installer skips provider setup and prints a warning |
| Linux with `systemd --user` | Used by `agy-bridge.service`; without systemd you can run directly with `deno run` ([see internals](docs/installer-internals.en.md#option-c-manual-installation)) |
| `python3` | Only for base provider/auth configuration in `opencode.json` and the TUI patch |
| `openssl` or `xxd` + `/dev/urandom` | Used to generate the 24-byte `AGY_TOKEN` |
| Port `7421` free on `127.0.0.1` | Loopback bind; configurable with `PORT` in `~/.config/agy-bridge/env` |

`~/.config/agy-bridge/env` and `~/.local/share/opencode/auth.json` are set to
`chmod 600` automatically.

## Install in 3 steps

**1. Verify the [requirements](#requirements)**, especially authenticated `agy`
and `deno`.

**2. Run the installer** (does not require or use `sudo`; you can audit it
before running it — [details](docs/installer-internals.en.md#option-a-remote-one-liner)):

```sh
# Standard installation (manual auth through /connect; see step 3)
curl -fsSL https://raw.githubusercontent.com/AlvaroTapia-f/agy-bridge/main/install-remote.sh | bash

# Recommended on a clean machine: configures auth.json automatically
curl -fsSL https://raw.githubusercontent.com/AlvaroTapia-f/agy-bridge/main/install-remote.sh | bash -s -- --with-auth
```

**3. Verify that it works** (the installer has already registered the provider,
plugin, and models):

```sh
source ~/.config/agy-bridge/env
curl -s http://127.0.0.1:7421/healthz
curl -s -H "Authorization: Bearer $AGY_TOKEN" http://127.0.0.1:7421/v1/models | head -c 300
```

If the first command does not return `{"ok":true}`, see
[Troubleshooting](#troubleshooting). For the complete verification checklist
(auth, Host guard, variants), see
[`docs/installer-internals.en.md`](docs/installer-internals.en.md#verification).

## Daily use

- **Choose a model by profile:** `auto-ro-<base>` (read-only) or
  `auto-rw-<base>` (read/write) for agentic tasks over local files. For direct
  OpenAI-compatible API calls, bare `gemini-*`/`claude-*` ids run inside a
  fresh empty workspace isolated per request. `auto-*` routes keep their
  inherited `cwd` and remain text-only.
- **Effort variants:** each model exposes `variants`
  (`high`/`medium`/`low`/`thinking`); when no variant is selected, the order is
  `medium` → `high` → `low` → `thinking`.
- **Monitor quota usage:** append-only log at
  `~/.local/state/agy-bridge/usage.jsonl` (one JSON object per request: date,
  model, duration, tokens, status).
- Fallback catalog when Antigravity does not respond: 7 bases × 2 profiles =
  14 ids (live-verified on 2026-09-07). Resynchronize at any time with
  `deno task sync:models` ([how it works](docs/installer-internals.en.md#model-synchronization)).

### Multimodal on bare models

Bare models accept `messages[].content` either as text or as OpenAI `text` +
`image_url` parts. `image_url.url` must be a supported
`data:<mime>;base64,...` URI: the bridge decodes the file into
`$STATE_DIR/work/req-<random>/`, passes that directory as the official `agy`
process `cwd`, and removes it after the response finishes (including SSE).
The bridge **does not download `http://`/`https://` URLs** and rejects them with
HTTP 400.

Limits apply to decoded bytes: 20 MiB per file and 64 MiB per request by
default, configurable through `AGY_MAX_ATTACHMENT_BYTES` and
`AGY_MAX_REQUEST_ATTACHMENT_BYTES`. `auto-ro-*`/`auto-rw-*` routes remain
text-only to preserve their agentic semantics and working directory. All
Google access continues to happen only inside the official `agy` binary; the
bridge does not read OAuth credentials or call private Google endpoints.

The isolated `cwd` prevents accidental exposure of the checkout, but **it is
not an operating-system sandbox**: `agy` still runs as the same user. Tests use
a hermetic mock; after installation, verify `view_file` with the official CLI
and the file types you actually plan to use.

Model contract (flat shape, `reasoning: true`, no `capabilities`) and variant
matrix: [`docs/model-contract.en.md`](docs/model-contract.en.md).

## Updating

1. Update `agy` first (old versions are rejected server-side).
2. Re-run the installer (the same one-liner from
   [installation](#install-in-3-steps)) or run `./install.sh` from the repo;
   this re-synchronizes the live model catalog and reapplies the TUI patch when
   needed. The installer automatically migrates only the canonical legacy
   `raw/agent.md` so isolated attachments can be read. If you customized that
   agent, it is preserved: apply the `view_file` exception for
   `attachment-NNN.*` manually or use `--force` if you want to replace it.
3. Models only, without the full installer: `deno task sync:models`
   (`--dry-run` to preview changes without writing).

Canonical installer details, plugin bundle, and TUI patch:
[`docs/installer-internals.en.md`](docs/installer-internals.en.md).

## Uninstalling

1. In `~/.config/opencode/opencode.json`, remove `provider.agy-bridge` and the
   plugin entry.
2. In `~/.local/share/opencode/auth.json`, remove the `agy-bridge` key while
   preserving other keys, then keep the file at `chmod 600`.
3. Restart opencode and verify the provider no longer appears.
4. Optionally stop and disable the `agy-bridge` systemd user service.

Exact commands: [`docs/installer-internals.en.md`](docs/installer-internals.en.md#rollback).

## Troubleshooting

| Symptom | Short fix |
|---|---|
| `401` on `/v1/models` | Bearer token is missing: `opencode` → `/connect` → `Other` → `agy-bridge` → paste `AGY_TOKEN`, or re-run the installer with `--with-auth` |
| `403` with an unusual `Host` | The anti-DNS-rebinding guard rejected it; use `127.0.0.1` or `localhost` as the host |
| `404` on `/chat/completions` | Provider `baseURL` **must** end in `/v1` (the SDK appends `/chat/completions`) |
| `/sdd-model` says the model does not expose effort | The TUI cache is stale: re-run `./install.sh` to reapply the patch ([why](docs/installer-internals.en.md#gentle-ai-tui-effort-patch)) |
| Service is down or not responding | `systemctl --user status agy-bridge`, then `journalctl --user -u agy-bridge -f` ([diagnostics](docs/testing.en.md#diagnostics)) |
| Port is already in use | Change `PORT` in `~/.config/agy-bridge/env` |
| `agy` is rejected or behaves strangely | Update `agy`; if flags or `stream-json` changed, the parser may need to be adjusted ([note](docs/testing.en.md#diagnostics)) |
| Models are stale | `deno task sync:models` (or `--dry-run` to preview) |

Known limitations: `agy` process startup latency per turn (~2-7s); thinking
tokens are counted in usage but not displayed; tool calls are buffered during
streaming (no deltas); `temperature`/`max_tokens` are ignored (`agy` does not
expose them); `cwd` isolation is not an OS sandbox; and actual `view_file`
compatibility depends on the installed Antigravity CLI version.

## Essential configuration

Defaults from [`.env.example`](.env.example):

| Var | Default | Notes |
|---|---|---|
| `PORT` | `7421` | HTTP port |
| `AGY_BIN` | `agy` | Path to the `agy` binary |
| `DENO_BIN` | `deno` | Path to the `deno` binary |
| `AGY_AGENT` | `raw` | Default agent in `raw` mode (opencode uses `auto-*`) |
| `MAX_CONCURRENT` | `1` | Serializes `agy` calls |
| `PRINT_TIMEOUT` | `20m` | `20m` in `.env.example`/`install.sh`; bridge fallback is `15m` when unset |
| `AGY_TOOLS` | `on` | `off` disables the tool protocol in `raw` |
| `AGY_TOOL_SCHEMA` | `full` | `slim` uses fewer tokens in `raw` |
| `AGY_REUSE` | `off` | `on` continues `raw` conversations (does not apply to `auto-*`) |
| `AGY_MAX_ATTACHMENT_BYTES` | `20971520` | Maximum decoded bytes per attachment (20 MiB) |
| `AGY_MAX_REQUEST_ATTACHMENT_BYTES` | `67108864` | Maximum total decoded attachment bytes per request (64 MiB) |
| `AGY_TOKEN` | *required* | `Authorization: Bearer <AGY_TOKEN>` |

## For developers and operators

- [`docs/architecture.en.md`](docs/architecture.en.md) — diagram, stdin NDJSON
  (`E2BIG`/190 KB), complete invariants, sessions and tokens, bare isolation,
  attachments, autonomous delegation, tool protocol, and streaming.
- [`docs/model-contract.en.md`](docs/model-contract.en.md) — flat model contract
  (`reasoning: true`, no `capabilities`), variants and `reasoningEffort`,
  7-base/14-id snapshot (2026-09-07), and bare ids not exposed by the provider.
- [`docs/installer-internals.en.md`](docs/installer-internals.en.md) — canonical
  installer, step-by-step manual installation, plugin bundle
  (`deno task bundle:plugin`), three-level synchronization, TUI patch,
  secret-free repository auth, full verification, and rollback.
- [`docs/testing.en.md`](docs/testing.en.md) — current suite and coverage
  (`deno task test`), smoke tests, diagnostics, and SDD.
- [`docs/third-party-notices.md`](docs/third-party-notices.md) — attribution for
  the reimplemented per-request isolation and data-URI staging ideas.
