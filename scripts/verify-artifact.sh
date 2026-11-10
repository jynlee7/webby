#!/usr/bin/env bash
# Verify a built Webby.app: strict signatures on the bridge and the app, the hardened
# runtime on both, no get-task-allow entitlement, every expected architecture, identity
# and version agreement, and a bundled extension identical to extension/. With --release
# it also requires a Developer ID signature from --team-id with a secure timestamp and no
# WebbyDevelopmentBuild key; --spctl adds a Gatekeeper assessment (meaningful only for a
# notarized, stapled app). Used by build-app.sh, CI and the release workflow on the
# re-extracted final ZIP.
#
# Usage: verify-artifact.sh APP [--release --team-id ID] [--archs "arm64 x86_64"] [--spctl]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  echo "usage: $0 APP [--release --team-id ID] [--archs \"arm64 x86_64\"] [--spctl]" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
app="$1"
shift
release=0
team_id=""
archs="$(uname -m)"
spctl_check=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) release=1; shift ;;
    --team-id) [[ $# -ge 2 ]] || usage; team_id="$2"; shift 2 ;;
    --archs) [[ $# -ge 2 ]] || usage; archs="$2"; shift 2 ;;
    --spctl) spctl_check=1; shift ;;
    *) usage ;;
  esac
done
if [[ "$release" -eq 1 && -z "$team_id" ]]; then
  echo "verify-artifact: --release requires --team-id" >&2
  exit 2
fi

failed=0
fail() {
  echo "verify-artifact: $*" >&2
  failed=1
}

[[ -d "$app/Contents" ]] || { echo "verify-artifact: $app is not an app bundle" >&2; exit 1; }
bridge="$app/Contents/MacOS/webby-bridge"
main="$app/Contents/MacOS/Webby"

for target in "$bridge" "$app"; do
  codesign --verify --strict --verbose=1 "$target" 2> /dev/null || fail "strict signature check failed for $target"
done
codesign --verify --strict --deep "$app" 2> /dev/null || fail "strict nested signature check failed for $app"

for target in "$bridge" "$app"; do
  details="$(codesign -d --verbose=4 "$target" 2>&1 || true)"
  grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]*\([^)]*runtime' <<< "$details" || fail "$target is not signed with the hardened runtime"
  entitlements="$(codesign -d --entitlements - --xml "$target" 2> /dev/null || true)"
  if grep -q 'get-task-allow' <<< "$entitlements"; then
    fail "$target carries com.apple.security.get-task-allow"
  fi
  if [[ "$release" -eq 1 ]]; then
    grep -q '^Authority=Developer ID Application: ' <<< "$details" || fail "$target is not signed with a Developer ID Application identity"
    grep -qx "TeamIdentifier=$team_id" <<< "$details" || fail "$target team is not $team_id"
    grep -q '^Timestamp=' <<< "$details" || fail "$target has no secure timestamp"
  fi
done

for executable in "$main" "$bridge"; do
  present=" $(lipo -archs "$executable" 2> /dev/null || true) "
  for arch in $archs; do
    [[ "$present" == *" $arch "* ]] || fail "$executable lacks $arch (has:$present)"
  done
done

if [[ "$release" -eq 1 ]]; then
  WEBBY_BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")" \
    "$root/scripts/check-version-identifiers.sh" --plist "$app/Contents/Info.plist" --release > /dev/null \
    || fail "identity or version check failed for $app (release)"
else
  "$root/scripts/check-version-identifiers.sh" --plist "$app/Contents/Info.plist" --allow-development > /dev/null \
    || fail "identity or version check failed for $app"
fi

bundled="$app/Contents/Resources/Extension"
entries="$( (cd "$bundled" 2> /dev/null && find . -mindepth 1 -print | sed 's#^\./##' | LC_ALL=C sort | tr '\n' ' ') || true)"
[[ "$entries" == "background.js manifest.json protocol.js " ]] || fail "bundled extension holds '$entries'"
for name in background.js manifest.json protocol.js; do
  cmp -s "$root/extension/$name" "$bundled/$name" || fail "bundled $name differs from extension/$name"
done

if [[ "$spctl_check" -eq 1 ]]; then
  spctl --assess --type execute --verbose=4 "$app" || fail "Gatekeeper rejected $app"
fi

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi
mode="development"
[[ "$release" -eq 1 ]] && mode="release, team $team_id"
echo "Artifact OK ($app: $mode, archs $archs)"
