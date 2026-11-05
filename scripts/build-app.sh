#!/usr/bin/env bash
# Build Webby.app (release) into dist/ and sign it: with $WEBBY_SIGN_IDENTITY when set,
# ad hoc otherwise (as in CI). $WEBBY_BUILD_NUMBER, when set, becomes the staged bundle's
# CFBundleVersion; the tracked Info.plist is never rewritten.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/mac"

build_number="${WEBBY_BUILD_NUMBER:-}"
if [[ -n "$build_number" && ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "WEBBY_BUILD_NUMBER '$build_number' is not a positive integer" >&2
  exit 1
fi

swift build -c release --product Webby
swift build -c release --product webby-bridge
bin="$(swift build -c release --show-bin-path)"

app="$root/dist/Webby.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -n "$build_number" ]]; then
  plutil -replace CFBundleVersion -string "$build_number" "$app/Contents/Info.plist"
fi
cp "$bin/Webby" "$app/Contents/MacOS/Webby"
cp "$bin/webby-bridge" "$app/Contents/MacOS/webby-bridge"

for skin in webby.clear webby.mono; do
  if [[ ! -f "Resources/Skins/$skin/skin.json" ]]; then
    echo "Missing built-in skin manifest: Resources/Skins/$skin/skin.json" >&2
    exit 1
  fi
done
cp -R Resources/Skins "$app/Contents/Resources/Skins"

# The extension Settings → Chrome points Load unpacked at: the same stage as the
# standalone archive, copied flat (no wrapper folder) before signing.
"$root/scripts/package-extension.sh" --output-dir "$root/dist/package"
cp -R "$root/dist/package/Extension" "$app/Contents/Resources/Extension"

"$root/scripts/check-version-identifiers.sh" --plist "$app/Contents/Info.plist"
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")"

# An ad-hoc signature changes with every build, so macOS drops privacy grants such as
# Accessibility after each rebuild. A stable identity (an Apple Development or
# self-signed code-signing certificate) keeps them (plan.md §6.6). Not notarized.
identity="${WEBBY_SIGN_IDENTITY:--}"
codesign --force --sign "$identity" "$app/Contents/MacOS/webby-bridge"
codesign --force --sign "$identity" "$app"
codesign --verify --strict "$app"
if [[ "$identity" == "-" ]]; then
  echo "Built $app (ad hoc; run 'tccutil reset Accessibility $bundle_id' after rebuilding)"
  # Builds before 0.1.0 used this identifier; its grant does not carry over.
  echo "Upgrading from a build before 0.1.0? Also run 'tccutil reset Accessibility com.webby.app'"
else
  echo "Built $app (signed with $identity)"
fi
