import { assertEquals } from "@std/assert";

function freePort(): number {
  const listener = Deno.listen({ port: 0, hostname: "127.0.0.1" });
  const port = (listener.addr as Deno.NetAddr).port;
  listener.close();
  return port;
}

Deno.test("deadline on a reused conversation retries with the full prompt", async () => {
  const port = freePort();
  const stateDir = await Deno.makeTempDir({
    prefix: "agy_reuse_lifecycle_state_",
  });
  const homeDir = await Deno.makeTempDir({
    prefix: "agy_reuse_lifecycle_home_",
  });
  const binDir = await Deno.makeTempDir({ prefix: "agy_reuse_lifecycle_bin_" });
  const agy = `${binDir}/agy`;

  await Deno.writeTextFile(
    agy,
    `#!/usr/bin/env bash
set -eu
if [ "$1" = "models" ]; then
  printf "gemini-2.5-pro\\tGemini 2.5 Pro\\n"
  printf ready > "$STATE_DIR/models-ready"
  exit 0
fi

count_file="$STATE_DIR/run-count"
count=0
if [ -f "$count_file" ]; then count="$(cat "$count_file")"; fi
count=$((count + 1))
printf '%s' "$count" > "$count_file"

read -r line
has_conv=0
for arg in "$@"; do
  if [ "$arg" = "--conversation" ]; then has_conv=1; fi
done

if [ "$count" -eq 1 ]; then
  printf '{"event":"result","result":{"status":"SUCCESS","response":"turn one","conversation_id":"reuse-conv-1","usage":{"input_tokens":1,"output_tokens":1}}}\\n'
  exit 0
fi

if [ "$has_conv" -eq 1 ]; then
  exec sleep 30
fi

if printf '%s' "$line" | grep -Fq 'turn 1' && printf '%s' "$line" | grep -Fq 'turn 2'; then
  printf '{"event":"result","result":{"status":"SUCCESS","response":"fresh full prompt","conversation_id":"reuse-conv-2","usage":{"input_tokens":1,"output_tokens":1}}}\\n'
  exit 0
fi

printf '{"event":"result","result":{"status":"ERROR","error":"fresh retry lost prior history","conversation_id":"reuse-conv-bad"}}\\n'
exit 1
`,
  );
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
      AGY_REUSE: "on",
      MAX_CONCURRENT: "1",
      PRINT_TIMEOUT: "100ms",
      AGY_HARD_MARGIN_MS: "100",
    },
    stdout: "piped",
    stderr: "piped",
  }).spawn();

  try {
    const startupDeadline = Date.now() + 10_000;
    while (Date.now() < startupDeadline) {
      try {
        const health = await fetch(`http://127.0.0.1:${port}/healthz`);
        await Deno.stat(`${stateDir}/models-ready`);
        if (health.ok) break;
      } catch {
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
    }

    const first = await fetch(`http://127.0.0.1:${port}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model: "gemini-2.5-pro",
        messages: [{ role: "user", content: "turn 1" }],
      }),
    });
    assertEquals(first.status, 200);

    const second = await fetch(`http://127.0.0.1:${port}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model: "gemini-2.5-pro",
        messages: [
          { role: "user", content: "turn 1" },
          { role: "assistant", content: "turn one" },
          { role: "user", content: "turn 2" },
        ],
      }),
    });
    assertEquals(second.status, 200);
    const body = await second.json();
    assertEquals(body.choices[0].message.content, "fresh full prompt");
    assertEquals(await Deno.readTextFile(`${stateDir}/run-count`), "3");
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
    for (const dir of [stateDir, homeDir, binDir]) {
      try {
        await Deno.remove(dir, { recursive: true });
      } catch {
        // ignore
      }
    }
  }
});

