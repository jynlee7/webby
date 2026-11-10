#!/usr/bin/env bash
# Check that Webby's identity and version agree everywhere they are written down:
# - Webby.bundleID (WebbyCore/Webby.swift) equals CFBundleIdentifier;
# - Webby.version equals CFBundleShortVersionString and the extension manifest version,
#   and each is MAJOR.MINOR.PATCH;
# - CFBundleVersion is a positive integer;
# - the exported skin UTI is bundleID + ".skin", the skin document type names it, and it
#   keeps the webbyskin extension and application/x-webbyskin MIME type;
# - release/history.json is schema 1 with strictly increasing builds.
# With --release, WEBBY_BUILD_NUMBER is required, must equal CFBundleVersion and exceed
# every accepted build, and the plist must not carry WebbyDevelopmentBuild. Without
# --release the key is still rejected unless --allow-development is given (the staged
# development build). With --extension-payload HASH (package-extension.sh's
# extensionPayload), a payload that differs from an accepted release of the same marketing
# version fails: an extension change needs a new version. Fails closed with one line per
# mismatch. macOS only (PlistBuddy).
#
# Usage: check-version-identifiers.sh [--plist PATH] [--extension-manifest PATH]
#          [--history PATH] [--swift PATH] [--extension-payload HASH]
#          [--release | --allow-development]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

plist="$root/mac/Resources/Info.plist"
manifest="$root/extension/manifest.json"
history="$root/release/history.json"
swift="$root/mac/Sources/WebbyCore/Webby.swift"
release=0
allow_development=0
extension_payload=""

