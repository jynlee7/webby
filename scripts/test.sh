#!/usr/bin/env bash
# Run the Swift test suite. With only the Command Line Tools installed (no Xcode),
# the Swift Testing framework lives outside the default search path, so point at it.
set -euo pipefail
cd "$(dirname "$0")/../mac"

args=()
clt_frameworks="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools* && -d "$clt_frameworks/Testing.framework" ]]; then
  args+=(-Xswiftc -F -Xswiftc "$clt_frameworks" -Xlinker -rpath -Xlinker "$clt_frameworks")
fi

swift test "${args[@]}" "$@"
