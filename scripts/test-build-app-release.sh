#!/usr/bin/env bash
# build-app.sh --release must fail closed, before building or touching dist/, whenever a
# release input is missing, ad hoc or inconsistent. Never signs anything.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

snapshot() {
  if [[ -e "$root/dist" ]]; then
    find "$root/dist" -maxdepth 3 -print0 | xargs -0 stat -f '%N %i %m' | LC_ALL=C sort
  else
    echo "no dist"
  fi
}

passed=0
failures=0
# expect_refusal NAME MESSAGE [VAR=value ...]: runs build-app.sh --release with only those inputs.
expect_refusal() {
  local name="$1" message="$2" before err
  shift 2
  before="$(snapshot)"
  if err="$(env -u WEBBY_SIGN_IDENTITY -u WEBBY_TEAM_ID -u WEBBY_BUILD_NUMBER -u WEBBY_ARCHS "$@" \
            "$root/scripts/build-app.sh" --release 2>&1 > /dev/null)"; then
    echo "FAIL: $name: build-app.sh --release succeeded" >&2
    failures=$((failures + 1))
  elif [[ "$err" != *"$message"* ]]; then
    echo "FAIL: $name: expected '$message', got: $err" >&2
    failures=$((failures + 1))
  elif [[ "$(snapshot)" != "$before" ]]; then
    echo "FAIL: $name: dist/ changed" >&2
    failures=$((failures + 1))
  else
    passed=$((passed + 1))
  fi
}

developer_id="Developer ID Application: Example Maintainer (ABCDE12345)"
expect_refusal "no identity" "requires WEBBY_SIGN_IDENTITY" WEBBY_TEAM_ID=ABCDE12345 WEBBY_BUILD_NUMBER=1
expect_refusal "empty identity" "requires WEBBY_SIGN_IDENTITY" WEBBY_SIGN_IDENTITY= WEBBY_TEAM_ID=ABCDE12345 WEBBY_BUILD_NUMBER=1
expect_refusal "ad hoc identity" "refuses ad hoc signing" WEBBY_SIGN_IDENTITY=- WEBBY_TEAM_ID=ABCDE12345 WEBBY_BUILD_NUMBER=1
expect_refusal "development identity" "must be 'Developer ID Application" "WEBBY_SIGN_IDENTITY=Apple Development: Example (ABCDE12345)" WEBBY_TEAM_ID=ABCDE12345 WEBBY_BUILD_NUMBER=1
expect_refusal "no team" "requires WEBBY_TEAM_ID" "WEBBY_SIGN_IDENTITY=$developer_id" WEBBY_BUILD_NUMBER=1
expect_refusal "team mismatch" "does not match the signing identity" "WEBBY_SIGN_IDENTITY=$developer_id" WEBBY_TEAM_ID=ZZZZZ99999 WEBBY_BUILD_NUMBER=1
expect_refusal "no build number" "requires WEBBY_BUILD_NUMBER" "WEBBY_SIGN_IDENTITY=$developer_id" WEBBY_TEAM_ID=ABCDE12345
expect_refusal "non-numeric build number" "is not a positive integer" "WEBBY_SIGN_IDENTITY=$developer_id" WEBBY_TEAM_ID=ABCDE12345 WEBBY_BUILD_NUMBER=1.0
expect_refusal "unsupported architecture" "unsupported architecture" "WEBBY_SIGN_IDENTITY=$developer_id" WEBBY_TEAM_ID=ABCDE12345 WEBBY_BUILD_NUMBER=1 WEBBY_ARCHS=ppc

# A well-formed identity the keychain search list doesn't hold must be refused before the
# build replaces dist/Webby.app. This runs a copy of build-app.sh in a temporary root with a
# pre-existing bundle, and puts stubs first on PATH: `security` lists only another identity,
# so no real keychain is read, and `swift` records that the build started. Without the check
# the script would reach `rm -rf dist/Webby.app`.
missing_identity_leaves_dist() {
  local tmp stub before after err
  tmp="$(mktemp -d)"
  stub="$tmp/stub"
  mkdir -p "$tmp/scripts" "$tmp/mac" "$tmp/dist/Webby.app/Contents/MacOS" "$stub"
  cp "$root/scripts/build-app.sh" "$tmp/scripts/build-app.sh"
  printf 'previous build\n' > "$tmp/dist/Webby.app/Contents/MacOS/Webby"
  printf '<plist/>\n' > "$tmp/dist/Webby.app/Contents/Info.plist"
  cat > "$stub/security" << 'STUB'
#!/bin/sh
echo '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Someone Else (ABCDE12345)"'
echo '     1 valid identities found'
STUB
  cat > "$stub/swift" << STUB
#!/bin/sh
touch "$tmp/swift-ran"
[ "\$*" = "\${*%--show-bin-path}" ] || echo "$tmp/bin"
exit 0
STUB
  chmod +x "$stub/security" "$stub/swift"
  digest() {
    (cd "$tmp/dist" && find . -print0 | LC_ALL=C sort -z | xargs -0 stat -f '%N %p %i %m %z' \
      && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256)
  }
  before="$(digest)"
  if err="$(env -u WEBBY_SIGN_IDENTITY -u WEBBY_TEAM_ID -u WEBBY_BUILD_NUMBER -u WEBBY_ARCHS PATH="$stub:$PATH" \
            "WEBBY_SIGN_IDENTITY=$developer_id" WEBBY_TEAM_ID=ABCDE12345 WEBBY_BUILD_NUMBER=1 WEBBY_ARCHS=arm64 \
            "$tmp/scripts/build-app.sh" --release 2>&1 > /dev/null)"; then
    echo "FAIL: identity not in keychain: build-app.sh --release succeeded" >&2
    failures=$((failures + 1))
  elif [[ "$err" != *"no valid code-signing identity named '$developer_id'"* ]]; then
    echo "FAIL: identity not in keychain: expected the keychain refusal, got: $err" >&2
    failures=$((failures + 1))
  elif [[ -e "$tmp/swift-ran" ]]; then
    echo "FAIL: identity not in keychain: the build started before the refusal" >&2
    failures=$((failures + 1))
  else
    after="$(digest)"
    if [[ "$after" != "$before" ]]; then
      echo "FAIL: identity not in keychain: dist/Webby.app changed" >&2
      failures=$((failures + 1))
    else
      passed=$((passed + 1))
    fi
  fi
  rm -rf "$tmp"
}
missing_identity_leaves_dist

if [[ "$failures" -ne 0 ]]; then
  echo "test-build-app-release: $failures failed, $passed passed" >&2
  exit 1
fi
echo "Release mode refusals OK ($passed cases)"
