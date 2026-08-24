#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
binary="$project_dir/.build/debug/lumos-spike"

if [[ ! -x "$binary" ]]; then
  swift build --package-path "$project_dir"
fi

verify_kind() {
  local kind=$1
  local assertion_name=$2
  local log_file
  log_file=$(mktemp -t lumos-spike.XXXXXX)

  "$binary" hold "$kind" 4 >"$log_file" &
  local probe_pid=$!
  sleep 1

  local during
  during=$(pmset -g assertions)
  if ! print -r -- "$during" | grep -F "pid $probe_pid(lumos-spike)" >/dev/null; then
    print -u2 -- "missing lumos-spike owner for $kind assertion"
    wait "$probe_pid" || true
    rm -f "$log_file"
    return 1
  fi
  if ! print -r -- "$during" | grep -F "$assertion_name" >/dev/null; then
    print -u2 -- "missing expected assertion name: $assertion_name"
    wait "$probe_pid" || true
    rm -f "$log_file"
    return 1
  fi

  wait "$probe_pid"
  local after
  after=$(pmset -g assertions)
  if print -r -- "$after" | grep -F "$assertion_name" >/dev/null; then
    print -u2 -- "assertion leaked after probe exit: $assertion_name"
    rm -f "$log_file"
    return 1
  fi

  print -- "PASS $kind: visible while held, absent after release"
  sed -n '1,2p' "$log_file"
  rm -f "$log_file"
}

verify_kind system "Lumos Spike System Idle Lease"
verify_kind display "Lumos Spike Display Idle Lease"

