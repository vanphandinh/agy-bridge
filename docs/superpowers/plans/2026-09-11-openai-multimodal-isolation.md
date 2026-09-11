# OpenAI Multimodal Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-request isolated workspaces and safe OpenAI-style data-URI attachments to bare-model chat requests while preserving `agy-bridge` streaming, tools, models, auth, and auto-agent behavior.

**Architecture:** Keep `agy-bridge.ts` as the HTTP/streaming core, but extract request workspace and attachment normalization into `request-workspace.ts`. Bare-model requests create an isolated workspace and stage validated data-URI files there before rendering the prompt; `runAgy` receives an optional `cwd`. Auto-agent routes retain their current workspace semantics and reject multimodal content in this change.

**Tech Stack:** Deno 2.9.5+, TypeScript, native Deno filesystem/process APIs, existing `@std/assert` test dependency, official Antigravity `agy` CLI via `stream-json`.

**Spec:** `docs/superpowers/specs/2026-09-11-openai-multimodal-isolation-design.md`

## Global Constraints

- All traffic to Google must continue to be performed only by the official `agy` binary with its own authentication.
- Do not read/copy OAuth tokens or call Google endpoints directly.
- Keep localhost binding, Host-header guard, bearer auth, `MAX_CONCURRENT`, timeout/deadline behavior, usage logging, model discovery, tool calling, and `auto-ro-*` / `auto-rw-*` routes.
- Do not add `--dangerously-skip-permissions`.
- Do not fetch remote attachment URLs server-side.
- Default per-attachment decoded limit: 20 MiB (`20971520`).
- Default total decoded attachment limit per request: 64 MiB (`67108864`).
- Bare-model requests use isolated workspaces; auto-agent routes keep existing workspace semantics and reject non-text content.
- Use TDD: every production behavior must have a failing test observed before implementation.

---

### Task 1: Request workspace primitive

**Files:**
- Create: `request-workspace.ts`
- Create: `request-workspace.test.ts`

**Interfaces:**
- Produces: `createRequestWorkspace(stateDir: string): Promise<RequestWorkspace>`
- Produces: `RequestWorkspace.dir: string`
- Produces: `RequestWorkspace.writeAttachment(bytes: Uint8Array, extension: string): Promise<string>` returning an absolute path
- Produces: `RequestWorkspace.cleanup(): Promise<void>` idempotent

- [ ] **Step 1: Write failing tests**

Create `request-workspace.test.ts` with tests that assert:

```ts
import { assert, assertEquals, assertRejects } from "@std/assert";
import { createRequestWorkspace } from "./request-workspace.ts";

Deno.test("createRequestWorkspace creates a unique empty directory under state/work", async () => {
  const state = await Deno.makeTempDir();
  try {
    const ws = await createRequestWorkspace(state);
    try {
      assert(ws.dir.startsWith(`${state}/work/`));
      assertEquals([...Deno.readDirSync(ws.dir)].length, 0);
    } finally {
      await ws.cleanup();
    }
  } finally {
    await Deno.remove(state, { recursive: true });
  }
});

Deno.test("writeAttachment uses generated names and cleanup is idempotent", async () => {
  const state = await Deno.makeTempDir();
  const ws = await createRequestWorkspace(state);
  const path = await ws.writeAttachment(new TextEncoder().encode("hello"), ".txt");
  assert(path.startsWith(ws.dir));
  assertEquals(await Deno.readTextFile(path), "hello");
  await ws.cleanup();
  await ws.cleanup();
  await assertRejects(() => Deno.stat(ws.dir));
  await Deno.remove(state, { recursive: true });
});
```

- [ ] **Step 2: Run test and verify RED**

Run:

```bash
deno test --allow-read --allow-write --allow-env request-workspace.test.ts
```

Expected: FAIL because `request-workspace.ts` does not exist.

- [ ] **Step 3: Implement the minimal workspace module**

