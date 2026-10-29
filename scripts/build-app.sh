#!/usr/bin/env bash
# Build Webby.app (release) into dist/ and sign it: with $WEBBY_SIGN_IDENTITY when set,
# ad hoc otherwise (as in CI).
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

# An ad-hoc signature changes with every build, so macOS drops privacy grants such as
# Accessibility after each rebuild. A stable identity (an Apple Development or
# self-signed code-signing certificate) keeps them (plan.md §6.6). Not notarized.
identity="${WEBBY_SIGN_IDENTITY:--}"
codesign --force --sign "$identity" "$app/Contents/MacOS/webby-bridge"
codesign --force --sign "$identity" "$app"
codesign --verify --strict "$app"
if [[ "$identity" == "-" ]]; then
  echo "Built $app (ad hoc; run 'tccutil reset Accessibility com.webby.app' after rebuilding)"
else
  echo "Built $app (signed with $identity)"
fi