usage() {
  echo "usage: $0 [--plist PATH] [--extension-manifest PATH] [--history PATH] [--swift PATH] [--release | --allow-development]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plist) [[ $# -ge 2 ]] || usage; plist="$2"; shift 2 ;;
    --extension-manifest) [[ $# -ge 2 ]] || usage; manifest="$2"; shift 2 ;;
    --history) [[ $# -ge 2 ]] || usage; history="$2"; shift 2 ;;
    --swift) [[ $# -ge 2 ]] || usage; swift="$2"; shift 2 ;;
    --extension-payload) [[ $# -ge 2 ]] || usage; extension_payload="$2"; shift 2 ;;
    --release) release=1; shift ;;
    --allow-development) allow_development=1; shift ;;
    *) usage ;;
  esac
done
if [[ "$release" -eq 1 && "$allow_development" -eq 1 ]]; then
  echo "--release and --allow-development are mutually exclusive" >&2
  exit 2
fi

failed=0
fail() {
  echo "check-version-identifiers: $*" >&2
  failed=1
}

for file in "$plist" "$manifest" "$history" "$swift"; do
  if [[ ! -f "$file" ]]; then
    echo "check-version-identifiers: missing $file" >&2
    exit 1
  fi
done
if ! plutil -lint -s "$plist"; then
  echo "check-version-identifiers: $plist is not a valid property list" >&2
  exit 1
fi
for file in "$manifest" "$history"; do
  if ! jq -e . "$file" > /dev/null 2>&1; then
    echo "check-version-identifiers: $file is not valid JSON" >&2
    exit 1
  fi
done

# Prints the value at a PlistBuddy key path (":" separated), or nothing when absent.
plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true
}

is_version() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

# Compares two MAJOR.MINOR.PATCH versions numerically: prints -1, 0 or 1.
compare_versions() {
  local a b i
  IFS=. read -r -a a <<< "$1"
  IFS=. read -r -a b <<< "$2"
  for i in 0 1 2; do
    if (( 10#${a[i]} < 10#${b[i]} )); then echo -1; return; fi
    if (( 10#${a[i]} > 10#${b[i]} )); then echo 1; return; fi
  done
  echo 0
}

swift_bundle_id="$(sed -nE 's/^[[:space:]]*public static let bundleID = "([^"]*)"$/\1/p' "$swift")"
swift_version="$(sed -nE 's/^[[:space:]]*public static let version = "([^"]*)"$/\1/p' "$swift")"
plist_bundle_id="$(plist_value CFBundleIdentifier)"
plist_version="$(plist_value CFBundleShortVersionString)"
plist_build="$(plist_value CFBundleVersion)"
extension_version="$(jq -r '.version // ""' "$manifest")"

[[ -n "$swift_bundle_id" ]] || fail "Webby.bundleID not found in $swift"
[[ -n "$swift_version" ]] || fail "Webby.version not found in $swift"

if [[ "$swift_bundle_id" != "$plist_bundle_id" ]]; then
  fail "bundle ID mismatch: Webby.bundleID '$swift_bundle_id' vs CFBundleIdentifier '$plist_bundle_id'"
fi
for pair in "Webby.version:$swift_version" "CFBundleShortVersionString:$plist_version" "extension version:$extension_version"; do
  name="${pair%%:*}"
  value="${pair#*:}"
  is_version "$value" || fail "$name '$value' is not MAJOR.MINOR.PATCH"
done
if [[ "$swift_version" != "$plist_version" ]]; then
  fail "marketing version mismatch: Webby.version '$swift_version' vs CFBundleShortVersionString '$plist_version'"
fi
if [[ "$swift_version" != "$extension_version" ]]; then
  fail "extension version mismatch: Webby.version '$swift_version' vs extension manifest '$extension_version'"
fi
is_positive_integer "$plist_build" || fail "CFBundleVersion '$plist_build' is not a positive integer"

# The skin UTI shares the bundle ID's domain; there is no exception (plan.md Step 10).
expected_uti="$swift_bundle_id.skin"
exported_uti="$(plist_value UTExportedTypeDeclarations:0:UTTypeIdentifier)"
document_uti="$(plist_value CFBundleDocumentTypes:0:LSItemContentTypes:0)"
skin_extension="$(plist_value UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:0)"
skin_mime="$(plist_value UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.mime-type:0)"
if [[ "$exported_uti" != "$expected_uti" ]]; then
  fail "skin UTI mismatch: UTExportedTypeDeclarations '$exported_uti' vs bundle ID + .skin '$expected_uti'"
fi
if [[ "$document_uti" != "$expected_uti" ]]; then
  fail "skin document type mismatch: CFBundleDocumentTypes '$document_uti' vs '$expected_uti'"
fi
[[ "$skin_extension" == "webbyskin" ]] || fail "skin filename extension '$skin_extension' is not 'webbyskin'"
[[ "$skin_mime" == "application/x-webbyskin" ]] || fail "skin MIME type '$skin_mime' is not 'application/x-webbyskin'"

development="$(plist_value WebbyDevelopmentBuild)"
if [[ -n "$development" && "$allow_development" -ne 1 ]]; then
  fail "WebbyDevelopmentBuild is set in $plist; only a staged development build may carry it"
fi

# Accepted release history: appended only by a reviewed PR after a release is accepted.
if ! jq -e '.schemaVersion == 1 and (.releases | type == "array")' "$history" > /dev/null; then
  fail "release history must be {\"schemaVersion\": 1, \"releases\": [...]}"
  history_ok=0
else
  history_ok=1
fi
last_build=0
last_version=""
if [[ "$history_ok" -eq 1 ]]; then
  bad_entries="$(jq -r '
    .releases | to_entries[]
    | select(
        (.value | type) != "object"
        or (.value.version | type) != "string"
        or (.value.build | type) != "number"
        or (.value.commit | type) != "string" or (.value.commit | test("^[0-9a-f]{40}$") | not)
        or (.value.acceptedAt | type) != "string" or (.value.acceptedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not)
        or ([.value.appZip, .value.extensionZip, .value.extensionPayload]
            | any(type != "string" or (test("^[0-9a-f]{64}$") | not)))
      )
    | .key' "$history")"
  for index in $bad_entries; do
    fail "release history entry $index needs version, build, commit, acceptedAt, appZip, extensionZip and extensionPayload"
  done
  while IFS=$'\t' read -r index version build; do
    [[ -z "$index" ]] && continue
    if ! is_version "$version"; then
      fail "release history entry $index version '$version' is not MAJOR.MINOR.PATCH"
      continue
    fi
    if ! is_positive_integer "$build"; then
      fail "release history entry $index build '$build' is not a positive integer"
      continue
    fi
    if (( build <= last_build )); then
      fail "release history entry $index build $build does not exceed the previous build $last_build"
    fi
    if [[ -n "$last_version" && "$(compare_versions "$version" "$last_version")" -lt 0 ]]; then
      fail "release history entry $index version $version is lower than the previous $last_version"
    fi
    last_build="$build"
    last_version="$version"
  done < <(jq -r '.releases | to_entries[] | select(.value | type == "object") | "\(.key)\t\(.value.version)\t\(.value.build)"' "$history")
fi

if [[ -n "$extension_payload" && "$history_ok" -eq 1 ]]; then
  if [[ ! "$extension_payload" =~ ^[0-9a-f]{64}$ ]]; then
    fail "--extension-payload '$extension_payload' is not a SHA-256 hex digest"
  else
    while IFS= read -r accepted; do
      [[ -z "$accepted" ]] && continue
      fail "extension payload differs from accepted release $swift_version ($accepted); bump the marketing version"
    done < <(jq -r --arg version "$swift_version" --arg payload "$extension_payload" \
      '[.releases[] | select(type == "object" and .version == $version and .extensionPayload != $payload)] | first | .build // empty | "build \(.)"' "$history")
  fi
fi

if [[ "$release" -eq 1 ]]; then
  build_number="${WEBBY_BUILD_NUMBER:-}"
  if [[ -z "$build_number" ]]; then
    fail "release mode requires WEBBY_BUILD_NUMBER"
  elif ! is_positive_integer "$build_number"; then
    fail "WEBBY_BUILD_NUMBER '$build_number' is not a positive integer"
  else
    if [[ "$plist_build" != "$build_number" ]]; then
      fail "CFBundleVersion '$plist_build' does not match WEBBY_BUILD_NUMBER '$build_number'"
    fi
    if (( build_number <= last_build )); then
      fail "WEBBY_BUILD_NUMBER $build_number does not exceed the last accepted build $last_build"
    fi
  fi
  if [[ -n "$last_version" ]] && is_version "$swift_version" \
     && [[ "$(compare_versions "$swift_version" "$last_version")" -lt 0 ]]; then
    fail "Webby.version $swift_version is lower than the last accepted release $last_version"
  fi
fi

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi
mode="development"
[[ "$release" -eq 1 ]] && mode="release"
echo "Identifiers OK ($plist_bundle_id $plist_version build $plist_build, $mode)"