Deno.test("failed reused stream evicts the stale conversation before the next request", async () => {
  const port = freePort();
  const stateDir = await Deno.makeTempDir({
    prefix: "agy_reuse_stream_state_",
  });
  const homeDir = await Deno.makeTempDir({ prefix: "agy_reuse_stream_home_" });
  const binDir = await Deno.makeTempDir({ prefix: "agy_reuse_stream_bin_" });
  const agy = `${binDir}/agy`;

  await Deno.writeTextFile(
    agy,
    `#!/usr/bin/env bash
set -eu
if [ "$1" = "models" ]; then
  printf "gemini-2.5-pro\\tGemini 2.5 Pro\\n"
  printf ready > "$STATE_DIR/models-ready"
  exit 0
fi

count_file="$STATE_DIR/run-count"
count=0
if [ -f "$count_file" ]; then count="$(cat "$count_file")"; fi
count=$((count + 1))
printf '%s' "$count" > "$count_file"

has_conv=0
for arg in "$@"; do
  if [ "$arg" = "--conversation" ]; then has_conv=1; fi
done
read -r line

if [ "$count" -eq 1 ]; then
  printf '{"event":"result","result":{"status":"SUCCESS","response":"turn one","conversation_id":"reuse-stream-conv","usage":{"input_tokens":1,"output_tokens":1}}}\\n'
  exit 0
fi

if [ "$count" -eq 2 ] && [ "$has_conv" -eq 1 ]; then
  exec sleep 30
fi

if [ "$has_conv" -eq 1 ]; then
  printf stale > "$STATE_DIR/stale-reused"
  printf '{"event":"result","result":{"status":"ERROR","error":"stale conversation reused","conversation_id":"reuse-stream-conv"}}\\n'
  exit 1
fi

if printf '%s' "$line" | grep -Fq 'turn 1' && printf '%s' "$line" | grep -Fq 'turn 2'; then
  printf '{"event":"result","result":{"status":"SUCCESS","response":"fresh after stream failure","conversation_id":"reuse-stream-fresh","usage":{"input_tokens":1,"output_tokens":1}}}\\n'
  exit 0
fi

printf '{"event":"result","result":{"status":"ERROR","error":"fresh request lost history","conversation_id":"reuse-stream-bad"}}\\n'
exit 1
`,
  );
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
      AGY_REUSE: "on",
      MAX_CONCURRENT: "1",
      PRINT_TIMEOUT: "100ms",
      AGY_HARD_MARGIN_MS: "100",
    },
    stdout: "piped",
    stderr: "piped",
  }).spawn();

  try {
    const startupDeadline = Date.now() + 10_000;
    while (Date.now() < startupDeadline) {
      try {
        const health = await fetch(`http://127.0.0.1:${port}/healthz`);
        await Deno.stat(`${stateDir}/models-ready`);
        if (health.ok) break;
      } catch {
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
    }

    const messages = [
      { role: "user", content: "turn 1" },
      { role: "assistant", content: "turn one" },
      { role: "user", content: "turn 2" },
    ];

    const first = await fetch(`http://127.0.0.1:${port}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model: "gemini-2.5-pro",
        messages: [messages[0]],
      }),
    });
    assertEquals(first.status, 200);

    const failedStream = await fetch(
      `http://127.0.0.1:${port}/v1/chat/completions`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          model: "gemini-2.5-pro",
          stream: true,
          messages,
        }),
      },
    );
    assertEquals(failedStream.status, 200);
    const failedText = await failedStream.text();
    assertEquals(failedText.includes("hard deadline exceeded"), true);

    const third = await fetch(`http://127.0.0.1:${port}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model: "gemini-2.5-pro",
        stream: true,
        messages,
      }),
    });
    assertEquals(third.status, 200);
    const thirdText = await third.text();
    assertEquals(thirdText.includes('"error"'), false);

    let reusedStale = false;
    try {
      await Deno.stat(`${stateDir}/stale-reused`);
      reusedStale = true;
    } catch {
      // expected: failed reused stream evicts its conversation entry
    }
    assertEquals(reusedStale, false);
    assertEquals(await Deno.readTextFile(`${stateDir}/run-count`), "3");
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
    for (const dir of [stateDir, homeDir, binDir]) {
      try {
        await Deno.remove(dir, { recursive: true });
      } catch {
        // ignore
      }
    }
  }
});

Deno.test("salvaged reused failure is evicted before a later request", async () => {
  const port = freePort();
  const stateDir = await Deno.makeTempDir({
    prefix: "agy_reuse_salvage_state_",
  });
  const homeDir = await Deno.makeTempDir({ prefix: "agy_reuse_salvage_home_" });
  const binDir = await Deno.makeTempDir({ prefix: "agy_reuse_salvage_bin_" });
  const agy = `${binDir}/agy`;

  await Deno.writeTextFile(
    agy,
    `#!/usr/bin/env bash
set -eu
if [ "$1" = "models" ]; then
  printf "gemini-2.5-pro\\tGemini 2.5 Pro\\n"
  printf ready > "$STATE_DIR/models-ready"
  exit 0
fi

count_file="$STATE_DIR/run-count"
count=0
if [ -f "$count_file" ]; then count="$(cat "$count_file")"; fi
count=$((count + 1))
printf '%s' "$count" > "$count_file"

has_conv=0
for arg in "$@"; do
  if [ "$arg" = "--conversation" ]; then has_conv=1; fi
done
read -r line

if [ "$count" -eq 1 ]; then
  printf '{"event":"result","result":{"status":"SUCCESS","response":"turn one","conversation_id":"reuse-salvage-conv","usage":{"input_tokens":1,"output_tokens":1}}}\\n'
  exit 0
fi

if [ "$count" -eq 2 ] && [ "$has_conv" -eq 1 ]; then
  log_dir="$HOME/.gemini/antigravity-cli/brain/reuse-salvage-conv/.system_generated/logs"
  mkdir -p "$log_dir"
  printf '%s\\n' '{"type":"PLANNER_RESPONSE","content":"salvaged answer"}' > "$log_dir/transcript_full.jsonl"
  printf '{"event":"result","result":{"status":"ERROR","error":"session failed after report","conversation_id":"reuse-salvage-conv"}}\\n'
  exit 1
fi

if [ "$has_conv" -eq 1 ]; then
  printf stale > "$STATE_DIR/stale-reused"
  printf '{"event":"result","result":{"status":"ERROR","error":"salvaged broken session reused","conversation_id":"reuse-salvage-conv"}}\\n'
  exit 1
fi

if printf '%s' "$line" | grep -Fq 'turn 1' && printf '%s' "$line" | grep -Fq 'turn 3'; then
  printf '{"event":"result","result":{"status":"SUCCESS","response":"fresh after salvage","conversation_id":"reuse-salvage-fresh","usage":{"input_tokens":1,"output_tokens":1}}}\\n'
  exit 0
fi

printf '{"event":"result","result":{"status":"ERROR","error":"fresh request lost history","conversation_id":"reuse-salvage-bad"}}\\n'
exit 1
`,
  );
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
      AGY_REUSE: "on",
      MAX_CONCURRENT: "1",
      PRINT_TIMEOUT: "2s",
      AGY_HARD_MARGIN_MS: "100",
    },
    stdout: "piped",
    stderr: "piped",
  }).spawn();

  try {
    const startupDeadline = Date.now() + 10_000;
    while (Date.now() < startupDeadline) {
      try {
        const health = await fetch(`http://127.0.0.1:${port}/healthz`);
        await Deno.stat(`${stateDir}/models-ready`);
        if (health.ok) break;
      } catch {
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
    }

    const first = await fetch(`http://127.0.0.1:${port}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model: "gemini-2.5-pro",
        messages: [{ role: "user", content: "turn 1" }],
      }),
    });
    assertEquals(first.status, 200);

    const secondMessages = [
      { role: "user", content: "turn 1" },
      { role: "assistant", content: "turn one" },
      { role: "user", content: "turn 2" },
    ];
    const second = await fetch(`http://127.0.0.1:${port}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model: "gemini-2.5-pro",
        messages: secondMessages,
      }),
    });
    assertEquals(second.status, 200);
    const secondBody = await second.json();
    assertEquals(secondBody.choices[0].message.content, "salvaged answer");

    const third = await fetch(`http://127.0.0.1:${port}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model: "gemini-2.5-pro",
        messages: [
          ...secondMessages,
          { role: "assistant", content: "salvaged answer" },
          { role: "user", content: "turn 3" },
        ],
      }),
    });
    assertEquals(third.status, 200);
    const thirdBody = await third.json();
    assertEquals(thirdBody.choices[0].message.content, "fresh after salvage");

    let reusedStale = false;
    try {
      await Deno.stat(`${stateDir}/stale-reused`);
      reusedStale = true;
    } catch {
      // expected: an errored session stays evicted even if its report was salvaged
    }
    assertEquals(reusedStale, false);
    assertEquals(await Deno.readTextFile(`${stateDir}/run-count`), "3");
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
    for (const dir of [stateDir, homeDir, binDir]) {
      try {
        await Deno.remove(dir, { recursive: true });
      } catch {
        // ignore
      }
    }
  }
});
