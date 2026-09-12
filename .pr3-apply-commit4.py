from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    s = p.read_text()
    if old not in s:
        raise SystemExit(f"expected block not found in {path}: {old[:80]!r}")
    p.write_text(s.replace(old, new, 1))

# agy-bridge.ts: transactional workspace policy; hold policy until workspace
# child reaches terminal status, including hard-deadline SIGKILL escalation.
replace_once(
    "agy-bridge.ts",
    'const WORKSPACE_AGENT = "agy-bridge-worker-ro-v1";\n',
    'const WORKSPACE_AGENT = "agy-bridge-worker-ro-v1";\nconst WORKSPACE_POLICY_HELPER = "/app/docker/workspace-policy.sh";\n',
)
replace_once(
    "agy-bridge.ts",
    '''interface AgyExecutionContext {\n  cwd?: string;\n  workspaceReadOnly?: boolean;\n}\n\nasync function runAgy(\n''',
    '''interface AgyExecutionContext {\n  cwd?: string;\n  workspaceReadOnly?: boolean;\n}\n\nasync function runWorkspacePolicy(action: "apply-ro" | "restore"): Promise<void> {\n  const child = new Deno.Command(WORKSPACE_POLICY_HELPER, {\n    args: [action],\n    stdout: "piped",\n    stderr: "piped",\n    stdin: "null",\n    env: childEnv(),\n    clearEnv: true,\n  }).spawn();\n  const [stdout, stderr, status] = await Promise.all([\n    new Response(child.stdout).text(),\n    new Response(child.stderr).text(),\n    child.status,\n  ]);\n  if (!status.success) {\n    const detail = stderr.trim() || stdout.trim() || `exit code ${status.code}`;\n    throw new Error(`${action} failed: ${detail}`);\n  }\n}\n\nasync function runAgy(\n''',
)
replace_once(
    "agy-bridge.ts",
    '''  let watchdog: ReturnType<typeof setTimeout> | null = null;\n  let onAbort: (() => void) | null = null;\n  let abortListenerAdded = false;\n\n  try {\n    const args = [\n''',
    '''  let watchdog: ReturnType<typeof setTimeout> | null = null;\n  let onAbort: (() => void) | null = null;\n  let abortListenerAdded = false;\n  let workspacePolicyApplied = false;\n  let workspaceChildStatus: Promise<Deno.CommandStatus> | null = null;\n  let workspaceChildKill: (() => void) | null = null;\n\n  try {\n    if (execution.workspaceReadOnly) {\n      await runWorkspacePolicy("apply-ro");\n      workspacePolicyApplied = true;\n    }\n    const args = [\n''',
)
replace_once(
    "agy-bridge.ts",
    '''    const stderrText = new Response(child.stderr).text().catch(() => "");\n    const statusPromise = child.status;\n    let exited = false;\n''',
    '''    const stderrText = new Response(child.stderr).text().catch(() => "");\n    const statusPromise = child.status;\n    if (execution.workspaceReadOnly) workspaceChildStatus = statusPromise;\n    let exited = false;\n''',
)
replace_once(
    "agy-bridge.ts",
    '''      if (escalateTimer === null) {\n        // This timer intentionally survives runAgy's outer finally. A child\n        // that ignores SIGTERM still needs SIGKILL after the request gate is\n        // released; child.status owns cancellation when the process exits.\n''',
    '''      if (escalateTimer === null) {\n        // Default runs may release their request gate before this escalation.\n        // Workspace runs wait for child.status before restoring policy and\n        // releasing the concurrency slot.\n''',
)
replace_once(
    "agy-bridge.ts",
    '''    };\n\n    let resolveAbort: ((value: "aborted") => void) | null = null;\n''',
    '''    };\n    if (execution.workspaceReadOnly) workspaceChildKill = killHard;\n\n    let resolveAbort: ((value: "aborted") => void) | null = null;\n''',
)
replace_once(
    "agy-bridge.ts",
    '''    if (signal && onAbort && abortListenerAdded) {\n      signal.removeEventListener("abort", onAbort);\n    }\n    release();\n''',
    '''    if (signal && onAbort && abortListenerAdded) {\n      signal.removeEventListener("abort", onAbort);\n    }\n    if (workspacePolicyApplied && workspaceChildStatus) {\n      workspaceChildKill?.();\n      try {\n        await workspaceChildStatus;\n      } catch {\n        // The containment invariant needs terminal process state, not a\n        // successful exit code. runAgy records the actual request failure.\n      }\n    }\n    if (workspacePolicyApplied) {\n      try {\n        await runWorkspacePolicy("restore");\n      } catch (e) {\n        result.ok = false;\n        result.text = "";\n        result.error = `workspace policy restore failed: ${\n          e instanceof Error ? e.message : String(e)\n        }`;\n        console.error("workspace policy restore failed");\n      }\n    }\n    release();\n''',
)

