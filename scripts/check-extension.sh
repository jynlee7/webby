#!/usr/bin/env bash
# Validate the Chrome extension and its agreement with the app:
# - the manifest parses and asks only for the permissions Webby needs;
# - the JS parses and the protocol tests pass;
# - the extension ID derived from the manifest "key", the native host template and
#   BridgeConstants.swift agree, and so do the host name and protocol version in
#   BridgeConstants.swift, protocol.js and the template.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
ext="$root/extension"
constants="$root/mac/Sources/WebbyCore/Bridge/BridgeConstants.swift"

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
if [[ "$failed" -ne 0 ]]; then
  exit 1
fi
echo "Extension OK (id $derived, host $swift_host, protocol v$swift_version)"
