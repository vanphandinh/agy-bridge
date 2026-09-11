import { assert, assertStringIncludes } from "@std/assert";

Deno.test("service grants state-dir read/write without broad home read", async () => {
  const service = await Deno.readTextFile("agy-bridge.service.template");
  assertStringIncludes(
    service,
    "--allow-read=%h/.gemini/antigravity-cli/brain,%h/.local/state/agy-bridge",
  );
  assertStringIncludes(service, "--allow-write=%h/.local/state/agy-bridge");
  assert(!service.includes("--allow-read=%h "));
  assert(!service.includes("--allow-read=%h\\\n"));
});

Deno.test("env example documents decoded attachment limits", async () => {
  const env = await Deno.readTextFile(".env.example");
  assertStringIncludes(env, "AGY_MAX_ATTACHMENT_BYTES=20971520");
  assertStringIncludes(env, "AGY_MAX_REQUEST_ATTACHMENT_BYTES=67108864");
});

Deno.test("installer-generated env includes attachment limit defaults", async () => {
  const install = await Deno.readTextFile("install.sh");
  assertStringIncludes(install, "AGY_MAX_ATTACHMENT_BYTES=20971520");
  assertStringIncludes(install, "AGY_MAX_REQUEST_ATTACHMENT_BYTES=67108864");
});

Deno.test("installer migrates only the legacy managed raw agent without --force", async () => {
  const install = await Deno.readTextFile("install.sh");
  assertStringIncludes(install, "LEGACY_RAW_AGENT=false");
  assertStringIncludes(
    install,
    "description: Plain text-in/text-out endpoint for local bridges. Never uses tools.",
  );
  assertStringIncludes(
    install,
    "Never invoke any tool, command, file operation, or external action",
  );
  assertStringIncludes(install, '[[ "$LEGACY_RAW_AGENT" != true ]]');
});

Deno.test("raw agent may inspect only bridge-staged attachments", async () => {
  const raw = await Deno.readTextFile("agents/raw/agent.md");
  assertStringIncludes(raw, "- view_file");
  assertStringIncludes(raw, "bridge-staged attachment");
  assertStringIncludes(raw, "attachment-NNN");
  assertStringIncludes(raw, "absolute path inside the current workspace");
  assertStringIncludes(
    raw,
    "Never use `view_file` outside the current workspace",
  );
  assert(!raw.includes("Never invoke any tool, command, file operation"));
});
