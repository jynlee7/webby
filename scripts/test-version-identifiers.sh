#!/usr/bin/env bash
# Seed one identity or version mismatch at a time into temporary copies of the tracked
# sources and check that check-version-identifiers.sh rejects each one with its own line.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
checker="$root/scripts/check-version-identifiers.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/webby-version-identifiers.XXXXXX")"
trap 'rm -rf "$work"' EXIT

passed=0
failures=0

# Fresh copies of the four inputs for each case.
reset_fixtures() {
  rm -rf "$work/case"
  mkdir -p "$work/case"
  cp "$root/mac/Resources/Info.plist" "$work/case/Info.plist"
  cp "$root/extension/manifest.json" "$work/case/manifest.json"
  # An empty history, so the cases stay valid after real releases are recorded.
  printf '{"schemaVersion": 1, "releases": []}\n' > "$work/case/history.json"
  cp "$root/mac/Sources/WebbyCore/Webby.swift" "$work/case/Webby.swift"
}

run_checker() {
  "$checker" --plist "$work/case/Info.plist" --extension-manifest "$work/case/manifest.json" \
    --history "$work/case/history.json" --swift "$work/case/Webby.swift" "$@"
}

record_failure() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

# expect_pass NAME [checker args...]
expect_pass() {
  local name="$1"
  shift
  if run_checker "$@" > "$work/out" 2> "$work/err"; then
    passed=$((passed + 1))
  else
    record_failure "$name: expected success, got: $(cat "$work/err")"
  fi
}

# expect_fail NAME MESSAGE LINES [checker args...]: exits non-zero and prints MESSAGE.
# LINES is the exact number of failure lines, or "any".
expect_fail() {
  local name="$1" message="$2" lines="$3"
  shift 3
  if run_checker "$@" > "$work/out" 2> "$work/err"; then
    record_failure "$name: expected failure, but the checker passed"
    return
  fi
  if ! grep -qF -- "$message" "$work/err"; then
    record_failure "$name: missing '$message' in: $(cat "$work/err")"
    return
  fi
  if [[ "$lines" != "any" && "$(wc -l < "$work/err" | tr -d ' ')" != "$lines" ]]; then
    record_failure "$name: expected $lines failure line(s), got: $(cat "$work/err")"
    return
  fi
  passed=$((passed + 1))
}

set_plist() {
  plutil -replace "$1" "$2" "$3" "$work/case/Info.plist"
}

set_swift() {
  local key="$1" value="$2"
  sed -i '' -E "s/(public static let $key = \")[^\"]*\"/\1$value\"/" "$work/case/Webby.swift"
}

set_json() {
  local file="$work/case/$1" filter="$2"
  jq "$filter" "$file" > "$file.new"
  mv "$file.new" "$file"
}

history_entry() {
  local version="$1" build="$2" hash
  hash="$(printf '%064d' 0)"
  printf '{"version":"%s","build":%s,"commit":"%s","acceptedAt":"2026-11-01","appZip":"%s","extensionZip":"%s","extensionPayload":"%s"}' \
    "$version" "$build" "$(printf '%040d' 0)" "$hash" "$hash" "$hash"
}

reset_fixtures
expect_pass "tracked sources agree"
version="$(jq -r .version "$work/case/manifest.json")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$work/case/Info.plist")"

reset_fixtures
set_plist CFBundleIdentifier -string com.example.other
# The expected UTI follows Webby.bundleID, so the plist's skin declarations still match.
expect_fail "bundle ID" "bundle ID mismatch" 1

reset_fixtures
set_swift bundleID "com.example.other"
# Renaming the Swift identity alone also breaks both skin UTI lines.
expect_fail "bundle ID (Swift)" "bundle ID mismatch" 3

reset_fixtures
set_plist CFBundleShortVersionString -string 9.9.9
expect_fail "marketing version" "marketing version mismatch" 1

reset_fixtures
set_json manifest.json '.version = "9.9.9"'
expect_fail "extension version" "extension version mismatch" 1

reset_fixtures
set_swift version "0.1"
expect_fail "malformed Swift version" "Webby.version '0.1' is not MAJOR.MINOR.PATCH" any

reset_fixtures
set_plist CFBundleShortVersionString -string 01.0.0
set_swift version "01.0.0"
set_json manifest.json '.version = "01.0.0"'
expect_fail "leading zero" "is not MAJOR.MINOR.PATCH" 3

