import { assertEquals, assertStringIncludes } from "@std/assert";

function freePort(): number {
  const listener = Deno.listen({ port: 0, hostname: "127.0.0.1" });
  const port = (listener.addr as Deno.NetAddr).port;
  listener.close();
  return port;
}

interface Harness {
  port: number;
  stateDir: string;
  homeDir: string;
  binDir: string;
  child: Deno.ChildProcess;
}

async function startHarness(
  extraEnv: Record<string, string> = {},
): Promise<Harness> {
  const port = freePort();
  const stateDir = await Deno.makeTempDir({ prefix: "agy_mm_state_" });
  const homeDir = await Deno.makeTempDir({ prefix: "agy_mm_home_" });
  const binDir = await Deno.makeTempDir({ prefix: "agy_mm_bin_" });
  const agy = `${binDir}/agy`;
  const script = `#!/usr/bin/env bash
set -eu
if [ "$1" = "models" ]; then
  printf "gemini-2.5-pro\\tGemini 2.5 Pro\\ngemini-3.7-flash-high\\tGemini 3.7 Flash High\\n"
  exit 0
fi
printf 'invoke\\n' >> "$STATE_DIR/invocations"
printf '%s\\n' "$*" >> "$STATE_DIR/args"
if [ "\${AGY_EARLY_SUCCESS:-}" = "1" ]; then
  exec 0<&-
  printf '{"event":"result","result":{"status":"SUCCESS","response":"fake success without stdin","conversation_id":"early-conv","usage":{"input_tokens":0,"output_tokens":1}}}\\n'
  exit 0
fi
read -r line
pwd_now="$(pwd)"
printf '%s' "$line" > "$STATE_DIR/last-input"
marker="$(printf '%s' "$line" | sed -n 's/.*\\[Attachment: \\([^;]*\\); mime=[^]]*\\].*/\\1/p')"
attachment=""
if [ -n "$marker" ] && [ -f "$marker" ]; then attachment="$(cat "$marker")"; fi
if printf '%s' "$line" | grep -q 'hang-stream'; then
  printf '%s' "$pwd_now" > "$STATE_DIR/stream-cwd"
  printf '{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"started"}}\\n'
  sleep 30
  exit 0
fi
response="cwd=$pwd_now attachment=$attachment"
printf '{"event":"result","result":{"status":"SUCCESS","response":"%s","conversation_id":"mm-conv","usage":{"input_tokens":1,"output_tokens":1}}}\\n' "$response"
`;
  await Deno.writeTextFile(agy, script);
  await Deno.chmod(agy, 0o755);
  const child = new Deno.Command("deno", {
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
      ...extraEnv,
    },
    stdout: "piped",
    stderr: "piped",
  }).spawn();
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    try {
      if ((await fetch(`http://127.0.0.1:${port}/healthz`)).ok) {
        return { port, stateDir, homeDir, binDir, child };
      }
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  try {
    child.kill("SIGTERM");
  } catch { /* ignore */ }
  throw new Error("bridge did not start");
}

async function stopHarness(h: Harness) {
  try {
    h.child.kill("SIGTERM");
  } catch { /* ignore */ }
  try {
    await h.child.status;
  } catch { /* ignore */ }
  for (const dir of [h.stateDir, h.homeDir, h.binDir]) {
    try {
      await Deno.remove(dir, { recursive: true });
    } catch { /* ignore */ }
  }
}

