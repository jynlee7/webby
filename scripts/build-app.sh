#!/usr/bin/env bash
# Build Webby.app (release) into dist/ and ad-hoc sign it.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/mac"

swift build -c release --product Webby
swift build -c release --product webby-bridge
bin="$(swift build -c release --show-bin-path)"

app="$root/dist/Webby.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp "$bin/Webby" "$app/Contents/MacOS/Webby"
cp "$bin/webby-bridge" "$app/Contents/MacOS/webby-bridge"

for skin in webby.clear webby.mono; do
  if [[ ! -f "Resources/Skins/$skin/skin.json" ]]; then
    echo "Missing built-in skin manifest: Resources/Skins/$skin/skin.json" >&2
    exit 1
  fi
done
cp -R Resources/Skins "$app/Contents/Resources/Skins"

# Ad-hoc signature: enough to run locally; not notarized.
codesign --force --sign - "$app/Contents/MacOS/webby-bridge"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
echo "Built $app"
