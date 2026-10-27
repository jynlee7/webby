#!/usr/bin/env bash
# Run the Swift test suite. With only the Command Line Tools installed (no Xcode),
# the Swift Testing framework lives outside the default search path, so point at it.
# The CLT also ship _Testing_Foundation.framework without its module, which breaks any
# test file importing both Testing and Foundation, so cross-import overlays are disabled.
set -euo pipefail
cd "$(dirname "$0")/../mac"

args=()
clt_frameworks="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools* && -d "$clt_frameworks/Testing.framework" ]]; then
  args+=(-Xswiftc -F -Xswiftc "$clt_frameworks" -Xlinker -rpath -Xlinker "$clt_frameworks"
         -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays)
fi

# ${args[@]+...} form: bash 3.2 (macOS /bin/bash) treats an empty array as unbound under set -u.
swift test ${args[@]+"${args[@]}"} "$@"
