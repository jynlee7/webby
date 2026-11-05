#!/usr/bin/env bash
# Validate the Chrome extension and its agreement with the app:
# - the manifest parses and asks only for the permissions Webby needs;
# - the JS parses and the protocol tests pass;
# - the extension ID derived from the manifest "key", the native host template and
#   BridgeConstants.swift agree, and so do the host name and protocol version in
#   BridgeConstants.swift, protocol.js and the template.
# With --package DIR (the package-extension.sh output) or --app PATH (a built Webby.app,
# whose package defaults to the dist/package folder beside it), also check that the stage,
# the standalone archive and the app's bundled copy each hold exactly the three payload
# files, byte for byte the same as the source, with no archive directory entries and the
# archived manifest at Webby.version.
#
# Usage: check-extension.sh [--package DIR] [--app PATH]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
ext="$root/extension"
constants="$root/mac/Sources/WebbyCore/Bridge/BridgeConstants.swift"
webby_swift="$root/mac/Sources/WebbyCore/Webby.swift"
payload=(background.js manifest.json protocol.js)

package=""
app=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) [[ $# -ge 2 ]] || { echo "usage: $0 [--package DIR] [--app PATH]" >&2; exit 2; }; package="$2"; shift 2 ;;
    --app) [[ $# -ge 2 ]] || { echo "usage: $0 [--package DIR] [--app PATH]" >&2; exit 2; }; app="$2"; shift 2 ;;
    *) echo "usage: $0 [--package DIR] [--app PATH]" >&2; exit 2 ;;
  esac
done
if [[ -n "$app" && -z "$package" ]]; then
  package="$(dirname "$app")/package"
fi

jq -e '.manifest_version == 3 and (.key | length > 0) and .background.type == "module"' "$ext/manifest.json" > /dev/null
# "storage" is the only permission added for the bridge; it shows no install warning.
jq -e '(.permissions | sort) == ["nativeMessaging", "storage", "tabs"]
       and (has("host_permissions") | not) and (has("optional_permissions") | not)' "$ext/manifest.json" > /dev/null

for f in "$ext"/*.js "$ext"/tests/*.js; do node --check "$f"; done
node --test "$ext"/tests/*.test.js

# Chrome's ID = first 32 hex chars of sha256(DER public key), mapped 0-f -> a-p.
derived="$(jq -r .key "$ext/manifest.json" | base64 --decode | shasum -a 256 | cut -c1-32 | tr '0-9a-f' 'a-p')"
template_id="$(jq -r '.allowed_origins[0]' "$ext/native-host.template.json" | sed -E 's#chrome-extension://([a-p]{32})/#\1#')"
template_host="$(jq -r .name "$ext/native-host.template.json")"
swift_id="$(sed -nE 's/.*static let extensionID = "([a-p]{32})".*/\1/p' "$constants")"
swift_host="$(sed -nE 's/.*static let hostName = "([^"]+)".*/\1/p' "$constants")"
swift_version="$(sed -nE 's/.*static let protocolVersion = ([0-9]+).*/\1/p' "$constants")"
js_host="$(sed -nE 's/^export const HOST_NAME = "([^"]+)";/\1/p' "$ext/protocol.js")"
js_version="$(sed -nE 's/^export const PROTOCOL_VERSION = ([0-9]+);/\1/p' "$ext/protocol.js")"

failed=0
agree() {
  local what="$1" first="$2" second="$3"
  if [[ -z "$first" || "$first" != "$second" ]]; then
    echo "$what mismatch: '$first' vs '$second'" >&2
    failed=1
  fi
}
agree "Extension ID (manifest key vs native host template)" "$derived" "$template_id"
agree "Extension ID (manifest key vs BridgeConstants.swift)" "$derived" "$swift_id"
agree "Host name (BridgeConstants.swift vs protocol.js)" "$swift_host" "$js_host"
agree "Host name (BridgeConstants.swift vs native host template)" "$swift_host" "$template_host"
agree "Protocol version (BridgeConstants.swift vs protocol.js)" "$swift_version" "$js_version"

# Lists the entries of folder $1 (names only, sorted, hidden files included) on one line.
folder_entries() {
  (cd "$1" && find . -mindepth 1 -print | sed 's#^\./##' | LC_ALL=C sort | tr '\n' ' ')
}

# Checks that folder $2 holds exactly the payload, each a regular file identical to the source.
check_payload_folder() {
  local what="$1" folder="$2" name entries
  if [[ ! -d "$folder" || -L "$folder" ]]; then
    echo "$what is missing: $folder" >&2
    failed=1
    return
  fi
  entries="$(folder_entries "$folder")"
  if [[ "$entries" != "${payload[*]} " ]]; then
    echo "$what holds unexpected entries: $entries" >&2
    failed=1
  fi
  for name in "${payload[@]}"; do
    if [[ -L "$folder/$name" || ! -f "$folder/$name" ]] || ! cmp -s "$ext/$name" "$folder/$name"; then
      echo "$what $name differs from extension/$name" >&2
      failed=1
    fi
  done
}

if [[ -n "$package" ]]; then
  webby_version="$(sed -nE 's/^[[:space:]]*public static let version = "([^"]*)"$/\1/p' "$webby_swift")"
  check_payload_folder "Staged extension" "$package/Extension"
  archive="$package/Webby-Extension-$webby_version.zip"
  if [[ ! -f "$archive" ]]; then
    echo "Extension archive is missing: $archive" >&2
    failed=1
  else
    listed="$(zipinfo -1 "$archive" | tr '\n' ' ')"
    if [[ "$listed" != "${payload[*]} " ]]; then
      echo "Extension archive holds unexpected entries: $listed" >&2
      failed=1
    fi
    for name in "${payload[@]}"; do
      if [[ "$(unzip -p "$archive" "$name" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)" \
            != "$(shasum -a 256 < "$ext/$name" | cut -d' ' -f1)" ]]; then
        echo "Extension archive $name differs from extension/$name" >&2
        failed=1
      fi
    done
    archived_version="$(unzip -p "$archive" manifest.json 2>/dev/null | jq -r '.version // ""' 2>/dev/null || true)"
    agree "Extension version (archive vs Webby.version)" "$archived_version" "$webby_version"
  fi
fi
if [[ -n "$app" ]]; then
  check_payload_folder "Bundled extension" "$app/Contents/Resources/Extension"
fi

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi
echo "Extension OK (id $derived, host $swift_host, protocol v$swift_version)"
if [[ -n "$package" ]]; then
  echo "Extension package OK ($package${app:+, bundled in $app})"
fi
