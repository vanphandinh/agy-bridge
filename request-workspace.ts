export interface RequestWorkspace {
  dir: string;
  writeAttachment(bytes: Uint8Array, extension: string): Promise<string>;
  cleanup(): Promise<void>;
}

export interface ParsedDataUri {
  mime: string;
  bytes: Uint8Array<ArrayBuffer>;
}

export interface AttachmentLimits {
  maxAttachmentBytes: number;
  maxRequestAttachmentBytes: number;
}

export interface StagedAttachment {
  path: string;
  relativeName: string;
  mime: string;
  size: number;
  sha256: string;
  nextTotal: number;
}

export class AttachmentInputError extends Error {
  constructor(public status: number, message: string) {
    super(message);
    this.name = "AttachmentInputError";
  }
}

const MIME_EXTENSIONS: Record<string, string> = {
  "image/png": ".png",
  "image/jpeg": ".jpg",
  "image/webp": ".webp",
  "image/gif": ".gif",
  "application/pdf": ".pdf",
  "text/plain": ".txt",
  "text/csv": ".csv",
  "application/msword": ".doc",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
    ".docx",
};

const CLEANUP_ATTEMPTS = 3;
const CLEANUP_RETRY_DELAY_MS = 25;

interface DataUriParts {
  mime: string;
  payload: string;
  decodedSize: number;
}

export function mimeToExtension(mime: string): string | null {
  return MIME_EXTENSIONS[mime.toLowerCase()] ?? null;
}

function parseDataUriParts(url: string): DataUriParts {
  if (!url.startsWith("data:")) {
    throw new AttachmentInputError(
      400,
      "remote attachment URLs are not supported; send a base64 data: URI",
    );
  }

  const match = /^data:([^;,]+);base64,([A-Za-z0-9+/]*={0,2})$/.exec(url);
  if (!match || match[2].length % 4 !== 0) {
    throw new AttachmentInputError(400, "malformed base64 data URI");
  }

  const mime = match[1].toLowerCase();
  if (!mimeToExtension(mime)) {
    throw new AttachmentInputError(
      400,
      `unsupported attachment MIME type: ${mime}`,
    );
  }

  const payload = match[2];
  const padding = payload.endsWith("==") ? 2 : payload.endsWith("=") ? 1 : 0;
  const decodedSize = payload.length === 0
    ? 0
    : payload.length / 4 * 3 - padding;
  return { mime, payload, decodedSize };
}

function decodeBase64(payload: string): Uint8Array<ArrayBuffer> {
  let decoded: string;
  try {
    decoded = atob(payload);
  } catch {
    throw new AttachmentInputError(400, "malformed base64 data URI");
  }
  const bytes = new Uint8Array(decoded.length);
  for (let i = 0; i < decoded.length; i++) bytes[i] = decoded.charCodeAt(i);
  return bytes;
}

export function parseDataUri(url: string): ParsedDataUri {
  const parsed = parseDataUriParts(url);
  return { mime: parsed.mime, bytes: decodeBase64(parsed.payload) };
}

async function sha256Hex(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes.buffer);
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

export async function createRequestWorkspace(
  stateDir: string,
): Promise<RequestWorkspace> {
  const workRoot = `${stateDir}/work`;
  await Deno.mkdir(workRoot, { recursive: true });
  const dir = await Deno.makeTempDir({ dir: workRoot, prefix: "req-" });
  let attachmentIndex = 0;
  let cleaned = false;

  return {
    dir,
    async writeAttachment(
      bytes: Uint8Array,
      extension: string,
    ): Promise<string> {
      if (cleaned) throw new Error("request workspace already cleaned up");
      attachmentIndex++;
      const relativeName = `attachment-${
        String(attachmentIndex).padStart(3, "0")
      }${extension}`;
      const path = `${dir}/${relativeName}`;
      await Deno.writeFile(path, bytes, { create: true, mode: 0o600 });
      return path;
    },
    async cleanup(): Promise<void> {
      if (cleaned) return;

      let lastError: unknown;
      for (let attempt = 1; attempt <= CLEANUP_ATTEMPTS; attempt++) {
        try {
          await Deno.remove(dir, { recursive: true });
          cleaned = true;
          return;
        } catch (error) {
          if (error instanceof Deno.errors.NotFound) {
            cleaned = true;
            return;
          }
          lastError = error;
          if (attempt < CLEANUP_ATTEMPTS) {
            await new Promise((resolve) =>
              setTimeout(resolve, CLEANUP_RETRY_DELAY_MS * attempt)
            );
          }
        }
      }

      throw lastError;
    },
  };
}

export async function stageDataUri(
  workspace: RequestWorkspace,
  url: string,
  limits: AttachmentLimits,
  runningTotal: number,
): Promise<StagedAttachment> {
  const parsed = parseDataUriParts(url);
  const extension = mimeToExtension(parsed.mime);
  if (!extension) {
    throw new AttachmentInputError(
      400,
      `unsupported attachment MIME type: ${parsed.mime}`,
    );
  }

  const size = parsed.decodedSize;
  if (size > limits.maxAttachmentBytes) {
    throw new AttachmentInputError(
      413,
      `attachment exceeds ${limits.maxAttachmentBytes} decoded bytes`,
    );
  }
  const nextTotal = runningTotal + size;
  if (nextTotal > limits.maxRequestAttachmentBytes) {
    throw new AttachmentInputError(
      413,
      `request attachments exceed ${limits.maxRequestAttachmentBytes} decoded bytes`,
    );
  }

  const bytes = decodeBase64(parsed.payload);
  const sha256 = await sha256Hex(bytes);
  const path = await workspace.writeAttachment(bytes, extension);
  const relativeName = path.slice(workspace.dir.length + 1);
  return {
    path,
    relativeName,
    mime: parsed.mime,
    size,
    sha256,
    nextTotal,
  };
}