# Runtime image/startup.
replace_once("Dockerfile", "      gnome-keyring \\\n", "      gnome-keyring \\\n      jq \\\n")
replace_once(
    "docker/start-bridge.sh",
    'AGY_SECRETS_DIR="${AGY_SECRETS_DIR:-/home/agy/.local/share/agy-secrets}"\n',
    'AGY_SECRETS_DIR="${AGY_SECRETS_DIR:-/home/agy/.local/share/agy-secrets}"\nSTATE_DIR="${STATE_DIR:-/home/agy/.local/state/agy-bridge}"\n',
)
replace_once(
    "docker/start-bridge.sh",
    'export KEYRING_PASSWORD_FILE="$keyring_password_file"\n\nworkspace_enabled=false\n',
    'export KEYRING_PASSWORD_FILE="$keyring_password_file"\nexport STATE_DIR\n\n# Recover a transaction left behind by an abrupt prior workspace run. This is\n# also required when returning to the default no-workspace deployment.\n/app/docker/workspace-policy.sh restore-if-needed\n\nworkspace_enabled=false\n',
)
replace_once(
    "docker/start-bridge.sh",
    '--allow-run="$AGY_BIN" \\\n',
    '--allow-run="$AGY_BIN,/app/docker/workspace-policy.sh" \\\n',
)

# fake agy failure/deadline fixtures.
replace_once(
    "docker/tests/fake-agy.sh",
    '''input="$(cat || true)"\nprintf '%s\\n' "$input" > "$capture_file"\nprintf '%s\\n' '{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"fake reply"}}'\n''',
    '''input="$(cat || true)"\nprintf '%s\\n' "$input" > "$capture_file"\n\nif [[ "$input" == *'FAKE_CHILD_FAILURE'* ]]; then\n  printf '%s\\n' '{"event":"result","result":{"status":"ERROR","error":"fake child failure","conversation_id":"fake-conversation"}}'\n  exit 1\nfi\n\nif [[ "$input" == *'FAKE_HANG'* ]]; then\n  trap '' TERM\n  sleep 30\n  exit 1\nfi\n\nprintf '%s\\n' '{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"fake reply"}}'\n''',
)

# deterministic bridge tests: exact helper permission + restore on success,
# child failure, and hard deadline where fake child ignores SIGTERM.
p = Path("docker/tests/test-bridge.sh")
s = p.read_text()
if s.count('--allow-run="$AGY_BIN" \\\n') != 2:
    raise SystemExit("expected exactly two test bridge --allow-run sites")
