import { assertEquals } from "@std/assert";

function freePort(): number {
  const listener = Deno.listen({ port: 0, hostname: "127.0.0.1" });
  const port = (listener.addr as Deno.NetAddr).port;
  listener.close();
  return port;
}

Deno.test("aborted stream keeps concurrency slot until agy exits", async () => {
  const port = freePort();
  const stateDir = await Deno.makeTempDir({ prefix: "agy_abort_state_" });
  const homeDir = await Deno.makeTempDir({ prefix: "agy_abort_home_" });
  const binDir = await Deno.makeTempDir({ prefix: "agy_abort_bin_" });
  const agy = `${binDir}/agy`;
  const script = `#!/usr/bin/env bash
set -eu
if [ "$1" = "models" ]; then
  printf "gemini-2.5-pro\\tGemini 2.5 Pro\\n"
  exit 0
fi
read -r line
if printf '%s' "$line" | grep -q 'hold-first'; then
  printf '%s' "$$" > "$STATE_DIR/first-pid"
  trap '' TERM
  printf '{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"started"}}\\n'
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
      PRINT_TIMEOUT: "20s",
      AGY_HARD_MARGIN_MS: "1000",
    },
    stdout: "piped",
    stderr: "piped",
  }).spawn();

  const abort = new AbortController();
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

    const first = await fetch(`http://127.0.0.1:${port}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model: "gemini-2.5-pro",
        stream: true,
        messages: [{ role: "user", content: "hold-first" }],
      }),
      signal: abort.signal,
    });
    assertEquals(first.status, 200);
    const reader = first.body!.getReader();
    await reader.read();

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

    abort.abort();
    try {
      await reader.cancel();
    } catch {
      // Abort may already have errored the reader.
    }

    const second = await fetch(`http://127.0.0.1:${port}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model: "gemini-2.5-pro",
        messages: [{ role: "user", content: "second" }],
      }),
    });
    assertEquals(second.status, 200);

    let overlapped = false;
    try {
      await Deno.stat(`${stateDir}/overlap`);
      overlapped = true;
    } catch {
      // expected: second agy starts only after the first child exits
    }
    assertEquals(overlapped, false);
  } finally {
    abort.abort();
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

Deno.test("aborted queued request never reaches runAgy", async () => {
  const port = freePort();
  const stateDir = await Deno.makeTempDir({ prefix: "agy_queue_state_" });
  const homeDir = await Deno.makeTempDir({ prefix: "agy_queue_home_" });
  const binDir = await Deno.makeTempDir({ prefix: "agy_queue_bin_" });
  const agy = `${binDir}/agy`;
  const script = `#!/usr/bin/env bash
set -eu
if [ "$1" = "models" ]; then
  printf "gemini-2.5-pro\\tGemini 2.5 Pro\\n"
  exit 0
fi
printf 'invoke\\n' >> "$STATE_DIR/invocations"
read -r line
if printf '%s' "$line" | grep -q 'hold-gate'; then
  printf 'started' > "$STATE_DIR/first-started"
  while [ ! -f "$STATE_DIR/release-first" ]; do sleep 0.05; done
  printf '{"event":"result","result":{"status":"SUCCESS","response":"first-ok","conversation_id":"first-conv","usage":{"input_tokens":1,"output_tokens":1}}}\\n'
  exit 0
fi
printf 'second' > "$STATE_DIR/second-invoked"
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
      PRINT_TIMEOUT: "20s",
      AGY_HARD_MARGIN_MS: "1000",
    },
    stdout: "piped",
    stderr: "piped",
  }).spawn();

  const queuedAbort = new AbortController();
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
          messages: [{ role: "user", content: "hold-gate" }],
        }),
      },
    );

    const firstDeadline = Date.now() + 3_000;
    while (true) {
      try {
        await Deno.stat(`${stateDir}/first-started`);
        break;
      } catch {
        if (Date.now() >= firstDeadline) {
          throw new Error("first agy did not start");
        }
        await new Promise((resolve) => setTimeout(resolve, 25));
      }
    }

    const secondPromise = fetch(
      `http://127.0.0.1:${port}/v1/chat/completions`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          model: "gemini-2.5-pro",
          messages: [{ role: "user", content: "queued-second" }],
        }),
        signal: queuedAbort.signal,
      },
    ).catch(() => null);

    const queuedDeadline = Date.now() + 3_000;
    while (true) {
      let workspaces = 0;
      try {
        for await (const entry of Deno.readDir(`${stateDir}/work`)) {
          if (entry.isDirectory && entry.name.startsWith("req-")) workspaces++;
        }
      } catch {
        // work root not created yet
      }
      if (workspaces >= 2) break;
      if (Date.now() >= queuedDeadline) {
        throw new Error("second request did not reach the queue");
      }
      await new Promise((resolve) => setTimeout(resolve, 25));
    }

    queuedAbort.abort();
    await secondPromise;
    await Deno.writeTextFile(`${stateDir}/release-first`, "go");

    const first = await firstPromise;
    assertEquals(first.status, 200);
    await first.text();

    await new Promise((resolve) => setTimeout(resolve, 500));
    let secondInvoked = false;
    try {
      await Deno.stat(`${stateDir}/second-invoked`);
      secondInvoked = true;
    } catch {
      // expected: aborted waiter is removed before the gate transfers a slot
    }
    assertEquals(secondInvoked, false);

    const usageLines = (await Deno.readTextFile(`${stateDir}/usage.jsonl`))
      .trim()
      .split("\n")
      .filter(Boolean);
    assertEquals(usageLines.length, 1);
  } finally {
    queuedAbort.abort();
    try {
      await Deno.writeTextFile(`${stateDir}/release-first`, "go");
    } catch {
      // ignore
    }
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
    for (const dir of [stateDir, homeDir, binDir]) {
      try {
        await Deno.remove(dir, { recursive: true });
      } catch {
        // ignore
      }
    }
  }
});
