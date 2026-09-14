#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${1:-$script_dir/../workspace-policy.sh}"

cleanup() {
  rm -rf /workspace/.agents /workspace/_agents
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

# Workspace plugins can also carry hooks.json. Reject those command surfaces as
# part of the same fail-closed customization boundary.
assert_rejected /workspace/.agents/plugins/shadow-plugin/hooks.json assert-agent-paths-ro 'RO plugin hook'
assert_rejected /workspace/.agents/plugins/shadow-plugin/hooks.json assert-agent-paths-rw 'RW plugin hook'
assert_rejected /workspace/_agents/plugins/shadow-plugin/hooks.json assert-agent-paths-rw 'RW alternate plugin hook'

echo 'PASS: explicit workspace modes reject workspace command hooks'
