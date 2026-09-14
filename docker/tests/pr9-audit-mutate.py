from pathlib import Path

fake = Path("docker/tests/fake-agy.sh")
text = fake.read_text()
old = """printf '%s\\n' "$input" > "$capture_file"

if [[ "$input" == *'FAKE_CREATE_RW_AGENT_COLLISION'* ]]; then
"""
new = """printf '%s\\n' "$input" > "$capture_file"

if [[ "$input" == *'FAKE_TOOL_STEP'* ]]; then
  printf '%s\\n' '{"event":"step_update","step_update":{"step_type":"tool","text_delta":"fake tool activity"}}'
fi

if [[ "$input" == *'FAKE_CREATE_RW_AGENT_COLLISION'* ]]; then
"""
assert text.count(old) == 1, "fake-agy anchor mismatch"
fake.write_text(text.replace(old, new))

test = Path("docker/tests/test-bridge.sh")
text = test.read_text()
old = """  -d '{"model":"auto-rw-gemini-test","reasoning_effort":"high","messages":[{"role":"user","content":"Modify the caller project."}]}' \\
  http://127.0.0.1:17424/v1/chat/completions)"
[[ "$workspace_rw" == *'fake reply'* ]] || fail "RW deployment auto-rw reply missing"
rw_args="$(cat "$HOME/fake-agy-args.txt")"
"""
new = """  -d '{"model":"auto-rw-gemini-test","reasoning_effort":"high","messages":[{"role":"user","content":"FAKE_TOOL_STEP Modify the caller project."}]}' \\
  http://127.0.0.1:17424/v1/chat/completions)"
[[ "$workspace_rw" == *'fake reply'* ]] || fail "RW deployment auto-rw reply missing"
latest_usage="$(tail -n 1 "$STATE_DIR/usage.jsonl")"
jq -e '
  .autonomous == "rw" and
  .agent == "agy-bridge-worker-rw-v1" and
  .tool_step_updates == 1
' <<<"$latest_usage" >/dev/null || fail "RW native tool-step evidence missing from usage log"
rw_args="$(cat "$HOME/fake-agy-args.txt")"
"""
assert text.count(old) == 1, "test-bridge anchor mismatch"
test.write_text(text.replace(old, new))

bridge = Path("agy-bridge.ts")
text = bridge.read_text()

old = """  const result: AgyResult = { ok: false, text: "" };
  let recoveredSalvage = false;
  let watchdog: ReturnType<typeof setTimeout> | null = null;
"""
new = """  const result: AgyResult = { ok: false, text: "" };
  let recoveredSalvage = false;
  let toolStepUpdates = 0;
  let watchdog: ReturnType<typeof setTimeout> | null = null;
"""
assert text.count(old) == 1, "runAgy counter anchor mismatch"
text = text.replace(old, new)

old = """        if (ev.event === "step_update") {
          const su = ev.step_update as Record<string, unknown>;
          if (typeof su.text_delta === "string" && su.text_delta !== "") {
"""
new = """        if (ev.event === "step_update") {
          const su = ev.step_update as Record<string, unknown>;
          if (su.step_type === "tool") toolStepUpdates++;
          if (typeof su.text_delta === "string" && su.text_delta !== "") {
"""
assert text.count(old) == 1, "step_update anchor mismatch"
text = text.replace(old, new)

old = """      tokens: result.usage,
      error: result.error,
"""
new = """      tokens: result.usage,
      tool_step_updates: toolStepUpdates,
      error: result.error,
"""
assert text.count(old) == 1, "usage anchor mismatch"
text = text.replace(old, new)
bridge.write_text(text)
