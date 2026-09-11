# OpenAI Multimodal Isolation Design

**Date:** 2026-09-11

## Goal

Extend `agy-bridge` into a safer general-purpose OpenAI-compatible local gateway while preserving the upstream strengths: official `agy` binary only, real `stream-json` streaming, OpenAI-style tool calls, model discovery, bearer auth, and localhost-only exposure.

The change combines three ideas:

1. Keep the existing `agy-bridge` stream/tool core.
2. Reimplement the request-isolation pattern proven by `tphakala/agy-openai-shim`: each normal OpenAI chat request gets a fresh empty working directory and cleanup is guaranteed.
3. Reimplement the useful data-URI file staging from `truongqv12/agy2api`, but with strict validation, byte limits, and no arbitrary remote downloads.

## Non-goals

- No direct calls to Google/Cloud Code Assist endpoints.
- No OAuth/token extraction or copying.
- No account rotation or multi-account pooling.
- No `/v1/responses` endpoint in this change.
- No image-generation, TTS, STT, or CapCut integrations.
- No server-side fetching of arbitrary `http://` or `https://` attachment URLs.
- No `--dangerously-skip-permissions` default.

## Existing behavior that must remain

- `POST /v1/chat/completions` supports buffered and SSE responses.
- `GET /v1/models` remains dynamic from `agy models`.
- OpenAI tool definitions and tool-result turns keep their current behavior.
- `auto-ro-*` / `auto-rw-*` model routing remains intact.
- `AGY_REUSE`, usage logging, hard deadline handling, salvage, host guard, and bearer auth remain intact.
- All traffic to Google is still performed by the official `agy` process using its own authentication.

## Architecture

### 1. Request workspace

Add a small `request-workspace.ts` module. A workspace lives under:

`$STATE_DIR/work/req-<random>/`

For ordinary/bare model requests, the bridge creates one workspace before rendering the prompt, launches `agy` with that directory as the child `cwd`, and removes the directory after the request completes or the SSE stream closes.

This prevents the model's built-in filesystem tools from accidentally seeing the bridge checkout or unrelated current-directory files. It also gives attachments a deterministic, per-request location.

`auto-ro-*` and `auto-rw-*` keep the existing inherited working-directory behavior because those routes are explicitly agentic and are intended to operate on local files. Multimodal data-URI attachments are therefore supported only on bare model IDs in this change; auto routes return a clear 400 for non-text content instead of silently changing workspace semantics.

### 2. Multimodal/data-URI attachments

Extend the accepted chat message content parts from text-only arrays to:

- `{ "type": "text", "text": "..." }`
- `{ "type": "image_url", "image_url": { "url": "data:<mime>;base64,..." } }`

Despite the historical `image_url` name, the bridge may stage a small safe set of document MIME types as files because some OpenAI-compatible clients reuse this field for PDFs/documents.

Supported MIME types initially:

- `image/png` -> `.png`
- `image/jpeg` -> `.jpg`
- `image/webp` -> `.webp`
- `image/gif` -> `.gif`
- `application/pdf` -> `.pdf`
- `text/plain` -> `.txt`
- `text/csv` -> `.csv`
- `application/msword` -> `.doc`
- `application/vnd.openxmlformats-officedocument.wordprocessingml.document` -> `.docx`

Each staged file gets a generated name such as `attachment-001.png`. The transformed message text contains an explicit attachment marker with the relative filename and MIME type, instructing the agent to inspect the file with its built-in file/view capability when relevant.

The bridge never fetches remote URLs. `http://` and `https://` values return 400 with guidance to send a `data:` URI. Unknown content-part types or malformed data URIs also return 400.

### 3. Attachment limits

Defaults:

- `AGY_MAX_ATTACHMENT_BYTES=20971520` (20 MiB per attachment)
- `AGY_MAX_REQUEST_ATTACHMENT_BYTES=67108864` (64 MiB total per request)

If a decoded attachment exceeds either limit, return HTTP 413 in the normal OpenAI error envelope. Limits are checked before writing the decoded bytes to disk.

### 4. `agy` invocation

Keep the existing protocol:

`agy --agent ... --model ... --input-format stream-json --output-format stream-json --print-timeout ...`

For isolated bare-model requests only, set the child process `cwd` to the request workspace. No Google endpoint is contacted by bridge code and no auth material is read by the new code.

The prompt still travels through stdin NDJSON, so large textual prompts retain the current protection from Linux argv-size limits.

### 5. Lifecycle and cleanup

Buffered request:

1. Create workspace.
2. Materialize/normalize message content.
3. Run `agy` in that workspace.
4. Build OpenAI response.
5. Remove workspace in `finally`.

Streaming request:

1. Create workspace before constructing the SSE stream.
2. Materialize/normalize message content.
3. Run `agy` in that workspace while forwarding deltas.
4. Send `[DONE]` / close.
5. Remove workspace in the stream's `finally` block, including disconnect/error cases.

No staged file survives a completed request.

## Error contract

Use the existing JSON error envelope:

```json
{
  "error": {
    "message": "...",
    "type": "agy_bridge_error",
    "code": 400
  }
}
```

New cases:

- 400: malformed data URI.
- 400: unsupported MIME type.
- 400: remote attachment URL.
- 400: unsupported content-part type.
- 400: multimodal content on an `auto-*` route.
- 413: per-file or per-request decoded-byte limit exceeded.
- 500: workspace/materialization failure that is not caused by caller input.

## Security constraints

- Keep localhost binding and Host-header/DNS-rebind guard.
- Keep bearer auth support.
- Do not add network fetches for attachments.
- Do not add `--dangerously-skip-permissions`.
- Filenames are generated by the bridge; caller-supplied filenames are never used as filesystem paths.
- Temporary files use the existing Deno process's scoped state-directory permissions.
- The systemd unit gains read permission to the bridge state directory because the child workspace becomes the active `cwd`; it does not gain broader `$HOME` read access.

## Testing

Use the existing hermetic service harness with a mock `agy` executable.

Required regression tests:

1. Bare text request runs with an isolated child `cwd` under `$STATE_DIR/work` and that directory is deleted after completion.
2. Data-URI image content is staged as a generated file, mentioned in the NDJSON prompt, visible to the mock child, and cleaned afterward.
3. Text and attachment parts preserve their relative order in the rendered user message.
4. Remote URLs return 400 and do not invoke `agy`.
5. Unsupported MIME/content-part types return 400.
6. Per-file limit returns 413.
7. Total request limit returns 413.
8. Existing buffered chat, SSE, tools, models, auth, host guard, deadline, salvage, and variant tests stay green.

## Source attribution

The fork remains MIT licensed. The isolation/file-staging behavior is reimplemented in TypeScript rather than copied verbatim, while documentation credits the ideas from:

- `tphakala/agy-openai-shim` (MIT) for per-call empty-workspace isolation and disciplined cleanup.
- `truongqv12/agy2api` (MIT) for OpenAI-content data-URI staging into temporary files.

The upstream `AlvaroTapia-f/agy-bridge` remains the primary codebase and source of the streaming/tool implementation.