async function chat(h: Harness, body: unknown): Promise<Response> {
  return await fetch(`http://127.0.0.1:${h.port}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

Deno.test("bare chat uses isolated cwd and removes it after completion", async () => {
  const h = await startHarness();
  try {
    const res = await chat(h, {
      model: "gemini-2.5-pro",
      messages: [{ role: "user", content: "hello" }],
    });
    assertEquals(res.status, 200);
    const body = await res.json();
    const text = body.choices[0].message.content as string;
    assertStringIncludes(text, `${h.stateDir}/work/req-`);
    const cwd = text.slice("cwd=".length, text.indexOf(" attachment="));
    let exists = true;
    try {
      await Deno.stat(cwd);
    } catch {
      exists = false;
    }
    assertEquals(exists, false);
  } finally {
    await stopHarness(h);
  }
});

Deno.test("data URI attachment is staged, referenced in stdin, and cleaned", async () => {
  const h = await startHarness();
  try {
    const res = await chat(h, {
      model: "gemini-2.5-pro",
      messages: [{
        role: "user",
        content: [
          { type: "text", text: "before" },
          {
            type: "image_url",
            image_url: { url: "data:text/plain;base64,aGVsbG8=" },
          },
          { type: "text", text: "after" },
        ],
      }],
    });
    assertEquals(res.status, 200);
    const body = await res.json();
    assertStringIncludes(body.choices[0].message.content, "attachment=hello");
    const input = await Deno.readTextFile(`${h.stateDir}/last-input`);
    assertStringIncludes(
      input,
      "before\\n[Attachment: attachment-001.txt; mime=text/plain; sha256=2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824]\\nafter",
    );
  } finally {
    await stopHarness(h);
  }
});

Deno.test("remote URL and auto multimodal are rejected before agy invocation", async () => {
  const h = await startHarness();
  try {
    const remote = await chat(h, {
      model: "gemini-2.5-pro",
      messages: [{
        role: "user",
        content: [{
          type: "image_url",
          image_url: { url: "https://example.com/x.png" },
        }],
      }],
    });
    assertEquals(remote.status, 400);

    const auto = await chat(h, {
      model: "auto-ro-gemini-3.7-flash-high",
      messages: [{
        role: "user",
        content: [{
          type: "image_url",
          image_url: { url: "data:image/png;base64,aGVsbG8=" },
        }],
      }],
    });
    assertEquals(auto.status, 400);

    let count = 0;
    try {
      count =
        (await Deno.readTextFile(`${h.stateDir}/invocations`)).trim().split(
          "\n",
        ).length;
    } catch { /* no invocations */ }
    assertEquals(count, 0);
  } finally {
    await stopHarness(h);
  }
});

Deno.test("attachment limits return 413", async () => {
  const h = await startHarness({
    AGY_MAX_ATTACHMENT_BYTES: "4",
    AGY_MAX_REQUEST_ATTACHMENT_BYTES: "8",
  });
  try {
    const res = await chat(h, {
      model: "gemini-2.5-pro",
      messages: [{
        role: "user",
        content: [{
          type: "image_url",
          image_url: { url: "data:text/plain;base64,aGVsbG8=" },
        }],
      }],
    });
    assertEquals(res.status, 413);
  } finally {
    await stopHarness(h);
  }
});

Deno.test("total request attachment limit spans multiple messages", async () => {
  const h = await startHarness({
    AGY_MAX_ATTACHMENT_BYTES: "4",
    AGY_MAX_REQUEST_ATTACHMENT_BYTES: "5",
  });
  try {
    const attachment = {
      type: "image_url",
      image_url: { url: "data:text/plain;base64,YWJj" },
    };
    const res = await chat(h, {
      model: "gemini-2.5-pro",
      messages: [
        { role: "user", content: [attachment] },
        { role: "user", content: [attachment] },
      ],
    });
    assertEquals(res.status, 413);

    let count = 0;
    try {
      count =
        (await Deno.readTextFile(`${h.stateDir}/invocations`)).trim().split(
          "\n",
        ).length;
    } catch { /* no invocations */ }
    assertEquals(count, 0);
  } finally {
    await stopHarness(h);
  }
});

Deno.test("SSE disconnect removes isolated workspace", async () => {
  const h = await startHarness();
  const abort = new AbortController();
  try {
    const res = await fetch(`http://127.0.0.1:${h.port}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model: "gemini-2.5-pro",
        stream: true,
        messages: [{
          role: "user",
          content: [
            { type: "text", text: "hang-stream" },
            {
              type: "image_url",
              image_url: { url: "data:text/plain;base64,aGVsbG8=" },
            },
          ],
        }],
      }),
      signal: abort.signal,
    });
    assertEquals(res.status, 200);
    const reader = res.body!.getReader();
    await reader.read();

    let cwd = "";
    const startedDeadline = Date.now() + 3_000;
    while (Date.now() < startedDeadline) {
      try {
        cwd = await Deno.readTextFile(`${h.stateDir}/stream-cwd`);
        break;
      } catch {
        await new Promise((r) => setTimeout(r, 25));
      }
    }
    assertStringIncludes(cwd, `${h.stateDir}/work/req-`);

    abort.abort();
    try {
      await reader.cancel();
    } catch {
      // Abort may already have errored the reader.
    }

    let exists = true;
    const cleanupDeadline = Date.now() + 5_000;
    while (Date.now() < cleanupDeadline) {
      try {
        await Deno.stat(cwd);
        await new Promise((r) => setTimeout(r, 50));
      } catch {
        exists = false;
        break;
      }
    }
    assertEquals(exists, false);
  } finally {
    abort.abort();
    await stopHarness(h);
  }
});

Deno.test("stdin failure cannot be masked by child success", async () => {
  const h = await startHarness({ AGY_EARLY_SUCCESS: "1" });
  try {
    const res = await chat(h, {
      model: "gemini-2.5-pro",
      messages: [{ role: "user", content: "x".repeat(2 * 1024 * 1024) }],
    });
    assertEquals(res.status, 502);
    const body = await res.json();
    assertStringIncludes(body.error?.message, "stdin");
  } finally {
    await stopHarness(h);
  }
});

Deno.test("AGY_REUSE does not continue when attachment bytes changed", async () => {
  const h = await startHarness({ AGY_REUSE: "on" });
  try {
    const first = await chat(h, {
      model: "gemini-2.5-pro",
      messages: [{
        role: "user",
        content: [{
          type: "image_url",
          image_url: { url: "data:text/plain;base64,YQ==" },
        }],
      }],
    });
    assertEquals(first.status, 200);

    const second = await chat(h, {
      model: "gemini-2.5-pro",
      messages: [
        {
          role: "user",
          content: [{
            type: "image_url",
            image_url: { url: "data:text/plain;base64,Yg==" },
          }],
        },
        { role: "user", content: "next" },
      ],
    });
    assertEquals(second.status, 200);

    const args = (await Deno.readTextFile(`${h.stateDir}/args`)).trim().split(
      "\n",
    );
    assertEquals(args.length, 2);
    assertEquals(args[1].includes("--conversation"), false);
  } finally {
    await stopHarness(h);
  }
});
