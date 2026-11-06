#!/usr/bin/env bash
# Exercise package-extension.sh against a temporary copy of the repository: determinism
# across umasks, working directories and source mtimes, the exact allowlist, and refusal
# (with no archive left behind) for symlinks, missing files, a version mismatch, an
# unwritable or symlinked output folder and the tracked extension folder.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

work="$(mktemp -d "${TMPDIR:-/tmp}/webby-extension-packaging.XXXXXX")"
cleanup() {
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

passed=0
failures=0
record_failure() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

# A fresh copy of the packager and its inputs, so a test can never touch tracked files.
make_repo() {
  local repo="$work/repo"
  rm -rf "$repo"
  mkdir -p "$repo/scripts" "$repo/mac/Sources/WebbyCore"
  cp "$root/scripts/package-extension.sh" "$repo/scripts/"
  cp -R "$root/extension" "$repo/extension"
  cp "$root/mac/Sources/WebbyCore/Webby.swift" "$repo/mac/Sources/WebbyCore/"
  echo "$repo"
}

payload="background.js manifest.json protocol.js "
version="$(jq -r .version "$root/extension/manifest.json")"
archive_name="Webby-Extension-$version.zip"

# expect_refusal NAME MESSAGE OUTPUT_DIR: the packager fails with MESSAGE and leaves no archive.
expect_refusal() {
  local name="$1" message="$2" out="$3"
  if "$repo/scripts/package-extension.sh" --output-dir "$out" > "$work/out" 2> "$work/err"; then
    record_failure "$name: expected failure"
    return
  fi
  if ! grep -qF -- "$message" "$work/err"; then
    record_failure "$name: missing '$message' in: $(cat "$work/err")"
    return
  fi
  if [[ -e "$out/$archive_name" ]] || compgen -G "$out/.package-extension*" > /dev/null; then
    record_failure "$name: left an archive or temporary folder in $out"
    return
  fi
  passed=$((passed + 1))
}

# Determinism: different umask, working directory and source mtimes give identical bytes.
repo="$(make_repo)"
first="$work/first"
second="$work/second"
(umask 022 && cd "$repo" && scripts/package-extension.sh --output-dir "$first" > "$work/first.log")
touch -t 202001020304 "$repo/extension/"*.js "$repo/extension/manifest.json"
(umask 077 && cd / && "$repo/scripts/package-extension.sh" --output-dir "$second" > "$work/second.log")
first_hash="$(shasum -a 256 < "$first/$archive_name" | cut -d' ' -f1)"
second_hash="$(shasum -a 256 < "$second/$archive_name" | cut -d' ' -f1)"
if [[ "$first_hash" == "$second_hash" ]]; then
  passed=$((passed + 1))
else
  record_failure "two runs produced different archives: $first_hash vs $second_hash"
fi
if [[ "$(grep '^extensionPayload=' "$work/first.log")" == "$(grep '^extensionPayload=' "$work/second.log")" ]]; then
  passed=$((passed + 1))
else
  record_failure "two runs printed different payload hashes"
fi
expected_payload="$(cd "$first/Extension" && shasum -a 256 background.js manifest.json protocol.js | shasum -a 256 | cut -d' ' -f1)"
if grep -qx "extensionPayload=$expected_payload" "$work/first.log"; then
  passed=$((passed + 1))
else
  record_failure "extensionPayload does not hash the sorted per-file listing"
fi

# Allowlist: exactly the three payload files, byte for byte, at the archive root.
staged="$(cd "$first/Extension" && find . -mindepth 1 -print | sed 's#^\./##' | LC_ALL=C sort | tr '\n' ' ')"
listed="$(zipinfo -1 "$first/$archive_name" | tr '\n' ' ')"
if [[ "$staged" == "$payload" && "$listed" == "$payload" ]]; then
  passed=$((passed + 1))
else
  record_failure "unexpected payload: stage '$staged', archive '$listed'"
fi
for name in background.js manifest.json protocol.js; do
  if cmp -s "$root/extension/$name" "$first/Extension/$name" \
     && [[ "$(unzip -p "$first/$archive_name" "$name" | shasum -a 256)" == "$(shasum -a 256 < "$root/extension/$name")" ]]; then
    passed=$((passed + 1))
  else
    record_failure "$name differs from the source in the stage or archive"
  fi
done
if [[ "$(stat -f '%Lp' "$first/Extension/manifest.json")" == "644" ]]; then
  passed=$((passed + 1))
else
  record_failure "staged files are not mode 0644"
fi

# A stray file in a previous stage is gone after the next run.
touch "$first/Extension/stray.txt"
(cd "$repo" && scripts/package-extension.sh --output-dir "$first" > /dev/null)
if [[ ! -e "$first/Extension/stray.txt" ]]; then
  passed=$((passed + 1))
else
  record_failure "a stray staged file survived a re-run"
fi

# Refusals.
repo="$(make_repo)"
ln -sf "$repo/extension/protocol.js" "$repo/extension/background.js.link"
rm "$repo/extension/background.js"
mv "$repo/extension/background.js.link" "$repo/extension/background.js"
expect_refusal "symlinked payload file" "background.js is a symlink" "$work/symlink"

repo="$(make_repo)"
rm "$repo/extension/protocol.js"
expect_refusal "missing payload file" "protocol.js is missing" "$work/missing"

repo="$(make_repo)"
jq '.version = "9.9.9"' "$repo/extension/manifest.json" > "$work/manifest.json"
mv "$work/manifest.json" "$repo/extension/manifest.json"
expect_refusal "version mismatch" "does not match Webby.version" "$work/mismatch"

repo="$(make_repo)"
jq '.permissions += ["history"]' "$repo/extension/manifest.json" > "$work/manifest.json"
mv "$work/manifest.json" "$repo/extension/manifest.json"
expect_refusal "extra permission" "permissions must be exactly" "$work/permission"

repo="$(make_repo)"
mkdir "$work/readonly"
chmod 0555 "$work/readonly"
expect_refusal "unwritable output" "is not writable" "$work/readonly"

mkdir "$work/real"
ln -s "$work/real" "$work/linked"
expect_refusal "symlinked output" "is a symlink" "$work/linked"

expect_refusal "inside the tracked extension folder" "refusing to write inside the tracked extension folder" "$repo/extension/out"
# On a case-insensitive volume <repo>/Extension is the tracked extension folder itself.
expect_refusal "repository root as output" "refusing" "$repo"
if [[ -f "$repo/extension/background.js" && -f "$repo/extension/package.json" ]]; then
  passed=$((passed + 1))
else
  record_failure "the tracked extension folder copy was modified"
fi

if [[ "$failures" -ne 0 ]]; then
  echo "test-extension-packaging: $failures failed, $passed passed" >&2
  exit 1
fi
echo "Extension packaging OK ($passed checks, archive $first_hash)"
