#!/usr/bin/env bash
set -euo pipefail

helper="${1:-/app/docker/tests/observe-child-env.sh}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$helper" ]] || fail "missing child environment observer helper: $helper"

wait_ready() {
  local result="$1"
  local pid="$2"
  local i
  for i in $(seq 1 200); do
    if grep -Fx 'READY' "$result" >/dev/null 2>&1; then
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.01
  done
  fail "observer did not report READY"
}

run_case() {
  local expected="$1"
  local canary_value="$2"
  local result
  result="$(mktemp)"
  trap 'rm -f "$result"' RETURN

  bash "$helper" \
    "$result" \
    'observer-test-child' \
    '--agent raw' \
    'TEST_OBSERVER_CANARY' \
    'bridge-secret' \
    2 &
  local observer_pid=$!
  wait_ready "$result" "$observer_pid"

  if [[ -n "$canary_value" ]]; then
    TEST_OBSERVER_CANARY="$canary_value" \
      bash -c 'sleep 0.05; :' observer-test-child '--agent raw' &
  else
    env -u TEST_OBSERVER_CANARY \
      bash -c 'sleep 0.05; :' observer-test-child '--agent raw' &
  fi
  local child_pid=$!
  wait "$child_pid"

  wait "$observer_pid" || fail "observer exited non-zero for expected $expected"
  tail -n 1 "$result" | grep -Fx "$expected" >/dev/null || {
    cat "$result" >&2
    fail "observer returned the wrong environment verdict"
  }
  rm -f "$result"
  trap - RETURN
}

run_case 'CANARY_ABSENT' ''
run_case 'CANARY_PRESENT' 'bridge-secret'

echo 'PASS: pre-armed child environment observer catches short-lived children'