Implement `RequestWorkspace` with:

```ts
export interface RequestWorkspace {
  dir: string;
  writeAttachment(bytes: Uint8Array, extension: string): Promise<string>;
  cleanup(): Promise<void>;
}
```

Use `Deno.mkdir(`${stateDir}/work`, { recursive: true })`, `Deno.makeTempDir({ dir: workRoot, prefix: "req-" })`, generated sequential names `attachment-001<ext>`, mode `0o600`, and recursive cleanup guarded by an internal boolean.

- [ ] **Step 4: Run test and verify GREEN**

Run the same `deno test` command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add request-workspace.ts request-workspace.test.ts
git commit -m "feat: add isolated request workspaces"
```

### Task 2: Safe data-URI parser and attachment limits

**Files:**
- Modify: `request-workspace.ts`
- Modify: `request-workspace.test.ts`

**Interfaces:**
- Produces: `parseDataUri(url: string): ParsedDataUri`
- Produces: `mimeToExtension(mime: string): string | null`
- Produces: `stageDataUri(workspace, url, limits, runningTotal): Promise<StagedAttachment>`
- `StagedAttachment` includes `{ path, relativeName, mime, size, nextTotal }`

- [ ] **Step 1: Write failing parser/limit tests**

Add tests for:

```ts
const parsed = parseDataUri("data:image/png;base64,aGVsbG8=");
assertEquals(parsed.mime, "image/png");
assertEquals(new TextDecoder().decode(parsed.bytes), "hello");
```

Also assert malformed base64 throws `AttachmentInputError` with status 400, unsupported MIME throws 400, a 21 MiB decoded payload exceeds a 20 MiB per-file limit with status 413, and aggregate size over 64 MiB returns 413.

- [ ] **Step 2: Run targeted tests and verify RED**

```bash
deno test --allow-read --allow-write --allow-env request-workspace.test.ts
```

Expected: FAIL because parser/staging exports do not exist.

- [ ] **Step 3: Implement parser and allowlist**

Use an explicit MIME map:

```ts
const MIME_EXTENSIONS: Record<string, string> = {
  "image/png": ".png",
  "image/jpeg": ".jpg",
  "image/webp": ".webp",
  "image/gif": ".gif",
  "application/pdf": ".pdf",
  "text/plain": ".txt",
  "text/csv": ".csv",
  "application/msword": ".doc",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document": ".docx",
};
```

Accept only `data:<mime>;base64,<payload>`. Reject non-data URLs and invalid base64 with `AttachmentInputError(status, message)`. Validate decoded byte size before calling `writeAttachment`.

- [ ] **Step 4: Run tests and verify GREEN**

Same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add request-workspace.ts request-workspace.test.ts
git commit -m "feat: validate and stage data-uri attachments"
```

### Task 3: OpenAI message normalization with ordered attachments

**Files:**
- Create: `message-content.ts`
- Create: `message-content.test.ts`
- Modify: `agy-bridge.ts`

**Interfaces:**
- Produces: `normalizeMessageContent(content, workspace, limits): Promise<NormalizedMessageContent>`
- `NormalizedMessageContent.text: string`
- `NormalizedMessageContent.attachmentCount: number`
- `NormalizedMessageContent.totalAttachmentBytes: number`
- `agy-bridge.ts` message type accepts text and `image_url` content parts.

- [ ] **Step 1: Write failing normalization tests**

Create tests showing this input:

```ts
[
  { type: "text", text: "before" },
  { type: "image_url", image_url: { url: "data:image/png;base64,aGVsbG8=" } },
  { type: "text", text: "after" },
]
```

normalizes in the same order and includes a marker like:

```text
before
[Attachment: attachment-001.png; mime=image/png]
after
```

Also test remote `https://example.com/x.png` returns 400, unsupported part type returns 400, and multiple attachments increment names deterministically.

- [ ] **Step 2: Run tests and verify RED**

