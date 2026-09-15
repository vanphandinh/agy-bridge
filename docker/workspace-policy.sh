#!/usr/bin/env bash
set -euo pipefail
umask 077

action="${1:-}"
settings_file="$HOME/.gemini/antigravity-cli/settings.json"
backup_file="$STATE_DIR/workspace-policy-backup.json"
settings_dir="$(dirname "$settings_file")"
backup_dir="$(dirname "$backup_file")"
managed_keys='["allowNonWorkspaceAccess","trustedWorkspaces","toolPermission","permissions"]'

fail() {
  echo "workspace policy: $*" >&2
  exit 1
}

frontmatter_has_name() {
  local file="$1" target="$2"
  awk -v target="$target" '
    { sub(/\r$/, "") }
    NR == 1 && $0 == "---" { in_frontmatter=1; next }
    in_frontmatter && $0 == "---" { exit }
    in_frontmatter && $0 ~ /^[[:space:]]*name[[:space:]]*:/ {
      value=$0
      sub(/^[[:space:]]*name[[:space:]]*:[[:space:]]*/, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if (value == target || value == "\"" target "\"" || value == "\047" target "\047") {
        found=1
        exit
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

assert_workspace_hooks_absent() {
  local customization_root hook_path plugin_config plugin_root
  for customization_root in \
    /workspace/.agents \
    /workspace/.agent \
    /workspace/_agents \
    /workspace/_agent; do
    [[ ! -L "$customization_root" ]] || fail "workspace customization root must not be a symlink: $customization_root"
    plugin_config="$customization_root/plugins.json"
    if [[ -e "$plugin_config" || -L "$plugin_config" ]]; then
      fail "workspace declared plugin configs are not allowed in explicit workspace mode: $plugin_config"
    fi
  done

  for hook_path in \
    /workspace/.agents/hooks.json \
    /workspace/.agent/hooks.json \
    /workspace/_agents/hooks.json \
    /workspace/_agent/hooks.json; do
    if [[ -e "$hook_path" || -L "$hook_path" ]]; then
      fail "workspace hooks are not allowed in explicit workspace mode: $hook_path"
    fi
  done

  for plugin_root in \
    /workspace/.agents/plugins \
    /workspace/.agent/plugins \
    /workspace/_agents/plugins \
    /workspace/_agent/plugins; do
    [[ ! -L "$plugin_root" ]] || fail "workspace plugin root must not be a symlink: $plugin_root"
    [[ -d "$plugin_root" ]] || continue
    if find "$plugin_root" -type l -print -quit | grep -q .; then
      fail "workspace plugin tree must not contain symlinks: $plugin_root"
    fi
    if find "$plugin_root" -name hooks.json \( -type f -o -type l \) -print -quit | grep -q .; then
      fail "workspace plugin hooks are not allowed in explicit workspace mode: $plugin_root"
    fi
  done
}

assert_plugin_agent_names() {
  local mode="$1"
  local reserved=(agy-bridge-worker-ro-v1)
  if [[ "$mode" == "rw" ]]; then
    reserved+=(agy-bridge-worker-rw-v1)
  fi

  local plugin_root agent_file name
  for plugin_root in \
    /workspace/.agents/plugins \
    /workspace/.agent/plugins \
    /workspace/_agents/plugins \
    /workspace/_agent/plugins; do
    [[ ! -L "$plugin_root" ]] || fail "workspace plugin root must not be a symlink: $plugin_root"
    [[ -d "$plugin_root" ]] || continue

    if find "$plugin_root" -path '*/agents/*' -type l -print -quit | grep -q .; then
      fail "workspace plugin agent definitions must not contain symlinks: $plugin_root"
    fi

    while IFS= read -r -d '' agent_file; do
      for name in "${reserved[@]}"; do
        if frontmatter_has_name "$agent_file" "$name"; then
          fail "reserved workspace plugin agent collision: $agent_file ($name)"
        fi
      done
    done < <(find "$plugin_root" -path '*/agents/*' -type f -name '*.md' -print0)
  done
}

assert_agent_paths() {
  local mode="$1"
  local reserved=(agy-bridge-worker-ro-v1)
  if [[ "$mode" == "rw" ]]; then
    reserved+=(agy-bridge-worker-rw-v1)
  fi

  local root name path
  for root in .agents .agent _agents _agent; do
    for name in "${reserved[@]}"; do
      for path in \
        "/workspace/$root/agents/$name.md" \
        "/workspace/$root/agents/$name/agent.md"; do
        if [[ -e "$path" || -L "$path" ]]; then
          fail "reserved workspace agent collision: $path"
        fi
      done
    done
  done
  assert_workspace_hooks_absent
  assert_plugin_agent_names "$mode"
}

read_settings() {
  if [[ -f "$settings_file" ]]; then
    jq -e 'type == "object"' "$settings_file" >/dev/null 2>&1 || fail "settings.json is not a valid JSON object"
    cat "$settings_file"
  else
    printf '{}\n'
  fi
}

atomic_json_write() {
  local target="$1" input="$2" dir tmp
  dir="$(dirname "$target")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.workspace-policy.XXXXXX")"
  trap 'rm -f "${tmp:-}"' RETURN
  printf '%s\n' "$input" > "$tmp"
  jq -e . "$tmp" >/dev/null 2>&1 || fail "refusing to write invalid JSON"
  mv -f "$tmp" "$target"
  trap - RETURN
}

apply_policy() {
  local mode="$1" allow trusted_workspaces extra_deny
  case "$mode" in
    none)
      allow='[]'
      trusted_workspaces='[]'
      extra_deny='[
        "read_file(/workspace)",
        "write_file(/workspace)"
      ]'
      ;;
    ro)
      allow='["read_file(/workspace)"]'
      trusted_workspaces='["/workspace"]'
      extra_deny='[]'
      ;;
    rw)
      allow='["read_file(/workspace)","write_file(/workspace)"]'
      trusted_workspaces='["/workspace"]'
      extra_deny='[
        "write_file(/workspace/.agents/agents/agy-bridge-worker-ro-v1.md)",
        "write_file(/workspace/.agents/agents/agy-bridge-worker-ro-v1/agent.md)",
        "write_file(/workspace/.agents/agents/agy-bridge-worker-rw-v1.md)",
        "write_file(/workspace/.agents/agents/agy-bridge-worker-rw-v1/agent.md)",
        "write_file(/workspace/.agent/agents/agy-bridge-worker-ro-v1.md)",
        "write_file(/workspace/.agent/agents/agy-bridge-worker-ro-v1/agent.md)",
        "write_file(/workspace/.agent/agents/agy-bridge-worker-rw-v1.md)",
        "write_file(/workspace/.agent/agents/agy-bridge-worker-rw-v1/agent.md)",
        "write_file(/workspace/_agents/agents/agy-bridge-worker-ro-v1.md)",
        "write_file(/workspace/_agents/agents/agy-bridge-worker-ro-v1/agent.md)",
        "write_file(/workspace/_agents/agents/agy-bridge-worker-rw-v1.md)",
        "write_file(/workspace/_agents/agents/agy-bridge-worker-rw-v1/agent.md)",
        "write_file(/workspace/_agent/agents/agy-bridge-worker-ro-v1.md)",
        "write_file(/workspace/_agent/agents/agy-bridge-worker-ro-v1/agent.md)",
        "write_file(/workspace/_agent/agents/agy-bridge-worker-rw-v1.md)",
        "write_file(/workspace/_agent/agents/agy-bridge-worker-rw-v1/agent.md)"
      ]'
      ;;
    *)
      fail "unsupported workspace policy mode: $mode"
      ;;
  esac

  [[ ! -e "$backup_file" ]] || fail "backup already exists; refusing nested policy transaction"
  mkdir -p "$settings_dir" "$backup_dir"

  local settings backup updated settings_present
  settings="$(read_settings)"
  if [[ -f "$settings_file" ]]; then settings_present=true; else settings_present=false; fi

  backup="$(jq -cn \
    --argjson settings "$settings" \
    --argjson keys "$managed_keys" \
    --argjson settings_present "$settings_present" '
      {
        version: 1,
        settingsFilePresent: $settings_present,
        managed: (reduce $keys[] as $k ({};
          .[$k] = {
            present: ($settings | has($k)),
            value: (if ($settings | has($k)) then $settings[$k] else null end)
          }
        ))
      }
    ')"
  atomic_json_write "$backup_file" "$backup"

  updated="$(jq --argjson allow "$allow" --argjson trusted_workspaces "$trusted_workspaces" --argjson extra_deny "$extra_deny" '
    .allowNonWorkspaceAccess = false
    | .trustedWorkspaces = $trusted_workspaces
    | .toolPermission = "request-review"
    | .permissions = {
        allow: $allow,
        deny: ($extra_deny + [
          "read_file(/app)",
          "write_file(/app)",
          "read_file(/home/agy/.gemini)",
          "write_file(/home/agy/.gemini)",
          "read_file(/home/agy/.local/share/agy-secrets)",
          "write_file(/home/agy/.local/share/agy-secrets)",
          "read_file(/home/agy/.local/share/keyrings)",
          "write_file(/home/agy/.local/share/keyrings)",
          "read_file(/home/agy/.local/state/agy-bridge)",
          "write_file(/home/agy/.local/state/agy-bridge)"
        ])
      }
  ' <<<"$settings")"
  atomic_json_write "$settings_file" "$updated"
}

