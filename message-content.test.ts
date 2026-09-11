import { assertEquals, assertRejects } from "@std/assert";
import { normalizeMessageContent } from "./message-content.ts";
import {
  AttachmentInputError,
  createRequestWorkspace,
} from "./request-workspace.ts";

Deno.test("normalizeMessageContent preserves text and attachment order", async () => {
  const state = await Deno.makeTempDir();
  const ws = await createRequestWorkspace(state);
  try {
    const result = await normalizeMessageContent(
      [
        { type: "text", text: "before" },
        {
          type: "image_url",
          image_url: { url: "data:image/png;base64,aGVsbG8=" },
        },
        { type: "text", text: "after" },
      ],
      ws,
      { maxAttachmentBytes: 1024, maxRequestAttachmentBytes: 2048 },
    );
    assertEquals(
      result.text,
      "before\n[Attachment: attachment-001.png; mime=image/png; sha256=2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824]\nafter",
    );
    assertEquals(result.attachmentCount, 1);
    assertEquals(result.totalAttachmentBytes, 5);
  } finally {
    await ws.cleanup();
    await Deno.remove(state, { recursive: true });
  }
});

Deno.test("normalizeMessageContent preserves legacy text-array concatenation", async () => {
  const state = await Deno.makeTempDir();
  const ws = await createRequestWorkspace(state);
  try {
    const result = await normalizeMessageContent(
      [
        { type: "text", text: "hello" },
        { type: "text", text: " world" },
      ],
      ws,
      { maxAttachmentBytes: 1024, maxRequestAttachmentBytes: 2048 },
    );
    assertEquals(result.text, "hello world");
    assertEquals(result.attachmentCount, 0);
  } finally {
    await ws.cleanup();
    await Deno.remove(state, { recursive: true });
  }
});

Deno.test("normalizeMessageContent increments generated attachment names", async () => {
  const state = await Deno.makeTempDir();
  const ws = await createRequestWorkspace(state);
  try {
    const result = await normalizeMessageContent(
      [
        {
          type: "image_url",
          image_url: { url: "data:text/plain;base64,YQ==" },
        },
        { type: "image_url", image_url: { url: "data:text/csv;base64,Yg==" } },
      ],
      ws,
      { maxAttachmentBytes: 1024, maxRequestAttachmentBytes: 2048 },
    );
    assertEquals(
      result.text,
      "[Attachment: attachment-001.txt; mime=text/plain; sha256=ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb]\n[Attachment: attachment-002.csv; mime=text/csv; sha256=3e23e8160039594a33894f6564e1b1348bbd7a0088d42c4acb73eeaed59c009d]",
    );
    assertEquals(result.attachmentCount, 2);
  } finally {
    await ws.cleanup();
    await Deno.remove(state, { recursive: true });
  }
});

Deno.test("normalizeMessageContent rejects remote URLs and unknown part types", async () => {
  const state = await Deno.makeTempDir();
  const ws = await createRequestWorkspace(state);
  try {
    await assertRejects(
      () =>
        normalizeMessageContent(
          [
            {
              type: "image_url",
              image_url: { url: "https://example.com/x.png" },
            },
          ],
          ws,
          { maxAttachmentBytes: 1024, maxRequestAttachmentBytes: 2048 },
        ),
      AttachmentInputError,
    );
    await assertRejects(
      () =>
        normalizeMessageContent(
          [
            { type: "input_audio" } as never,
          ],
          ws,
          { maxAttachmentBytes: 1024, maxRequestAttachmentBytes: 2048 },
        ),
      AttachmentInputError,
    );
  } finally {
    await ws.cleanup();
    await Deno.remove(state, { recursive: true });
  }
});

Deno.test("normalizeMessageContent leaves string content unchanged", async () => {
  const state = await Deno.makeTempDir();
  const ws = await createRequestWorkspace(state);
  try {
    const result = await normalizeMessageContent("hello", ws, {
      maxAttachmentBytes: 1024,
      maxRequestAttachmentBytes: 2048,
    });
    assertEquals(result.text, "hello");
    assertEquals(result.attachmentCount, 0);
    assertEquals(result.totalAttachmentBytes, 0);
  } finally {
    await ws.cleanup();
    await Deno.remove(state, { recursive: true });
  }
});
