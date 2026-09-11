# Installer internals

**English** · [Español](installer-internals.md) · [← Back to README](../README.en.md) ·
[Architecture](architecture.en.md) · [Model contract](model-contract.en.md) ·
[Testing](testing.en.md)

`install.sh` is the canonical project installer. It configures the system
locally:

- **Environment:** discovers `deno`/`agy`, initializes
  `~/.config/agy-bridge/env` from [`.env.example`](../.env.example).
- **Agents:** copies `raw`, `worker-ro`, and `worker-rw` profiles into
  `~/.gemini/config/agents/`. On upgrades, it automatically migrates only the
  canonical legacy `raw/agent.md` that still prohibited all tool use; any
  customized `raw` agent is preserved unless `--force` is used.
- **Provider + plugin + models:** registers `agy-bridge`
  (`baseURL: "http://127.0.0.1:7421/v1"`), installs
  `~/.config/opencode/plugins/agy-bridge.ts`, and live-synchronizes dynamic
  `auto-ro/rw-*` models through `scripts/sync-models.ts` using three-level
  resolution: `agy models` TSV → `GET /v1/models` → grouped fallback.

```sh
./install.sh                 # provider + plugin + model sync (manual auth via /connect)
./install.sh --with-auth     # also configures auth.json automatically
```

Available flags:

- `--force`: overwrite existing agent configs in `~/.gemini/config/agents/`.
- `--with-auth`: upsert `AGY_TOKEN` from `~/.config/agy-bridge/env` into
  `~/.local/share/opencode/auth.json` as
  `{"agy-bridge":{"type":"api","key":"..."}}`, preserving other keys,
  applying `chmod 600`, and remaining idempotent. Without it, auth is manual
  through `/connect`.

## Option A: Remote one-liner

Downloads the repository safely and delegates to the canonical installer:

```sh
# Standard installation (manual auth via /connect)
curl -fsSL https://raw.githubusercontent.com/AlvaroTapia-f/agy-bridge/main/install-remote.sh | bash

# Recommended on a clean machine: configure auth.json automatically
curl -fsSL https://raw.githubusercontent.com/AlvaroTapia-f/agy-bridge/main/install-remote.sh | bash -s -- --with-auth
```

You can audit the remote script first:

```sh
curl -fsSL https://raw.githubusercontent.com/AlvaroTapia-f/agy-bridge/main/install-remote.sh | less
```

The script does **not** require or use `sudo`, does not store or print literal
tokens, downloads/clones into `AGY_BRIDGE_DIR` (default
`~/.local/share/agy-bridge` or `$XDG_DATA_HOME/agy-bridge`), then `exec`s the
canonical installer.

Configurable environment variables:

- `AGY_BRIDGE_DIR`: destination directory.
- `AGY_BRIDGE_REF`: branch, tag, or commit to install (default `main`).

## Option C: Manual installation

If you do not use systemd or prefer manual setup, reproduce what `install.sh`
does:

1. **Environment configuration**

   ```sh
   mkdir -p ~/.config/agy-bridge
   cp .env.example ~/.config/agy-bridge/env
   # Edit ~/.config/agy-bridge/env with AGY_TOKEN and binary paths
   chmod 600 ~/.config/agy-bridge/env
   ```

2. **Copy agents**

   ```sh
   mkdir -p ~/.gemini/config/agents
   cp -r agents/* ~/.gemini/config/agents/
   ```

   If upgrading from an older install with a customized `raw/agent.md`, apply
   the documented `view_file` exception manually; the installer preserves
   customized agents unless `--force` is used.

3. **Install the self-contained opencode plugin**

   ```sh
   mkdir -p ~/.config/opencode/plugins
   cp plugins/agy-bridge.ts ~/.config/opencode/plugins/agy-bridge.ts
   ```

   `plugins/agy-bridge.ts` is generated with `deno task bundle:plugin` from
   `plugins/agy-bridge.plugin.ts`, inlining `plugins/agy-bridge-helpers.ts`.

4. **Register provider and models in global `opencode.json`**

   Add `provider.agy-bridge` using `npm: "@ai-sdk/openai-compatible"` and
   `options.baseURL: "http://127.0.0.1:7421/v1"`, plus the plugin path. Models
   are generated from `GET /v1/models` by grouping effort suffixes. Do not
   expose bare `gemini-*`/`claude-*` ids in the provider.

5. **Configure auth**

   - Automatic: read `AGY_TOKEN` from the bridge env file and upsert the
     `agy-bridge` key in `auth.json`, preserving other keys and `chmod 600`.
   - Manual: `opencode` → `/connect` → `Other` → `agy-bridge` → paste
     `AGY_TOKEN`. Environment-based `apiKey: "{env:AGY_TOKEN}"` also works when
     the variable is sourced before launching opencode.

6. **Run the service**

   With user systemd:

   ```sh
   mkdir -p ~/.config/systemd/user
   sed -e "s|\${DENO_BIN}|$(which deno)|g" \
       -e "s|\${AGY_BIN}|$(which agy)|g" \
       -e "s|\${INSTALL_DIR}|$(pwd)|g" \
       agy-bridge.service.template > ~/.config/systemd/user/agy-bridge.service
   systemctl --user daemon-reload
   systemctl --user enable --now agy-bridge
   ```

   Directly in a terminal without systemd:

   ```sh
   set -a; source ~/.config/agy-bridge/env; set +a
   $DENO_BIN run --allow-net=127.0.0.1 --allow-run=$AGY_BIN \
     --allow-read=$HOME/.gemini/antigravity-cli/brain,$HOME/.local/state/agy-bridge \
     --allow-write=$HOME/.local/state/agy-bridge --allow-env \
     --unstable-no-legacy-abort agy-bridge.ts
   ```