restore_policy() {
  [[ -f "$backup_file" ]] || fail "backup missing"
  jq -e \
    --argjson keys "$managed_keys" '
      . as $backup
      | .version == 1
        and (.settingsFilePresent | type == "boolean")
        and (.managed | type == "object")
        and all($keys[]; . as $k |
          ($backup.managed | has($k))
          and ($backup.managed[$k].present | type == "boolean")
          and ($backup.managed[$k] | has("value"))
        )
    ' "$backup_file" >/dev/null 2>&1 || fail "backup is corrupt; leaving it in place"

  local settings restored
  settings="$(read_settings)"
  restored="$(jq \
    --slurpfile backup "$backup_file" \
    --argjson keys "$managed_keys" '
      reduce $keys[] as $k (.;
        if $backup[0].managed[$k].present
        then .[$k] = $backup[0].managed[$k].value
        else del(.[$k])
        end
      )
    ' <<<"$settings")"
  atomic_json_write "$settings_file" "$restored"

  if [[ "$(jq -r '.settingsFilePresent' "$backup_file")" == "false" ]] && \
     jq -e 'keys | length == 0' "$settings_file" >/dev/null 2>&1; then
    rm -f "$settings_file"
  fi
  rm -f "$backup_file"
}

case "$action" in
  assert-agent-paths-ro)
    assert_agent_paths ro
    ;;
  assert-agent-paths-rw)
    assert_agent_paths rw
    ;;
  apply-none)
    apply_policy none
    ;;
  apply-ro)
    apply_policy ro
    ;;
  apply-rw)
    apply_policy rw
    ;;
  restore)
    restore_policy
    ;;
  restore-if-needed)
    if [[ -e "$backup_file" ]]; then restore_policy; fi
    ;;
  *)
    fail "usage: $0 {assert-agent-paths-ro|assert-agent-paths-rw|apply-none|apply-ro|apply-rw|restore|restore-if-needed}"
    ;;
esac
