import { assertEquals, assertStringIncludes } from "@std/assert";

function freePort(): number {
  const listener = Deno.listen({ port: 0, hostname: "127.0.0.1" });
  const port = (listener.addr as Deno.NetAddr).port;
  listener.close();
  return port;
}

interface HarnessOptions {
  blockStdin?: boolean;
  printTimeout?: string;
  hardMarginMs?: string;
}

interface Harness {
  port: number;
  stateDir: string;
  homeDir: string;
  binDir: string;
  agy: string;
  bridge: Deno.ChildProcess;
}

async function startHarness(opts: HarnessOptions = {}): Promise<Harness> {
  const port = freePort();
  const stateDir = await Deno.makeTempDir({ prefix: "agy_lifecycle_state_" });
  const homeDir = await Deno.makeTempDir({ prefix: "agy_lifecycle_home_" });
  const binDir = await Deno.makeTempDir({ prefix: "agy_lifecycle_bin_" });
  const agy = `${binDir}/agy`;
  const script = `#!/usr/bin/env bash
set -eu
if [ "$1" = "models" ]; then
  printf "gemini-2.5-pro\\tGemini 2.5 Pro\\n"
  printf 'ready' > "$STATE_DIR/models-ready"
  exit 0
fi
if [ "\${AGY_TEST_BLOCK_STDIN:-}" = "1" ]; then
  printf '%s' "$$" > "$STATE_DIR/blocked-pid"
  while true; do sleep 1; done
fi
read -r line
printf '{"event":"result","result":{"status":"SUCCESS","response":"ok","conversation_id":"lifecycle-conv","usage":{"input_tokens":1,"output_tokens":1}}}\\n'
`;
  await Deno.writeTextFile(agy, script);
  await Deno.chmod(agy, 0o755);

  const bridge = new Deno.Command("deno", {
    args: [
      "run",
      "--unstable-no-legacy-abort",
      "--allow-net=127.0.0.1",
      `--allow-run=${agy}`,
      `--allow-read=${stateDir},${homeDir},${Deno.cwd()}`,
      `--allow-write=${stateDir},${homeDir}`,
      "--allow-env",
      "agy-bridge.ts",
    ],
    cwd: Deno.cwd(),
    env: {
      PORT: String(port),
      HOSTNAME: "127.0.0.1",
      HOME: homeDir,
      STATE_DIR: stateDir,
      AGY_BIN: agy,
      PATH: `${binDir}:${Deno.env.get("PATH") ?? ""}`,
      AGY_TOKEN: "",
      MAX_CONCURRENT: "1",
      PRINT_TIMEOUT: opts.printTimeout ?? "20s",
      AGY_HARD_MARGIN_MS: opts.hardMarginMs ?? "1000",
      ...(opts.blockStdin ? { AGY_TEST_BLOCK_STDIN: "1" } : {}),
    },
    stdout: "piped",
    stderr: "piped",
  }).spawn();

  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    try {
      const health = await fetch(`http://127.0.0.1:${port}/healthz`);
      await Deno.stat(`${stateDir}/models-ready`);
      if (health.ok) {
        return { port, stateDir, homeDir, binDir, agy, bridge };
      }
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  }

  try {
    bridge.kill("SIGTERM");
  } catch {
    // already stopped
  }
  throw new Error("bridge did not start");
}

async function stopHarness(h: Harness): Promise<void> {
  try {
    const pid = Number(await Deno.readTextFile(`${h.stateDir}/blocked-pid`));
    if (Number.isInteger(pid) && pid > 0) Deno.kill(pid, "SIGKILL");
  } catch {
    // no blocked child
  }
  try {
    h.bridge.kill("SIGTERM");
  } catch {
    // already stopped
  }
  try {
    await h.bridge.status;
  } catch {
    // ignore
  }
  for (const dir of [h.stateDir, h.homeDir, h.binDir]) {
    try {
      await Deno.remove(dir, { recursive: true });
    } catch {
      // ignore
    }
  }
}

async function chat(
  h: Harness,
  content: string,
  signal?: AbortSignal,
): Promise<Response> {
  return await fetch(`http://127.0.0.1:${h.port}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: "gemini-2.5-pro",
      messages: [{ role: "user", content }],
    }),
    signal,
  });
}

Deno.test("spawn failure releases the concurrency slot and returns a bridge error", async () => {
  const h = await startHarness();
  try {
    let first: Response;
    await Deno.chmod(h.agy, 0o000);
    try {
      first = await chat(h, "spawn must fail");
    } finally {
      await Deno.chmod(h.agy, 0o755);
    }

    assertEquals(first.status, 502);
    const firstBody = await first.json();
    assertStringIncludes(firstBody.error?.message, "spawn");

    const second = await chat(h, "slot must still be usable");
    assertEquals(second.status, 200);
  } finally {
    try {
      await Deno.chmod(h.agy, 0o755);
    } catch {
      // already removed
    }
    await stopHarness(h);
  }
});

Deno.test("hard deadline also covers a blocked stdin write", async () => {
  const h = await startHarness({
    blockStdin: true,
    printTimeout: "100ms",
    hardMarginMs: "100",
  });
  const controller = new AbortController();
  const clientTimeout = setTimeout(() => controller.abort(), 2_000);
  let response: Response | null = null;

  try {
    try {
      response = await chat(h, "x".repeat(2 * 1024 * 1024), controller.signal);
    } catch {
      // A client-side timeout is evidence that the bridge deadline did not
      // protect the stdin-delivery phase. Kill the blocked mock below so this
      // regression fails promptly instead of leaking a child into the suite.
    }

    if (response === null) {
      try {
        const pid = Number(await Deno.readTextFile(`${h.stateDir}/blocked-pid`));
        if (Number.isInteger(pid) && pid > 0) Deno.kill(pid, "SIGKILL");
      } catch {
        // child may already have exited
      }
    }

    assertEquals(response?.status, 502);
    const body = await response!.json();
    assertStringIncludes(body.error?.message, "hard deadline exceeded");
  } finally {
    clearTimeout(clientTimeout);
    controller.abort();
    await stopHarness(h);
  }
});
