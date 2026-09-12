from pathlib import Path
p = Path('docs/docker-compose.md')
s = p.read_text()
old = '''## Workspace and filesystem boundary

This Docker deployment does **not** mount or infer an HTTP caller's project
workspace.

`/app` contains the `agy-bridge` application source baked into the image. It is
not the caller's workspace, and the bridge does not infer a caller workspace
from `Deno.cwd()`.

The deployment does not automatically grant `read_file(/app)`,
`write_file(/app)`, or command permissions to turn `/app` into an implicit
workspace. Explicit host-workspace integration is intentionally out of scope
for this deployment.

'''
new = '''## Explicit read-only host workspace

The secure default remains workspace-free:

```powershell
docker compose up -d
```

With only `compose.yaml`, no host project is mounted, `/app` remains bridge
application code, and `auto-ro-*` / `auto-rw-*` retain their existing
non-host-workspace behavior. The bridge never infers a caller workspace from
`Deno.cwd()`.

PR #3 adds an **explicit, one-project, read-only** Docker override. On Windows
PowerShell, point `AGY_WORKSPACE_HOST_PATH` only at the intended project:

```powershell
$env:AGY_WORKSPACE_HOST_PATH = 'C:\\src\\project'

docker compose `
  -f compose.yaml `
  -f compose.workspace.yaml `
  up -d
```

Do not use `C:\\`, a user profile, Docker Desktop storage, or another broad
host path. The selected directory is mounted exactly at `/workspace` with a
Docker-enforced read-only bind. Only `agy-bridge` receives that mount; helper
services do not.

Workspace routing is deliberately asymmetric:

```text
auto-ro-* -> explicit /workspace read-only project access
auto-rw-* -> HTTP 403 before agy is spawned
ordinary/bare models -> no host workspace capability is implied
```

Workspace `auto-ro-*` runs with the reserved Docker read-only agent, child CWD
`/workspace`, a bridge-owned workspace contract, a strict child-environment
allowlist, and a transactional Antigravity read policy. The bridge itself does
not receive Deno read/write permission for `/workspace`.

### Exact `agy` version gate

Explicit workspace mode is fail-closed against unverified official `agy`
versions. `docker/workspace/verified-agy-versions.txt` contains only exact
semantic versions that have passed the full live workspace containment
verifier on the final candidate PR SHA.

An image rebuild may install a newer official CLI. Default no-workspace mode
continues to work, but workspace startup intentionally refuses that new version
until it passes the repository verifier and is explicitly added to the
allowlist. Do not add a version based only on unit, static, or Compose tests.

### Return to the default deployment

```powershell
docker compose -f compose.yaml -f compose.workspace.yaml down
docker compose up -d
```

Named OAuth/keyring/secrets/state volumes are retained. Startup also restores
any stale managed workspace-policy transaction before the normal OAuth/model
preflight.

'''
if old not in s:
    raise SystemExit('workspace docs section not found')
s = s.replace(old, new, 1)

old = '''A PowerShell helper additionally validates resolved Compose defaults and the
loopback-only security boundary:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\\docker\\tests\\test-compose.ps1
```

That PowerShell helper is a test convenience; it is not a runtime requirement.
'''
new = '''PowerShell helpers additionally validate resolved Compose defaults, the
loopback-only security boundary, and the explicit read-only workspace override:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\\docker\\tests\\test-compose.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\\docker\\tests\\test-compose-workspace.ps1
```

Those PowerShell helpers are test conveniences; they are not runtime
requirements.
'''
if old not in s:
    raise SystemExit('deterministic docs block not found')
s = s.replace(old, new, 1)

old = '''`docker/tests/verify-all.ps1` is the end-to-end acceptance helper for this
Docker deployment. It verifies repository/head identity, Docker and Compose
availability, build-context isolation, the deterministic suite, Deno lint and
tests, reset semantics, persisted OAuth, the production runtime identity,
HTTP auth/Host guards, official `agy` non-streaming and streaming calls,
autonomous routing smoke tests, bridge-state persistence, and OAuth/state
persistence across restart, down/up, recreation, rebuild, and a Docker Desktop
restart.
'''
new = '''`docker/tests/verify-all.ps1` is the end-to-end acceptance helper for this
Docker deployment. In addition to the PR #2 gates, it validates the explicit
workspace Compose boundary, requires the exact installed `agy` candidate to be
staged in the verified-version allowlist, proves workspace fixture reads,
proves host-project immutability, requires workspace `auto-rw-*` HTTP 403, and
checks non-workspace canaries including traversal attempts. It then returns to
the default deployment and re-runs the OAuth/state persistence transitions
across restart, down/up, recreation, rebuild, and a Docker Desktop restart.
'''
if old not in s:
    raise SystemExit('full verifier docs block not found')
s = s.replace(old, new, 1)

old = '''A full live acceptance run covers:

1. authenticated `GET /v1/models`;
2. one official-`agy` non-stream completion;
3. one official-`agy` streaming completion ending in `data: [DONE]`;
4. one non-filesystem `auto-ro-*` request;
5. one non-destructive `auto-rw-*` request;
6. OAuth persistence across restart, down/up, recreation, rebuild, and host
   Docker-runtime restart;
7. bridge-state persistence;
8. isolated `down -v` reset behavior.

This Docker deployment has been live-verified on a Windows x86_64 host with
Docker Desktop, including OAuth/state persistence across a Docker Desktop
restart. Other host environments should run the same acceptance gates before
being advertised as live-verified.
'''
new = '''A full live acceptance run covers:

1. authenticated `GET /v1/models` plus official-`agy` non-stream and streaming
   calls;
2. the exact official `agy` semantic version used for workspace mode;
3. `auto-ro-*` reading both disposable `/workspace` fixture files;
4. unchanged host hashes, timestamps, content, and directory entries after
   model mutation requests;
5. workspace `auto-rw-*` returning HTTP 403 without project mutation;
6. denial of harmless `/app`, bridge-state, agy-secrets, keyring, and traversal
   canaries;
7. Host/Bearer/loopback boundaries after returning to default mode;
8. OAuth/state persistence across restart, down/up, recreation, rebuild, and
   Docker Desktop restart;
9. bridge-state persistence and isolated `down -v` reset behavior.

The default Docker deployment has already been live-verified on a Windows
x86_64 Docker Desktop host for the PR #2 OAuth/persistence boundaries. Explicit
host-workspace support must **not** be advertised as live-verified until the
full PR #3 verifier passes without `-SkipLive` and without
`-SkipDockerRestart` on the final candidate SHA and the exact passing `agy`
version is retained in the allowlist.
'''
if old not in s:
    raise SystemExit('live coverage docs block not found')
s = s.replace(old, new, 1)

p.write_text(s)
