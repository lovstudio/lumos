#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"

swift test
Scripts/verify-assertions.sh
Scripts/verify-process-tree.sh
.build/debug/lumos-spike system-state
.build/debug/lumos-spike network
.build/debug/lumos-spike display-brightness

print -- "PASS non-disruptive Spike suite"
print -- "Opt-in visible test: .build/debug/lumos-spike display-sleep-now --confirmed"
print -- "Root permission probe is documented, but intentionally excluded from routine runs."

