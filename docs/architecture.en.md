# Architecture

**English** · [Español](architecture.md) · [← Back to README](../README.en.md) ·
[Model contract](model-contract.en.md) · [Installer internals](installer-internals.en.md) ·
[Testing](testing.en.md)

Local **OpenAI-compatible** bridge that exposes models from a Google Antigravity
subscription to any client, especially opencode. One rule is non-negotiable:
**all traffic to Google is performed by the official `agy` binary (Antigravity
CLI) in headless mode using its own authentication**.

```text
opencode ──(OpenAI API)──▶ agy-bridge :7421 ──(spawn+stdin NDJSON)──▶ agy --agent raw …
                                                              │
                                                     cloudcode-pa.googleapis.com
                                              (CLI-owned auth, unchanged)
```

Prompts travel over **stdin** as NDJSON `stream-json` protocol events rather
than through `-p`: opencode system prompts can exceed Linux's 128 KiB per-arg
limit (`E2BIG` / "Argument list too long"). This path was verified with payloads
around 190 KB.

## Anti-ban invariants

1. **Official binary only.** The bridge never reads/copies tokens, performs its
   own OAuth flow, talks to Google endpoints directly, or spoofs fingerprints.
2. **One account, one call at a time** (`MAX_CONCURRENT=1`): requests are queued
   and serialized.
3. **Three agents by cost/risk:**
   - **`raw` — expensive escape hatch** (~40k tokens per `tool_call`; each
     opencode tool turn creates a new agy session). Its only allowed native tool
     is `view_file`, and policy restricts it to bridge-generated
     `attachment-NNN.*` files inside the isolated request workspace. OpenAI tool
     calls remain a textual protocol controlled by opencode. Kept for
     compatibility and the bare API path; not recommended for long agentic
     tasks. `tools: []` falls back to "all", and `wait_5_seconds` breaks init.
   - **`worker-ro` — autonomous read-only** (one session per task, no tool
     round-trip reinjection).
   - **`worker-rw` — autonomous read/write** (can create/modify files; never
     `commit`/`push` without an explicit request). `sed_file`, `command_status`,
     `send_command_input`, and `wait_5_seconds` break init when allowlisted.
4. **Keep `agy` updated**; old versions are rejected server-side.
5. Never expose this service outside localhost or add account rotation.

## Sessions and tokens

- **Autonomous mode (`auto-ro/rw`, recommended): 1 task = 1 request = 1 agy
  session.** The model completes the whole task in its internal loop and returns
  one completion. Measured overhead is ~7.4k tokens (`ro`) / ~9.8k (`rw`), about
  75/80% lower than stateless mode for multi-tool tasks because system prompts,
  schemas, and history are not resent for every tool call.
- **`raw`/bare mode (escape hatch, not exposed in the provider): stateless per
  turn by default.** Each opencode tool call creates a new agy session. A
  three-step task is roughly four sessions. A typical `raw` turn (~40k input)
  consists of ~25k opencode system text, ~12k tool schemas (~9k with
  `AGY_TOOL_SCHEMA=slim`), ~5.5k agy harness, plus history. The bare API path is
  also used for direct text and isolated data-URI attachments.
- **Actual cost levers:** (1) prompt/skill size, (2) `auto-ro/rw` to collapse N
  turns into one agy session, and (3) `AGY_TOOL_SCHEMA=slim` for `raw` only.
  `AGY_REUSE=on` does not save tokens in `raw` and is irrelevant to `auto-*`.

## Per-request isolation and attachments

Bare ids create a fresh empty directory under `$STATE_DIR/work/req-<random>/`
before prompt rendering. The official `agy` child starts with that directory as
its `cwd`; after buffered completion, SSE completion, error, or disconnect, the
bridge removes the workspace with retries for transient deletion failures.

`messages[].content` may contain `text` and `image_url` parts. For `image_url`,
the bridge accepts only allowlisted `data:<mime>;base64,...` URIs, validates
limits on decoded bytes before materialization, creates generated
`attachment-NNN.ext` names, and adds a prompt marker containing MIME and SHA-256.
Caller filenames are never trusted, and `http://`/`https://` attachments are
never downloaded.

`auto-ro-*`/`auto-rw-*` keep their inherited `cwd` because they are agentic and
deliberately operate on local files; therefore they remain text-only in this
change.

This isolation reduces **accidental** checkout/working-directory exposure, but
it is not an OS sandbox. The `agy` subprocess runs as the same user, and the
raw-agent `view_file` restriction is agent policy rather than an operating
system boundary against a compromised process or adversarial prompt. Do not
expose the bridge to untrusted callers; loopback binding and Bearer auth remain
part of the security boundary.

## Autonomous delegation (`auto-*` models)

`auto-<profile>-*` models run an autonomous agy agent that completes the task
with its native tool loop and returns one completion.

```text
stateless: opencode ──n turns──▶ bridge ──n sessions──▶ agy raw       (context sent n times)
auto-ro:   opencode ──1 request─▶ bridge ──1 session──▶ agy worker-ro (context sent once)
```

- **Profile** = agent with its own allowlist (`~/.gemini/config/agents/`):
  - `ro` → `worker-ro`: `view_file`, `list_dir`, `grep_search`, `find_by_name`,
    `read_url_content`, `search_web` (~7.4k harness).
  - `rw` → `worker-rw`: `ro` plus `write_to_file`, `replace_file_content`,
    `multi_replace_file_content`, `run_command` (~9.8k harness). Never commits
    or pushes without an explicit request.
- **Engine** = any model suffix (`auto-ro-<model>` / `auto-rw-<model>`). The
  provider generates the matrix dynamically from `GET /v1/models` (or the
  fallback 7 bases × 2 = 14 ids, live-verified 2026-09-07) and the bridge
  validates it through `parseAutoModel`. Stateless bare ids are removed from
  the provider but remain available through the direct API escape hatch.
- **Incremental streaming uses a narration classifier:** `NOTE:` is routed to
  `reasoning_content`, final output to `content`, with SSE `: keepalive` every
  10 seconds during internal tool execution. `delta_chars` is logged.

## Tool protocol

In `raw`, the bridge renders opencode tools as a textual
`<tool_call>`/`<tool_result>` protocol and converts replies back into OpenAI
`tool_calls`; opencode controls execution. `AGY_TOOLS=off` degrades this
protocol to plain text. The raw agent's native `view_file` exception is
separate and is only for bridge-generated attachments. In `auto-ro/rw`, the
textual OpenAI tool protocol is not involved because the agent executes its
native internal loop.

## Quota usage

- Append-only log: `~/.local/state/agy-bridge/usage.jsonl` (`ts`, model,
  duration, tokens, status per request).
- Autonomous-task overhead: ~7.4k (`ro`) / ~9.8k (`rw`); ~5.5k in `raw`.
