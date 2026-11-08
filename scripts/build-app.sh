#!/usr/bin/env bash
# Build Webby.app into dist/ and sign it with the hardened runtime and the empty
# mac/Resources/Webby.entitlements.
#
#   build-app.sh             Development: signs with $WEBBY_SIGN_IDENTITY when set, ad hoc
#                            otherwise (as in CI), and stages WebbyDevelopmentBuild=true so
#                            the app may register the Chrome bridge from any folder.
#   build-app.sh --release   Release: requires WEBBY_SIGN_IDENTITY naming a
#                            "Developer ID Application: … (TEAMID)" identity, a matching
#                            WEBBY_TEAM_ID and a numeric WEBBY_BUILD_NUMBER; adds a secure
#                            timestamp and builds arm64 + x86_64. Missing or ad hoc inputs,
#                            and an identity the keychain search list doesn't hold, fail
#                            before anything in dist/ is touched. Not notarized here.
#
# $WEBBY_BUILD_NUMBER, when set, becomes the staged bundle's CFBundleVersion; the tracked
# Info.plist is never rewritten. $WEBBY_ARCHS overrides the architectures (default: this
# Mac's for development, "arm64 x86_64" for release).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

release=0
case "${1:-}" in
  "") ;;
  --release) release=1 ;;
  *) echo "usage: $0 [--release]" >&2; exit 2 ;;
esac

refuse() {
  echo "build-app: $*" >&2
  exit 1
}

build_number="${WEBBY_BUILD_NUMBER:-}"
if [[ -n "$build_number" && ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  refuse "WEBBY_BUILD_NUMBER '$build_number' is not a positive integer"
fi

identity="${WEBBY_SIGN_IDENTITY:-}"
team_id="${WEBBY_TEAM_ID:-}"
if [[ "$release" -eq 1 ]]; then
  [[ -n "$identity" ]] || refuse "--release requires WEBBY_SIGN_IDENTITY (a Developer ID Application identity)"
  [[ "$identity" != "-" ]] || refuse "--release refuses ad hoc signing"
  if [[ ! "$identity" =~ ^Developer\ ID\ Application:\ .+\ \(([A-Z0-9]{10})\)$ ]]; then
    refuse "WEBBY_SIGN_IDENTITY must be 'Developer ID Application: <name> (<TEAMID>)'"
  fi
  identity_team="${BASH_REMATCH[1]}"
  [[ -n "$team_id" ]] || refuse "--release requires WEBBY_TEAM_ID"
  [[ "$team_id" == "$identity_team" ]] || refuse "WEBBY_TEAM_ID does not match the signing identity's team"
  [[ -n "$build_number" ]] || refuse "--release requires WEBBY_BUILD_NUMBER"
  archs="${WEBBY_ARCHS:-arm64 x86_64}"
else
  identity="${identity:--}"
  archs="${WEBBY_ARCHS:-$(uname -m)}"
fi
arch_flags=()
for arch in $archs; do
  case "$arch" in
    arm64 | x86_64) arch_flags+=(--arch "$arch") ;;
    *) refuse "unsupported architecture '$arch'" ;;
  esac
done

# codesign looks the identity up only after the build has replaced dist/Webby.app, so a
# mistyped name or a certificate missing from the keychain search list must fail here.
# The output is captured first: with pipefail, grep -q closing the pipe early can fail it.
if [[ "$release" -eq 1 ]]; then
  identities="$(security find-identity -v -p codesigning 2> /dev/null || true)"
  grep -Fq "\"$identity\"" <<< "$identities" \
    || refuse "no valid code-signing identity named '$identity' in the keychain search list"
fi

cd "$root/mac"
swift build -c release "${arch_flags[@]}" --product Webby
swift build -c release "${arch_flags[@]}" --product webby-bridge
bin="$(swift build -c release "${arch_flags[@]}" --show-bin-path)"

app="$root/dist/Webby.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
plist="$app/Contents/Info.plist"
cp Resources/Info.plist "$plist"
if [[ -n "$build_number" ]]; then
  plutil -replace CFBundleVersion -string "$build_number" "$plist"
fi
if [[ "$release" -eq 0 ]]; then
  # A development build may register the Chrome bridge from any non-translocated folder
  # (RegistrationPolicy.development); release artifacts must never carry this key.
  plutil -replace WebbyDevelopmentBuild -bool true "$plist"
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
package_log="$("$root/scripts/package-extension.sh" --output-dir "$root/dist/package")"
echo "$package_log"
payload_hash="$(sed -n 's/^extensionPayload=//p' <<< "$package_log")"
cp -R "$root/dist/package/Extension" "$app/Contents/Resources/Extension"

if [[ "$release" -eq 1 ]]; then
  "$root/scripts/check-version-identifiers.sh" --plist "$plist" --release --extension-payload "$payload_hash"
else
  "$root/scripts/check-version-identifiers.sh" --plist "$plist" --allow-development --extension-payload "$payload_hash"
fi
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$plist")"

# Nothing changes the bundle after this. The bridge is signed before the app that contains
# it, and never with --deep. An ad-hoc signature changes with every build, so macOS drops
# privacy grants such as Accessibility after each rebuild; a stable identity (an Apple
# Development or self-signed certificate) keeps them (plan.md §6.6).
sign_flags=(--force --options runtime --entitlements "$root/mac/Resources/Webby.entitlements" --sign "$identity")
if [[ "$release" -eq 1 ]]; then
  sign_flags+=(--timestamp)
fi
codesign "${sign_flags[@]}" "$app/Contents/MacOS/webby-bridge"
codesign "${sign_flags[@]}" "$app"

if [[ "$release" -eq 1 ]]; then
  "$root/scripts/verify-artifact.sh" "$app" --release --team-id "$team_id" --archs "$archs"
  echo "Built $app (release, $identity, build $build_number; notarize before distributing)"
else
  "$root/scripts/verify-artifact.sh" "$app" --archs "$archs"
  if [[ "$identity" == "-" ]]; then
    echo "Built $app (ad hoc; run 'tccutil reset Accessibility $bundle_id' after rebuilding)"
    # Builds before 0.1.0 used this identifier; its grant does not carry over.
    echo "Upgrading from a build before 0.1.0? Also run 'tccutil reset Accessibility com.webby.app'"
  else
    echo "Built $app (signed with $identity)"
  fi
fi
