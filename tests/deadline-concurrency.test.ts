import { assertEquals } from "@std/assert";

function freePort(): number {
  const listener = Deno.listen({ port: 0, hostname: "127.0.0.1" });
  const port = (listener.addr as Deno.NetAddr).port;
  listener.close();
  return port;
}

Deno.test("hard deadline keeps concurrency slot until agy exits", async () => {
  const port = freePort();
  const stateDir = await Deno.makeTempDir({ prefix: "agy_deadline_state_" });
  const homeDir = await Deno.makeTempDir({ prefix: "agy_deadline_home_" });
  const binDir = await Deno.makeTempDir({ prefix: "agy_deadline_bin_" });
  const agy = `${binDir}/agy`;
  const script = `#!/usr/bin/env bash
set -eu
if [ "$1" = "models" ]; then
  printf "gemini-2.5-pro\\tGemini 2.5 Pro\\n"
  exit 0
fi
read -r line
if printf '%s' "$line" | grep -q 'hold-deadline'; then
  printf '%s' "$$" > "$STATE_DIR/first-pid"
  trap '' TERM
  while true; do sleep 1; done
fi
if [ -f "$STATE_DIR/first-pid" ] && kill -0 "$(cat "$STATE_DIR/first-pid")" 2>/dev/null; then
  printf 'overlap' > "$STATE_DIR/overlap"
fi
printf '{"event":"result","result":{"status":"SUCCESS","response":"second-ok","conversation_id":"second-conv","usage":{"input_tokens":1,"output_tokens":1}}}\\n'
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
      PRINT_TIMEOUT: "100ms",
      AGY_HARD_MARGIN_MS: "100",
    },
    stdout: "piped",
    stderr: "piped",
  }).spawn();

  try {
    const upDeadline = Date.now() + 10_000;
    while (true) {
      try {
        if ((await fetch(`http://127.0.0.1:${port}/healthz`)).ok) break;
      } catch {
        if (Date.now() >= upDeadline) throw new Error("bridge did not start");
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
    }

    const firstPromise = fetch(
      `http://127.0.0.1:${port}/v1/chat/completions`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          model: "gemini-2.5-pro",
          messages: [{ role: "user", content: "hold-deadline" }],
        }),
      },
    );

    const startedDeadline = Date.now() + 3_000;
    while (true) {
      try {
        await Deno.stat(`${stateDir}/first-pid`);
        break;
      } catch {
        if (Date.now() >= startedDeadline) {
          throw new Error("first agy did not start");
        }
        await new Promise((resolve) => setTimeout(resolve, 25));
      }
    }

    const first = await firstPromise;
    assertEquals(first.status, 502);
    await first.text();

    const second = await fetch(`http://127.0.0.1:${port}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model: "gemini-2.5-pro",
        messages: [{ role: "user", content: "second" }],
      }),
    });
    assertEquals(second.status, 200);
    await second.text();

    let overlapped = false;
    try {
      await Deno.stat(`${stateDir}/overlap`);
      overlapped = true;
    } catch {
      // expected: the gate stays held until the timed-out agy child exits
    }
    assertEquals(overlapped, false);
  } finally {
    try {
      bridge.kill("SIGTERM");
    } catch {
      // already stopped
    }
    try {
      await bridge.status;
    } catch {
      // ignore
    }
    try {
      const pid = Number(await Deno.readTextFile(`${stateDir}/first-pid`));
      if (Number.isInteger(pid) && pid > 0) Deno.kill(pid, "SIGKILL");
    } catch {
      // already gone
    }
    for (const dir of [stateDir, homeDir, binDir]) {
      try {
        await Deno.remove(dir, { recursive: true });
      } catch {
        // ignore
      }
    }
  }
});
