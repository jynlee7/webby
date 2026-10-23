#!/usr/bin/env bash
# Validate the Chrome extension: manifest parses, JS parses, and the extension ID
# derived from manifest "key" matches the ID the native host manifest allows.
set -euo pipefail
ext="$(cd "$(dirname "$0")/../extension" && pwd)"

jq -e '.manifest_version == 3 and (.key | length > 0)' "$ext/manifest.json" > /dev/null
for f in "$ext"/*.js; do node --check "$f"; done

# Chrome's ID = first 32 hex chars of sha256(DER public key), mapped 0-f -> a-p.
derived="$(jq -r .key "$ext/manifest.json" | base64 --decode | shasum -a 256 | cut -c1-32 | tr '0-9a-f' 'a-p')"
allowed="$(jq -r '.allowed_origins[0]' "$ext/native-host.template.json" | sed -E 's#chrome-extension://([a-p]{32})/#\1#')"

if [[ "$derived" != "$allowed" ]]; then
  echo "Extension ID mismatch: manifest key -> $derived, host allows $allowed" >&2
  exit 1
fi
echo "Extension OK (id $derived)"
