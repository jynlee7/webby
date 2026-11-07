#!/usr/bin/env bash
# Stage the Chrome extension payload and archive it deterministically.
#
#   package-extension.sh --output-dir DIR [--zip PATH]
#
# Writes DIR/Extension/ with exactly manifest.json, background.js and protocol.js, and
# DIR/Webby-Extension-<version>.zip (or PATH) with the same three files at the archive
# root. build-app.sh copies DIR/Extension into the app; the archive is kept for a later
# Chrome Web Store upload with the same key. package.json, the native host template and
# the tests stay in extension/ and are never staged. The tracked manifest is never edited:
# a version that differs from Webby.version fails instead. Two runs from the same source
# produce the same archive bytes. Prints extensionPayload=<sha256>, the hash of the
# sorted per-file SHA-256 listing, which release history records.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

source_dir="$root/extension"
swift="$root/mac/Sources/WebbyCore/Webby.swift"
out=""
zip_path=""
payload=(background.js manifest.json protocol.js)

usage() {
  echo "usage: $0 --output-dir DIR [--zip PATH]" >&2
  exit 2
}

die() {
  echo "package-extension: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) [[ $# -ge 2 ]] || usage; out="$2"; shift 2 ;;
    --zip) [[ $# -ge 2 ]] || usage; zip_path="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$out" ]] || usage

# Resolved absolute path of an existing directory.
physical_dir() {
  (cd "$1" && pwd -P)
}

# Whether directory $1 is $2 or inside it. APFS is usually case-insensitive, so compare
# lowercased paths.
is_within() {
  local inner outer
  inner="$(printf '%s/' "$1" | tr '[:upper:]' '[:lower:]')"
  outer="$(printf '%s/' "$2" | tr '[:upper:]' '[:lower:]')"
  [[ "$inner" == "$outer"* ]]
}

# Payload: every expected file present as a regular file, never a symlink.
[[ -d "$source_dir" && ! -L "$source_dir" ]] || die "source $source_dir is not a directory"
for name in "${payload[@]}"; do
  file="$source_dir/$name"
  [[ ! -L "$file" ]] || die "$name is a symlink"
  [[ -e "$file" ]] || die "$name is missing from $source_dir"
  [[ -f "$file" ]] || die "$name is not a regular file"
done

manifest="$source_dir/manifest.json"
jq -e . "$manifest" > /dev/null 2>&1 || die "manifest.json is not valid JSON"
jq -e '.manifest_version == 3 and (.key | type == "string" and length > 0)
       and .background.service_worker == "background.js" and .background.type == "module"' "$manifest" > /dev/null \
  || die "manifest.json must be MV3 with its pinned key and the background.js module worker"
jq -e '(.permissions | sort) == ["nativeMessaging", "storage", "tabs"]
       and (has("host_permissions") | not) and (has("optional_permissions") | not)' "$manifest" > /dev/null \
  || die "manifest.json permissions must be exactly nativeMessaging, storage and tabs"
for name in background.js protocol.js; do
  node --check "$source_dir/$name" || die "$name does not parse"
done

[[ -f "$swift" ]] || die "missing $swift"
webby_version="$(sed -nE 's/^[[:space:]]*public static let version = "([^"]*)"$/\1/p' "$swift")"
manifest_version="$(jq -r '.version // ""' "$manifest")"
[[ -n "$webby_version" ]] || die "Webby.version not found in $swift"
if [[ "$manifest_version" != "$webby_version" ]]; then
  die "extension version '$manifest_version' does not match Webby.version '$webby_version'"
fi

# Output: an existing real directory, or a new one in an existing parent, never inside the
# tracked extension folder.
tracked="$(physical_dir "$source_dir")"
[[ ! -L "$out" ]] || die "output directory $out is a symlink"
out_parent="$(dirname "$out")"
[[ -d "$out_parent" ]] || die "parent of output directory $out does not exist"
out="$(physical_dir "$out_parent")/$(basename "$out")"
! is_within "$out" "$tracked" || die "refusing to write inside the tracked extension folder"
if [[ ! -e "$out" ]]; then
  mkdir "$out" || die "cannot create output directory $out"
fi
[[ -d "$out" ]] || die "output $out is not a directory"
[[ -w "$out" ]] || die "output directory $out is not writable"
out="$(physical_dir "$out")"
! is_within "$out" "$tracked" || die "refusing to write inside the tracked extension folder"
stage="$out/Extension"
[[ ! -L "$stage" ]] || die "$stage is a symlink"
if [[ -e "$stage" && ( ! -d "$stage" || "$stage" -ef "$tracked" ) ]]; then
  die "refusing to replace $stage"
fi

[[ -n "$zip_path" ]] || zip_path="$out/Webby-Extension-$webby_version.zip"
zip_dir="$(dirname "$zip_path")"
[[ -d "$zip_dir" && ! -L "$zip_dir" ]] || die "archive folder $zip_dir is not a directory"
[[ -w "$zip_dir" ]] || die "archive folder $zip_dir is not writable"
zip_dir="$(physical_dir "$zip_dir")"
! is_within "$zip_dir" "$tracked" || die "refusing to write inside the tracked extension folder"
zip_path="$zip_dir/$(basename "$zip_path")"
[[ ! -L "$zip_path" && ! -d "$zip_path" ]] || die "refusing to replace $zip_path"

# Everything is built under temporary names and renamed into place only after it checks out,
# so a failure leaves no partial stage or archive.
work=""
zip_work=""
cleanup() {
  [[ -z "$work" ]] || rm -rf "$work"
  [[ -z "$zip_work" ]] || rm -rf "$zip_work"
}
trap cleanup EXIT
work="$(mktemp -d "$out/.package-extension.XXXXXX")" || die "cannot create a temporary folder in $out"
zip_work="$(mktemp -d "$zip_dir/.package-extension-zip.XXXXXX")" || die "cannot create a temporary folder in $zip_dir"

new_stage="$work/Extension"
mkdir "$new_stage"
for name in "${payload[@]}"; do
  # -X skips extended attributes and resource forks.
  cp -X "$source_dir/$name" "$new_stage/$name"
  chmod 0644 "$new_stage/$name"
  TZ=UTC touch -t 198001010000 "$new_stage/$name"
done
chmod 0755 "$new_stage"

staged="$(cd "$new_stage" && find . -mindepth 1 -print | sed 's#^\./##' | LC_ALL=C sort | tr '\n' ' ')"
[[ "$staged" == "${payload[*]} " ]] || die "stage holds unexpected entries: $staged"
for name in "${payload[@]}"; do
  cmp -s "$source_dir/$name" "$new_stage/$name" || die "staged $name differs from the source"
done

# -X: no extra fields (uid/gid, extended timestamps); -D: no directory entries. ZIPOPT
# could add options behind our back, and TZ pins the DOS timestamps.
new_zip="$zip_work/extension.zip"
(
  unset ZIPOPT ZIP
  cd "$new_stage"
  COPYFILE_DISABLE=1 TZ=UTC zip -X -D -q -6 "$new_zip" "${payload[@]}"
) || die "zip failed"
listed="$(zipinfo -1 "$new_zip" | tr '\n' ' ')"
[[ "$listed" == "${payload[*]} " ]] || die "archive holds unexpected entries: $listed"

payload_hash="$(cd "$new_stage" && shasum -a 256 "${payload[@]}" | shasum -a 256 | cut -d' ' -f1)"

# Swap in the new stage, then the archive.
if [[ -e "$stage" ]]; then
  mv "$stage" "$work/Extension-previous"
fi
mv "$new_stage" "$stage"
mv -f "$new_zip" "$zip_path"

echo "Staged $stage"
echo "archive=$zip_path"
echo "archiveSHA256=$(shasum -a 256 "$zip_path" | cut -d' ' -f1)"
echo "extensionPayload=$payload_hash"
