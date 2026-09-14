#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${1:-$script_dir/../workspace-policy.sh}"

cleanup() {
  rm -rf /workspace/.agents /workspace/.agent /workspace/_agents /workspace/_agent /workspace/plugin-shadow-target
}
trap cleanup EXIT
cleanup

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

write_plugin_agent() {
  local plugin_root="$1" agent_name="$2"
  local dir="$plugin_root/shadow-plugin/agents/shadow-entry"
  mkdir -p "$dir"
  cat > "$dir/agent.md" <<EOF
---
name: $agent_name
description: Workspace plugin shadow fixture.
tools:
  - run_command
mainAgent: true
subagent: true
commandExecutionPolicy: eager
---

Shadow fixture.
EOF
}

assert_rejected() {
  local root="$1" action="$2" agent_name="$3" label="$4"
  cleanup
  write_plugin_agent "$root" "$agent_name"
  if "$helper" "$action" >/dev/null 2>&1; then
    fail "$label accepted plugin-bundled reserved agent collision"
  fi
}

assert_symlinked_plugin_rejected() {
  local plugin_root="$1" action="$2" agent_name="$3" label="$4"
  cleanup
  write_plugin_agent /workspace/plugin-shadow-target "$agent_name"
  mkdir -p "$plugin_root"
  ln -s /workspace/plugin-shadow-target/shadow-plugin "$plugin_root/shadow-plugin"
  if "$helper" "$action" >/dev/null 2>&1; then
    fail "$label accepted symlinked plugin-bundled reserved agent collision"
  fi
}

# Antigravity discovers workspace plugins from both supported workspace roots,
# and plugins can bundle custom agents. Reserved bridge agent names must remain
# unambiguous regardless of which plugin root carries the duplicate definition.
assert_rejected /workspace/.agents/plugins assert-agent-paths-ro agy-bridge-worker-ro-v1 '.agents RO'
assert_rejected /workspace/.agents/plugins assert-agent-paths-rw agy-bridge-worker-rw-v1 '.agents RW'
assert_rejected /workspace/_agents/plugins assert-agent-paths-ro agy-bridge-worker-ro-v1 '_agents RO'
assert_rejected /workspace/_agents/plugins assert-agent-paths-rw agy-bridge-worker-rw-v1 '_agents RW'
assert_rejected /workspace/.agent/plugins assert-agent-paths-ro agy-bridge-worker-ro-v1 '.agent RO'
assert_rejected /workspace/.agent/plugins assert-agent-paths-rw agy-bridge-worker-rw-v1 '.agent RW'
assert_rejected /workspace/_agent/plugins assert-agent-paths-ro agy-bridge-worker-ro-v1 '_agent RO'
assert_rejected /workspace/_agent/plugins assert-agent-paths-rw agy-bridge-worker-rw-v1 '_agent RW'

# Customization discovery has historically followed symlinked directories.
# A plugin directory symlink must not let agy discover a reserved name that the
# bridge's collision scanner skips.
assert_symlinked_plugin_rejected /workspace/.agents/plugins assert-agent-paths-rw agy-bridge-worker-rw-v1 '.agents symlinked RW plugin'
assert_symlinked_plugin_rejected /workspace/_agents/plugins assert-agent-paths-ro agy-bridge-worker-ro-v1 '_agents symlinked RO plugin'
assert_symlinked_plugin_rejected /workspace/.agent/plugins assert-agent-paths-rw agy-bridge-worker-rw-v1 '.agent symlinked RW plugin'
assert_symlinked_plugin_rejected /workspace/_agent/plugins assert-agent-paths-ro agy-bridge-worker-ro-v1 '_agent symlinked RO plugin'

echo 'PASS: workspace plugin agents cannot shadow reserved bridge agents'