reset_fixtures
set_plist CFBundleVersion -string 0
expect_fail "non-positive build" "CFBundleVersion '0' is not a positive integer" 1

reset_fixtures
set_plist CFBundleVersion -string 1a
expect_fail "non-numeric build" "CFBundleVersion '1a' is not a positive integer" 1

reset_fixtures
set_plist UTExportedTypeDeclarations.0.UTTypeIdentifier -string com.webby.app.skin
expect_fail "UTI domain" "skin UTI mismatch" 1

reset_fixtures
set_plist CFBundleDocumentTypes.0.LSItemContentTypes.0 -string com.webby.app.skin
expect_fail "document type" "skin document type mismatch" 1

reset_fixtures
/usr/libexec/PlistBuddy -c 'Set :UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:0 zip' "$work/case/Info.plist"
expect_fail "skin extension" "skin filename extension 'zip'" 1

reset_fixtures
/usr/libexec/PlistBuddy -c 'Set :UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.mime-type:0 application/zip' "$work/case/Info.plist"
expect_fail "skin MIME type" "skin MIME type 'application/zip'" 1

reset_fixtures
expect_fail "missing release build number" "release mode requires WEBBY_BUILD_NUMBER" 1 --release

reset_fixtures
WEBBY_BUILD_NUMBER=x expect_fail "non-numeric release build number" "WEBBY_BUILD_NUMBER 'x' is not a positive integer" 1 --release

reset_fixtures
set_plist CFBundleVersion -string 7
WEBBY_BUILD_NUMBER=8 expect_fail "staged build number" "CFBundleVersion '7' does not match WEBBY_BUILD_NUMBER '8'" 1 --release

reset_fixtures
set_plist CFBundleVersion -string 7
WEBBY_BUILD_NUMBER=7 expect_pass "release build number applied" --release

reset_fixtures
set_plist WebbyDevelopmentBuild -bool true
expect_fail "leaked WebbyDevelopmentBuild" "WebbyDevelopmentBuild is set" 1
WEBBY_BUILD_NUMBER=1 expect_fail "WebbyDevelopmentBuild in release" "WebbyDevelopmentBuild is set" 1 --release
expect_pass "staged development build" --allow-development

reset_fixtures
if run_checker --release --allow-development > /dev/null 2>&1; then
  record_failure "conflicting modes: expected a usage error"
else
  passed=$((passed + 1))
fi

reset_fixtures
set_json history.json '.schemaVersion = 2'
expect_fail "history schema" "release history must be" 1

reset_fixtures
set_json history.json ".releases = [$(history_entry "$version" 2), $(history_entry "$version" 2)]"
expect_fail "history builds not increasing" "release history entry 1 build 2 does not exceed the previous build 2" 1

reset_fixtures
set_json history.json ".releases = [$(history_entry "$version" 1) | del(.commit)]"
expect_fail "history entry fields" "release history entry 0 needs" 1

reset_fixtures
set_json history.json ".releases = [$(history_entry "$version" 3)]"
set_plist CFBundleVersion -string 3
WEBBY_BUILD_NUMBER=3 expect_fail "release build not above history" "WEBBY_BUILD_NUMBER 3 does not exceed the last accepted build 3" 1 --release

reset_fixtures
set_json history.json ".releases = [$(history_entry "$version" 3)]"
set_plist CFBundleVersion -string 4
WEBBY_BUILD_NUMBER=4 expect_pass "release build above history" --release

reset_fixtures
set_json history.json ".releases = [$(history_entry 99.0.0 3)]"
set_plist CFBundleVersion -string 4
WEBBY_BUILD_NUMBER=4 expect_fail "release version below history" "is lower than the last accepted release 99.0.0" 1 --release

same="$(printf '%064d' 0)"
changed="$(printf '%064d' 1)"
reset_fixtures
set_json history.json ".releases = [$(history_entry "$version" 3)]"
expect_pass "unchanged extension payload" --extension-payload "$same"
expect_fail "changed extension payload, same version" "extension payload differs from accepted release" 1 --extension-payload "$changed"

reset_fixtures
set_json history.json ".releases = [$(history_entry 0.0.9 3)]"
expect_pass "changed extension payload, new version" --extension-payload "$changed"

if [[ "$failures" -ne 0 ]]; then
  echo "test-version-identifiers: $failures failed, $passed passed" >&2
  exit 1
fi
echo "Version identifier checks OK ($passed cases, $bundle_id $version)"
