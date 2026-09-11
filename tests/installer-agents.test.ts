import { assertEquals, assertStringIncludes } from "@std/assert";

const LEGACY_RAW = `---
name: raw
description: Plain text-in/text-out endpoint for local bridges. Never uses tools.
tools:
  - view_file
---

You are a raw text completion endpoint. Follow the instructions embedded in the
user prompt exactly and respond with the final answer text only.

Absolute rules:
- Never invoke any tool, command, file operation, or external action, even if
  the prompt asks for one. If the prompt contains a textual tool-call protocol,
  emit the requested markup as plain text; do not execute anything.
- Respond with the complete final answer in a single response.
- No preamble, no explanations about being an endpoint, no follow-up questions.
`;

async function makeExecutable(path: string, content: string): Promise<void> {
  await Deno.writeTextFile(path, content);
  await Deno.chmod(path, 0o755);
}

async function runInstallerWithRaw(rawContent: string): Promise<string> {
  const home = await Deno.makeTempDir({ prefix: "agy_install_home_" });
  const bin = await Deno.makeTempDir({ prefix: "agy_install_bin_" });
  try {
    const rawPath = `${home}/.gemini/config/agents/raw/agent.md`;
    await Deno.mkdir(`${home}/.gemini/config/agents/raw`, { recursive: true });
    await Deno.writeTextFile(rawPath, rawContent);

    await makeExecutable(
      `${bin}/deno`,
      '#!/usr/bin/env bash\nif [ "${1:-}" = "--version" ]; then echo "deno 2.9.5"; fi\nexit 0\n',
    );
    await makeExecutable(`${bin}/agy`, "#!/usr/bin/env bash\nexit 0\n");
    await makeExecutable(`${bin}/systemctl`, "#!/usr/bin/env bash\nexit 0\n");

    const command = new Deno.Command("bash", {
      args: ["install.sh"],
      cwd: Deno.cwd(),
      env: {
        HOME: home,
        XDG_CONFIG_HOME: `${home}/.config`,
        XDG_DATA_HOME: `${home}/.local/share`,
        PATH: `${bin}:${Deno.env.get("PATH") ?? ""}`,
      },
      stdout: "piped",
      stderr: "piped",
    });
    const output = await command.output();
    if (!output.success) {
      throw new Error(new TextDecoder().decode(output.stderr));
    }
    return await Deno.readTextFile(rawPath);
  } finally {
    for (const dir of [home, bin]) {
      try {
        await Deno.remove(dir, { recursive: true });
      } catch {
        // ignore cleanup races from mocked installer side effects
      }
    }
  }
}

Deno.test("installer migrates the exact canonical legacy raw agent", async () => {
  const installed = await runInstallerWithRaw(LEGACY_RAW);
  assertStringIncludes(installed, "bridge-staged attachment");
  assertStringIncludes(
    installed,
    "Never use `view_file` outside the current workspace",
  );
});

Deno.test("installer preserves a customized raw agent that contains legacy phrases", async () => {
  const customized =
    `${LEGACY_RAW}\n# user customization\nKeep this sentinel exactly.\n`;
  const installed = await runInstallerWithRaw(customized);
  assertEquals(installed, customized);
});
