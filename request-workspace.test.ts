import { assert, assertEquals, assertRejects, assertThrows } from "@std/assert";
import {
  AttachmentInputError,
  createRequestWorkspace,
  mimeToExtension,
  parseDataUri,
  stageDataUri,
} from "./request-workspace.ts";

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
  try {
    const path = await ws.writeAttachment(
      new TextEncoder().encode("hello"),
      ".txt",
    );
    assert(path.startsWith(ws.dir));
    assertEquals(path.endsWith("attachment-001.txt"), true);
    assertEquals(await Deno.readTextFile(path), "hello");
    await ws.cleanup();
    await ws.cleanup();
    await assertRejects(() => Deno.stat(ws.dir));
  } finally {
    try {
      await Deno.remove(state, { recursive: true });
    } catch {
      // already removed
    }
  }
});

Deno.test("cleanup retries a transient removal failure within one call", async () => {
  const state = await Deno.makeTempDir();
  const ws = await createRequestWorkspace(state);
  const originalRemove = Deno.remove;
  let calls = 0;
  Object.defineProperty(Deno, "remove", {
    configurable: true,
    value: async (path: string | URL, options?: Deno.RemoveOptions) => {
      calls++;
      if (calls === 1) throw new Deno.errors.PermissionDenied("transient");
      return await originalRemove(path, options);
    },
  });
  try {
    await ws.cleanup();
    assertEquals(calls, 2);
    await assertRejects(() => Deno.stat(ws.dir), Deno.errors.NotFound);
  } finally {
    Object.defineProperty(Deno, "remove", {
      configurable: true,
      value: originalRemove,
    });
    try {
      await originalRemove(state, { recursive: true });
    } catch {
      // already removed
    }
  }
});

Deno.test("parseDataUri decodes strict base64 data URIs", () => {
  const parsed = parseDataUri("data:image/png;base64,aGVsbG8=");
  assertEquals(parsed.mime, "image/png");
  assertEquals(new TextDecoder().decode(parsed.bytes), "hello");
});

Deno.test("parseDataUri rejects malformed and non-data URLs", () => {
  const e1 = assertThrows(
    () => parseDataUri("data:image/png;base64,%%%"),
    AttachmentInputError,
  );
  assertEquals(e1.status, 400);
  const e2 = assertThrows(
    () => parseDataUri("https://example.com/a.png"),
    AttachmentInputError,
  );
  assertEquals(e2.status, 400);
});

Deno.test("mime allowlist maps supported types and rejects unknown types", () => {
  assertEquals(mimeToExtension("image/jpeg"), ".jpg");
  assertEquals(mimeToExtension("application/pdf"), ".pdf");
  assertEquals(mimeToExtension("application/octet-stream"), null);
});

Deno.test("stageDataUri enforces per-file and total decoded byte limits", async () => {
  const state = await Deno.makeTempDir();
  const ws = await createRequestWorkspace(state);
  try {
    const url = `data:text/plain;base64,${btoa("hello")}`;
    const one = await stageDataUri(ws, url, {
      maxAttachmentBytes: 5,
      maxRequestAttachmentBytes: 9,
    }, 0);
    assertEquals(one.size, 5);
    assertEquals(one.nextTotal, 5);
    assertEquals(one.relativeName, "attachment-001.txt");

    const perFile = await Promise.resolve().then(() =>
      stageDataUri(ws, `data:text/plain;base64,${btoa("123456")}`, {
        maxAttachmentBytes: 5,
        maxRequestAttachmentBytes: 20,
      }, 0)
    ).then(() => null, (e) => e);
    assert(perFile instanceof AttachmentInputError);
    assertEquals(perFile.status, 413);

    const total = await Promise.resolve().then(() =>
      stageDataUri(ws, `data:text/plain;base64,${btoa("abcde")}`, {
        maxAttachmentBytes: 10,
        maxRequestAttachmentBytes: 9,
      }, 5)
    ).then(() => null, (e) => e);
    assert(total instanceof AttachmentInputError);
    assertEquals(total.status, 413);
  } finally {
    await ws.cleanup();
    await Deno.remove(state, { recursive: true });
  }
});

Deno.test("stageDataUri rejects oversized base64 before decoding", async () => {
  const state = await Deno.makeTempDir();
  const ws = await createRequestWorkspace(state);
  const originalAtob = globalThis.atob;
  globalThis.atob = () => {
    throw new Error("decoder must not run for an oversized attachment");
  };
  try {
    const error = await stageDataUri(
      ws,
      "data:text/plain;base64,aGVsbG8=",
      { maxAttachmentBytes: 4, maxRequestAttachmentBytes: 8 },
      0,
    ).then(() => null, (e) => e);
    assert(error instanceof AttachmentInputError);
    assertEquals(error.status, 413);
  } finally {
    globalThis.atob = originalAtob;
    await ws.cleanup();
    await Deno.remove(state, { recursive: true });
  }
});