s = s.replace('--allow-run="$AGY_BIN" \\\n', '--allow-run="$AGY_BIN,/app/docker/workspace-policy.sh" \\\n')
needle = '''assert_eq "$count_after" "$count_before"\nstop_bridge\n\necho "PASS: bridge default regression and explicit read-only workspace runtime"\n'''
replacement = '''assert_eq "$count_after" "$count_before"\n[[ ! -e "$STATE_DIR/workspace-policy-backup.json" ]] || fail "workspace policy backup remained after successful request"\n\n# A child-side failure must still restore the policy transaction.\ncode="$(curl -sS -o "$work/child-failure.json" -w '%{http_code}' \\\n  -H 'content-type: application/json' \\\n  -H "Authorization: Bearer $AGY_TOKEN" \\\n  -d '{"model":"auto-ro-gemini-test","messages":[{"role":"user","content":"FAKE_CHILD_FAILURE"}]}' \\\n  http://127.0.0.1:17422/v1/chat/completions)"\nassert_eq "$code" 502\n[[ ! -e "$STATE_DIR/workspace-policy-backup.json" ]] || fail "workspace policy backup remained after child failure"\nstop_bridge\n\n# A hard-deadline path uses a fake child that ignores SIGTERM. The bridge must\n# wait for terminal child status (SIGKILL escalation) before restoring policy.\nexport PRINT_TIMEOUT=1ms\nexport AGY_HARD_MARGIN_MS=50\nstart_bridge 17423\ncode="$(curl -sS -o "$work/hard-deadline.json" -w '%{http_code}' \\\n  -H 'content-type: application/json' \\\n  -H "Authorization: Bearer $AGY_TOKEN" \\\n  -d '{"model":"auto-ro-gemini-test","messages":[{"role":"user","content":"FAKE_HANG"}]}' \\\n  http://127.0.0.1:17423/v1/chat/completions)"\nassert_eq "$code" 502\n[[ ! -e "$STATE_DIR/workspace-policy-backup.json" ]] || fail "workspace policy backup remained after hard deadline"\nstop_bridge\nunset PRINT_TIMEOUT AGY_HARD_MARGIN_MS\n\necho "PASS: bridge default regression and explicit read-only workspace runtime"\n'''
if needle not in s:
    raise SystemExit("test-bridge tail anchor missing")
p.write_text(s.replace(needle, replacement, 1))

replace_once(
    "docker/tests/run.sh",
    "bash /app/docker/tests/test-keyring.sh\n",
    "bash /app/docker/tests/test-keyring.sh\nbash /app/docker/tests/test-workspace-policy.sh /app/docker/workspace-policy.sh\n",
)
replace_once(
    "docker/tests/run.sh",
    "bash /app/docker/tests/check-runagy-lifecycle.sh /app/agy-bridge.ts\n",
    "bash /app/docker/tests/check-runagy-lifecycle.sh /app/agy-bridge.ts\nbash /app/docker/tests/check-workspace-runagy-lifecycle.sh /app/agy-bridge.ts\n",
)
replace_once(
    "docker/tests/check-runtime-permissions.sh",
    '''grep -F -- '--allow-read="$HOME/.gemini/antigravity-cli/brain"' "$file" >/dev/null || {\n  echo 'missing scoped transcript read permission' >&2\n  exit 1\n}\n''',
    '''grep -F -- '--allow-read="$HOME/.gemini/antigravity-cli/brain"' "$file" >/dev/null || {\n  echo 'missing scoped transcript read permission' >&2\n  exit 1\n}\ngrep -F -- '/app/docker/workspace-policy.sh' "$file" >/dev/null || {\n  echo 'missing exact workspace policy helper run permission' >&2\n  exit 1\n}\n''',
)

# Stage files are blobs committed only on this temporary branch. Copy them to
# production paths; the final clean commit excludes .pr3-stage entirely.
for src, dst in [
    (".pr3-stage/workspace-policy.sh", "docker/workspace-policy.sh"),
    (".pr3-stage/test-workspace-policy.sh", "docker/tests/test-workspace-policy.sh"),
    (".pr3-stage/check-workspace-runagy-lifecycle.sh", "docker/tests/check-workspace-runagy-lifecycle.sh"),
]:
    data = Path(src).read_bytes()
    q = Path(dst)
    q.parent.mkdir(parents=True, exist_ok=True)
    q.write_bytes(data)
    q.chmod(0o755)