```bash
deno test --allow-read --allow-write --allow-env message-content.test.ts
```

Expected: FAIL because `message-content.ts` does not exist.

- [ ] **Step 3: Implement normalization**

Do not download URLs. For each `image_url` data URI, stage the bytes and insert the marker at that exact content-part position. Keep plain string content unchanged.

- [ ] **Step 4: Update bridge types only**

Replace the old loose `{ type?: string; text?: string }` part type with explicit text/image-url shapes while preserving backwards compatibility for string message content.

- [ ] **Step 5: Run tests and verify GREEN**

```bash
deno test --allow-read --allow-write --allow-env message-content.test.ts
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add message-content.ts message-content.test.ts agy-bridge.ts
git commit -m "feat: normalize OpenAI multimodal message content"
```

### Task 4: Bare-model chat integration and isolated `cwd`

**Files:**
- Modify: `agy-bridge.ts`
- Modify: `tests/service.test.ts`

**Interfaces:**
- `runAgy(..., cwd?: string)` launches `Deno.Command` with `cwd` for bare-model requests.
- `handleChat` creates and cleans an isolated workspace for bare-model requests.
- Auto routes reject non-text content with 400.

- [ ] **Step 1: Add failing service tests**

Extend `HarnessOptions` with attachment-limit env overrides if needed. Add mock scripts that record `pwd`, read the stdin event, inspect the referenced staged attachment, and return those observations in the completion text.

Required RED tests:

```ts
Deno.test("bare chat runs agy inside an isolated request workspace and removes it after completion", ...)
Deno.test("data-uri image is staged inside isolated cwd and referenced in prompt", ...)
Deno.test("auto route rejects multimodal content with 400 before invoking agy", ...)
Deno.test("remote image_url returns 400 before invoking agy", ...)
```

Use a mock counter file outside the request workspace to prove invalid requests never invoke `agy`.

- [ ] **Step 2: Run targeted service tests and verify RED**

```bash
deno test --allow-net --allow-run --allow-read --allow-write --allow-env tests/service.test.ts
```

Expected: new tests FAIL while existing tests remain runnable.

- [ ] **Step 3: Add attachment config**

In `agy-bridge.ts` read:

```ts
const MAX_ATTACHMENT_BYTES = Number(Deno.env.get("AGY_MAX_ATTACHMENT_BYTES") ?? 20 * 1024 * 1024);
const MAX_REQUEST_ATTACHMENT_BYTES = Number(Deno.env.get("AGY_MAX_REQUEST_ATTACHMENT_BYTES") ?? 64 * 1024 * 1024);
```

Reject non-finite or non-positive configured values at startup.

- [ ] **Step 4: Make prompt rendering async for bare routes**

Before `preparePrompt`, create a workspace and normalize every message's content into text. Render the existing transcript/tool protocol from that normalized request so the rest of the bridge logic stays unchanged.

Do not mutate the caller object in-place; build a shallow cloned request/messages array.

- [ ] **Step 5: Pass workspace `cwd` into `runAgy`**

Add `cwd?: string` as the final optional parameter and set it on `new Deno.Command(AGY_BIN, { cwd, ... })`. Auto routes call `runAgy` without `cwd`.

- [ ] **Step 6: Guarantee cleanup**

Buffered path: workspace cleanup in `finally` around all normal/continued retry paths.

Streaming path: transfer workspace ownership to the SSE stream and cleanup in the stream `finally` after `[DONE]`/close handling.

- [ ] **Step 7: Run targeted tests and verify GREEN**

```bash
deno test --allow-net --allow-run --allow-read --allow-write --allow-env tests/service.test.ts
```

Expected: all service tests PASS.

- [ ] **Step 8: Commit**

```bash
git add agy-bridge.ts tests/service.test.ts
git commit -m "feat: isolate bare chat requests and stage attachments"
```

### Task 5: Deno permissions, installer defaults, and attribution

