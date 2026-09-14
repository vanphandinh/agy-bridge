#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${1:-$script_dir/../workspace-policy.sh}"

cleanup() {
  rm -rf /workspace/.agents /workspace/.agent /workspace/_agents /workspace/_agent \
    /workspace/customization-root-target
}
trap cleanup EXIT
cleanup

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

write_hook() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
{
  "bridge-escape-fixture": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "sh -c 'echo should-not-run > /tmp/workspace-hook-canary'"
          }
        ]
      }
    ]
  }
}
EOF
}

assert_rejected() {
  local hook_path="$1" action="$2" label="$3"
  cleanup
  write_hook "$hook_path"
  if "$helper" "$action" >/dev/null 2>&1; then
    fail "$label accepted workspace command hook configuration"
  fi
}

# Trusted workspaces can load .agents/hooks.json independently of a custom
# agent's declared tools. Explicit bridge workspace modes must therefore reject
# workspace command hooks before spawning agy.
assert_rejected /workspace/.agents/hooks.json assert-agent-paths-ro 'RO top-level hook'
assert_rejected /workspace/.agents/hooks.json assert-agent-paths-rw 'RW top-level hook'
assert_rejected /workspace/.agent/hooks.json assert-agent-paths-ro 'RO singular-dot top-level hook'
assert_rejected /workspace/_agent/hooks.json assert-agent-paths-rw 'RW singular-underscore top-level hook'

# Workspace plugins can also carry hooks.json. Reject those command surfaces as
# part of the same fail-closed customization boundary.
assert_rejected /workspace/.agents/plugins/shadow-plugin/hooks.json assert-agent-paths-ro 'RO plugin hook'
assert_rejected /workspace/.agents/plugins/shadow-plugin/hooks.json assert-agent-paths-rw 'RW plugin hook'
assert_rejected /workspace/_agents/plugins/shadow-plugin/hooks.json assert-agent-paths-rw 'RW alternate plugin hook'
assert_rejected /workspace/.agent/plugins/shadow-plugin/hooks.json assert-agent-paths-ro 'RO singular-dot plugin hook'
assert_rejected /workspace/_agent/plugins/shadow-plugin/hooks.json assert-agent-paths-rw 'RW singular-underscore plugin hook'

# Antigravity 1.2.2 also supports workspace plugins.json files whose entries or
# inherits can redirect discovery to plugin trees outside <root>/plugins. The
# bridge does not resolve that recursive config graph, so explicit workspace
# modes must reject the indirection fail-closed instead of scanning only the
# standard plugin directories.
for declared_plugin_config in \
  /workspace/.agents/plugins.json \
  /workspace/.agent/plugins.json \
  /workspace/_agents/plugins.json \
  /workspace/_agent/plugins.json; do
  cleanup
  mkdir -p "$(dirname "$declared_plugin_config")"
  printf '%s\n' '{"entries":[{"path":"../declared-plugins"}]}' > "$declared_plugin_config"
  if "$helper" assert-agent-paths-rw >/dev/null 2>&1; then
    fail "RW accepted declared plugin config: $declared_plugin_config"
  fi
done

# Reject indirection at the customization-root boundary itself. Otherwise an
# empty symlinked root passes the child-path scanners and leaves Antigravity to
# discover customization content outside the operator-selected workspace tree.
for customization_root in .agents .agent _agents _agent; do
  cleanup
  mkdir -p /workspace/customization-root-target
  ln -s /workspace/customization-root-target "/workspace/$customization_root"
  if "$helper" assert-agent-paths-rw >/dev/null 2>&1; then
    fail "RW accepted symlinked customization root: $customization_root"
  fi
done

echo 'PASS: explicit workspace modes reject workspace command hooks'
