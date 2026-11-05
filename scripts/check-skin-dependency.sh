#!/usr/bin/env bash
# Guard the skin archive dependency pin (plan.md §5.4.6, Step 9a). The archive lane
# must build against ZIPFoundation 0.9.20, pinned exactly in both the manifest and
# the committed SwiftPM resolution. Read-only: it never edits either file.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package="$root/mac/Package.swift"
resolved="$root/mac/Package.resolved"
expected="0.9.20"
expected_revision="22787ffb59de99e5dc1fbfe80b19c97a904ad48d"
expected_url="https://github.com/weichsel/ZIPFoundation.git"

status=0

report() {
  printf 'check-skin-dependency: %s\n' "$*" >&2
  status=1
}

if [[ ! -f "$package" ]]; then
  report "$package is missing"
else
  package_count="$(grep -Ec '^[[:space:]]*\.package[[:space:]]*\(' "$package" || true)"
  if [[ "$package_count" -ne 1 ]]; then
    report "$package: issue #18 permits exactly one third-party package dependency"
  fi
  if ! grep -Fq ".package(url: \"$expected_url\", exact: \"$expected\")" "$package"; then
    report "$package: ZIPFoundation must use $expected_url pinned with exact: \"$expected\""
  fi
fi

if [[ ! -f "$resolved" ]]; then
  report "$resolved is missing; run 'swift package resolve' in mac/ and commit the result"
else
  # Package.resolved is generated JSON with one pin per identity. Split on the
  # "identity" key so the ZIPFoundation pin's state object can be checked alone.
  pin="$(awk 'BEGIN { RS = "\"identity\"" } /"zipfoundation"/ { print }' "$resolved")"
  if [[ -z "$pin" ]]; then
    report "$resolved: no ZIPFoundation pin; run 'swift package resolve' in mac/"
  else
    if ! printf '%s' "$pin" | grep -Fq "\"location\" : \"$expected_url\"" \
       && ! printf '%s' "$pin" | grep -Fq "\"location\": \"$expected_url\""; then
      report "$resolved: ZIPFoundation resolves from an unexpected location"
    fi
    if ! printf '%s' "$pin" | grep -Eq '"version"[[:space:]]*:[[:space:]]*"0\.9\.20"'; then
      report "$resolved: ZIPFoundation does not resolve to $expected"
    fi
    if ! printf '%s' "$pin" | grep -Fq "\"revision\" : \"$expected_revision\"" \
       && ! printf '%s' "$pin" | grep -Fq "\"revision\": \"$expected_revision\""; then
      report "$resolved: ZIPFoundation revision does not match the reviewed $expected tag"
    fi
  fi
fi

if [[ "$status" -ne 0 ]]; then
  exit 1
fi
echo "Skin archive dependency pin OK (ZIPFoundation $expected)"