Read permission on `~/.local/state/agy-bridge` is required because bare
requests use `$STATE_DIR/work/req-*` as child `cwd`; read access to
`~/.gemini/antigravity-cli/brain` preserves transcript salvage. Broad `$HOME`
read permission is unnecessary.

## OpenCode provider (global)

The bridge is exposed as global provider `agy-bridge` in
`~/.config/opencode/opencode.json`:

```json
{
  "provider": {
    "agy-bridge": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "AGY Bridge",
      "options": { "baseURL": "http://127.0.0.1:7421/v1" }
    }
  },
  "plugin": ["file:///home/<user>/.config/opencode/plugins/agy-bridge.ts"]
}
```

- `baseURL` **must** end in `/v1`; the SDK appends `/chat/completions`.
- Host guard allows only `127.0.0.1:*` or `localhost:*`; `Host: evil.com`
  returns 403.
- For effort suffix grouping and variant selection, see
  [Model contract](model-contract.en.md). Never expose bare model ids through
  the provider.

## Model synchronization

`deno task sync:models` runs `scripts/sync-models.ts`. Every install/update
synchronizes the live `agy models` catalog into global `opencode.json` without
duplicating configuration or touching other providers.

```sh
# Standard synchronization
deno task sync:models

# Preview without writing
deno task sync:models --dry-run

# Custom config path or agy binary
deno run --allow-run=agy --allow-net=127.0.0.1:7421 --allow-read --allow-write --allow-env scripts/sync-models.ts --config-path /custom/opencode.json
```

Three resolution levels:

1. live `agy models` TSV;
2. bridge `GET /v1/models`;
3. grouped fallback catalog (7 bases → 14 `auto-ro/rw-*` ids, live-verified
   2026-09-07).

New Antigravity models or efforts such as `high`, `medium`, `low`, `thinking`,
or `ultra` are inferred dynamically under `auto-ro-<base>` / `auto-rw-<base>`
with `variants.<effort>.reasoningEffort`.

## gentle-ai TUI effort patch

The `agy-bridge` provider publishes a flat model shape: `reasoning: true` plus
`variants.*.reasoningEffort`, with no `capabilities` object. The
`@ai-sdk/openai-compatible` layer used by opencode can enrich that model while
leaving `capabilities.reasoning` false or absent in the TUI-visible provider
state. Without a compatibility patch, `/sdd-model` can therefore claim the
model does not expose effort options even though `/variant` works.

`install.sh` section **#7** patches the cached gentle-ai TUI idempotently when
needed:

```text
~/.cache/opencode/packages/opencode-sdd-engram-manage@latest/dist/tui.js
  → listReasoningEffortsFromModel(modelDef)
```

Conceptually, the guard changes from requiring
`capabilities.reasoning === true` to also accepting actual
`variants.*.reasoningEffort` entries. Singletons without variants remain
unsupported.

The patch is idempotent, does not touch `agy-bridge.ts` or systemd, and is
reapplied only by `./install.sh`. If opencode refreshes its cache, rerun the
installer. If gentle-ai fixes the behavior upstream, the old pattern no longer
matches and the installer warns rather than breaking the file.

## Auth without repository secrets

Recommended on a new machine:

```sh
./install.sh --with-auth
```

Manual alternative:

```json
{ "agy-bridge": { "type": "api", "key": "<AGY_TOKEN>" } }
```

Keep `auth.json` and the bridge env file at `chmod 600`. Never commit the token.

## Verification

Post-install checklist:

```sh
# 1. Bridge alive and auth OK
source ~/.config/agy-bridge/env
curl -s -H "Authorization: Bearer $AGY_TOKEN" http://127.0.0.1:7421/v1/models | head
curl -s http://127.0.0.1:7421/healthz

# 2. Host guard -> 403
curl -s -H "Host: evil.com" -H "Authorization: Bearer $AGY_TOKEN" http://127.0.0.1:7421/v1/models -w " %{http_code}\n"

# 3. No auth -> 401
curl -s http://127.0.0.1:7421/v1/models -w " %{http_code}\n"

# 4. Provider visible without bare ids
opencode models | grep agy-bridge

# 5. Variant -> wire id
curl -s http://127.0.0.1:7421/v1/chat/completions -H "content-type: application/json" \
  -H "Authorization: Bearer $AGY_TOKEN" \
  -d '{"model":"auto-ro-gemini-3.7-flash-high","messages":[{"role":"user","content":"ping"}]}' | jq .choices[0].message.content
```

For the bare/multimodal path, pick a bare id actually returned by
`GET /v1/models` and run an official-CLI smoke test with a small supported data
URI such as `data:text/plain;base64,...`. The automated suite uses a hermetic
mock and does not replace real `view_file` integration verification.

## Rollback

```sh
# Remove provider and plugin entry from ~/.config/opencode/opencode.json
# Remove the agy-bridge key from ~/.local/share/opencode/auth.json
# Restart opencode and verify the provider is gone
```

Isolation changes only affect bare-request `cwd` and the minimum Deno
permissions required by that path. Loopback `baseURL`, `accessGuard` (Host 403,
Bearer 401), and `auto-*` semantics remain unchanged.