**Files:**
- Modify: `.env.example`
- Modify: `agy-bridge.service.template`
- Modify: `README.md`
- Create: `docs/third-party-notices.md`
- Modify: tests that assert installer/service invariants if present

**Interfaces:**
- Service grants bridge read/write access only to `$STATE_DIR` plus existing transcript read scope.
- `.env.example` documents the two attachment limits.

- [ ] **Step 1: Write/extend failing invariant tests**

If the repository has service/install text assertions, add checks that the systemd unit allows read/write access to `%h/.local/state/agy-bridge` and does not add broad `$HOME` read access. If no suitable test file exists, add `tests/config.test.ts` that reads the template and `.env.example` as plain text.

- [ ] **Step 2: Run tests and verify RED**

```bash
deno test --allow-read tests/config.test.ts
```

Expected: FAIL until service/env changes are made.

- [ ] **Step 3: Update service permissions and env example**

Change systemd read permissions to include `%h/.local/state/agy-bridge` alongside the existing Antigravity transcript path. Add:

```text
AGY_MAX_ATTACHMENT_BYTES=20971520
AGY_MAX_REQUEST_ATTACHMENT_BYTES=67108864
```

- [ ] **Step 4: Document behavior and attribution**

README must state:

- bare model IDs are isolated per request;
- `image_url` accepts only supported base64 data URIs;
- remote URLs are rejected;
- auto-agent routes remain text-only for this change;
- limits and environment variables;
- official `agy` remains the only Google-facing process.

Create `docs/third-party-notices.md` crediting `tphakala/agy-openai-shim` (MIT) for the isolation design inspiration and `truongqv12/agy2api` (MIT) for data-URI staging inspiration, with repository URLs and a note that the TypeScript implementation in this fork is a clean reimplementation.

- [ ] **Step 5: Run tests and verify GREEN**

```bash
deno test --allow-read tests/config.test.ts
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add .env.example agy-bridge.service.template README.md docs/third-party-notices.md tests/config.test.ts
git commit -m "docs: configure multimodal isolation safely"
```

### Task 6: Full regression and compatibility verification

**Files:**
- Modify only if a failing regression reveals a defect directly caused by Tasks 1-5.

**Interfaces:**
- Final branch must retain the upstream OpenAI chat API behavior and add isolated data-URI attachments.

- [ ] **Step 1: Run formatter check**

```bash
deno fmt --check
```

Expected: PASS.

- [ ] **Step 2: Run lint**

```bash
deno lint
```

Expected: PASS.

- [ ] **Step 3: Run complete tests**

```bash
deno task test
```

Expected: all existing and new tests PASS with 0 failures.

- [ ] **Step 4: Verify no forbidden implementation patterns**

Run:

```bash
grep -R "cloudcode-pa.googleapis.com\|daily-cloudcode-pa.googleapis.com" --exclude-dir=.git .
grep -R "dangerously-skip-permissions" --exclude-dir=.git .
```

Expected: no new runtime calls or dangerous permission flag in production code. Historical docs/spec text may be reviewed manually if matches exist.

- [ ] **Step 5: Review branch diff**

```bash
git diff main...HEAD --stat
git diff main...HEAD
```

Confirm changes are limited to isolation, attachment handling, tests, permissions, and docs.

- [ ] **Step 6: Commit any verification-only fixes**

If formatting or a directly related regression required changes:

```bash
git add <changed-files>
git commit -m "fix: complete multimodal isolation integration"
```

Otherwise do not create an empty commit.

- [ ] **Step 7: Open a draft pull request**

Open a PR from `feature/openai-multimodal-isolation` to `main` summarizing:

- official `agy` stream-json path retained;
- bare-model request workspace isolation added;
- safe data-URI multimodal staging added;
- remote URL fetching intentionally rejected;
- auto-agent routes intentionally remain text-only;
- test/lint/format results.
