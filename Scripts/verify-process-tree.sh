#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
binary="$project_dir/.build/debug/lumos-spike"

if [[ ! -x "$binary" ]]; then
  swift build --package-path "$project_dir"
fi

/bin/zsh -c 'sleep 4 & wait' &
root_pid=$!
sleep 0.5

tree=$($binary process "$root_pid")
print -r -- "$tree"

if ! print -r -- "$tree" | jq -e --argjson root_pid "$root_pid" '
  .process.pid == $root_pid
  and (.descendants | length) >= 1
  and any(.descendants[]; .parentPID == $root_pid and .name == "sleep")
' >/dev/null; then
  print -u2 -- "process tree did not contain the expected zsh -> sleep edge"
  wait "$root_pid" || true
  exit 1
fi

wait "$root_pid"
print -- "PASS process tree: observed zsh $root_pid -> sleep"

