import {
  AttachmentInputError,
  type AttachmentLimits,
  type RequestWorkspace,
  stageDataUri,
} from "./request-workspace.ts";

export interface TextContentPart {
  type: "text";
  text: string;
}

export interface ImageUrlContentPart {
  type: "image_url";
  image_url: { url: string };
}

export type MessageContentPart = TextContentPart | ImageUrlContentPart;
export type MessageContent = string | MessageContentPart[] | null | undefined;

export interface NormalizedMessageContent {
  text: string;
  attachmentCount: number;
  totalAttachmentBytes: number;
}

export async function normalizeMessageContent(
  content: MessageContent,
  workspace: RequestWorkspace,
  limits: AttachmentLimits,
): Promise<NormalizedMessageContent> {
  if (typeof content === "string") {
    return { text: content, attachmentCount: 0, totalAttachmentBytes: 0 };
  }
  if (content == null) {
    return { text: "", attachmentCount: 0, totalAttachmentBytes: 0 };
  }
  if (!Array.isArray(content)) {
    throw new AttachmentInputError(400, "unsupported message content");
  }

  const rendered: string[] = [];
  let attachmentCount = 0;
  let totalAttachmentBytes = 0;

  for (const part of content) {
    if (!part || typeof part !== "object") {
      throw new AttachmentInputError(400, "unsupported content-part type");
    }
    if (part.type === "text") {
      if (typeof part.text !== "string") {
        throw new AttachmentInputError(
          400,
          "text content part is missing text",
        );
      }
      rendered.push(part.text);
      continue;
    }
    if (part.type === "image_url") {
      const url = part.image_url?.url;
      if (typeof url !== "string" || url.length === 0) {
        throw new AttachmentInputError(
          400,
          "image_url content part is missing url",
        );
      }
      const staged = await stageDataUri(
        workspace,
        url,
        limits,
        totalAttachmentBytes,
      );
      totalAttachmentBytes = staged.nextTotal;
      attachmentCount++;
      rendered.push(
        `[Attachment: ${staged.relativeName}; mime=${staged.mime}; sha256=${staged.sha256}]`,
      );
      continue;
    }
    throw new AttachmentInputError(
      400,
      `unsupported content-part type: ${
        (part as { type?: unknown }).type ?? "unknown"
      }`,
    );
  }

  return {
    text: rendered.join(attachmentCount === 0 ? "" : "\n"),
    attachmentCount,
    totalAttachmentBytes,
  };
}
