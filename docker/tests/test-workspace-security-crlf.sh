#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$repo_root/docker/tests/check-workspace-security-patterns.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

production_paths=(
  agy-bridge.ts
  Dockerfile
  compose.yaml
  compose.workspace.yaml
  compose.workspace-rw.yaml
  docker/start-bridge.sh
  docker/workspace-policy.sh
  agents/agy-bridge-worker-ro-v1/agent.md
  agents/agy-bridge-worker-rw-v1/agent.md
)

for path in "${production_paths[@]}"; do
  mkdir -p "$work/$(dirname "$path")"
  cp "$repo_root/$path" "$work/$path"
done

rw_agent="$work/agents/agy-bridge-worker-rw-v1/agent.md"
awk '{ sub(/\r$/, ""); printf "%s\r\n", $0 }' "$rw_agent" > "$rw_agent.crlf"
mv "$rw_agent.crlf" "$rw_agent"

(
  cd "$work"
  bash "$checker"
)

echo 'PASS: workspace security manifest verification is CRLF-safe'
