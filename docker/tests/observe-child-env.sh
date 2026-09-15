#!/usr/bin/env bash
set -euo pipefail

result_file="${1:?result file is required}"
first_fragment="${2:?first command fragment is required}"
second_fragment="${3:?second command fragment is required}"
env_name="${4:?environment variable name is required}"
env_value="${5:?environment variable value is required}"
timeout_seconds="${6:-30}"

[[ "$timeout_seconds" =~ ^[0-9]+$ ]] || {
  echo "invalid timeout: $timeout_seconds" >&2
  exit 64
}

printf 'READY\n' > "$result_file"
deadline=$((SECONDS + timeout_seconds))

while (( SECONDS <= deadline )); do
  for proc in /proc/[0-9]*; do
    [[ "$proc" == "/proc/$$" ]] && continue
    [[ -r "$proc/cmdline" ]] || continue
    cmd="$(tr '\000' ' ' < "$proc/cmdline" 2>/dev/null || true)"
    [[ "$cmd" == *"$first_fragment"* ]] || continue
    [[ "$cmd" == *"$second_fragment"* ]] || continue

    # Read the whole environment before matching: read errors and a vanished
    # child are not evidence of absence, and grep -q can SIGPIPE its producer.
    if ! child_env="$(tr '\000' '\n' < "$proc/environ" 2>/dev/null)"; then
      printf 'INCONCLUSIVE\n' >> "$result_file"
      exit 4
    fi
    current_cmd="$(tr '\000' ' ' < "$proc/cmdline" 2>/dev/null || true)"
    if [[ -z "$current_cmd" || "$current_cmd" != "$cmd" ]]; then
      printf 'INCONCLUSIVE\n' >> "$result_file"
      exit 4
    fi
    if grep -Fxq -- "$env_name=$env_value" <<< "$child_env"; then
      printf 'CANARY_PRESENT\n' >> "$result_file"
    else
      printf 'CANARY_ABSENT\n' >> "$result_file"
    fi
    exit 0
  done
  sleep 0.01
done

printf 'TIMEOUT\n' >> "$result_file"
exit 3
