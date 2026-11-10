# Releasing Webby

This runbook produces a Developer ID signed, notarized and stapled Webby ZIP plus the
standalone extension ZIP, then proves them on clean machines before anyone calls the
release accepted. The workflow uploads workflow artifacts only. It never creates a GitHub
Release, tag, commit or deployment, and it never writes `release/history.json`.

Status: the workflow and scripts exist, but no release has run yet. The Apple membership,
Team ID, signing identity, notary key and the `release` environment are not confirmed.

## 1. Prerequisites (once)

- An active Apple Developer Program membership and its 10-character Team ID.
- A **Developer ID Application** certificate with its private key, exported as `.p12`.
- An App Store Connect API key for notarization (`.p8`, key ID, issuer ID). It is scoped and
  revocable, so it is preferred over an Apple ID app password.
- A GitHub environment named `release`: required reviewer `jynlee7`, deployment branch
  `main` only, and these secrets (names only; values never enter the repository or logs):

  | Secret | Value |
  |---|---|
  | `WEBBY_TEAM_ID` | Team ID |
  | `WEBBY_SIGNING_P12_BASE64` | `base64 -i DeveloperID.p12` |
  | `WEBBY_SIGNING_P12_PASSWORD` | the `.p12` export password |
  | `WEBBY_NOTARY_KEY_P8_BASE64` | `base64 -i AuthKey_XXXX.p8` |
  | `WEBBY_NOTARY_KEY_ID` | API key ID |
  | `WEBBY_NOTARY_ISSUER_ID` | API issuer ID |

- Artifact retention is 90 days (set in the workflow). Pull requests and the `ci` job never
  see these secrets; there is no `pull_request_target` workflow.

## 2. Pre-release PR

1. Bump `Webby.version` (`mac/Sources/WebbyCore/Webby.swift`), `CFBundleShortVersionString`
   and `extension/manifest.json` together. Any extension payload change needs a new
   marketing version.
2. Pick the build number: higher than every `build` in `release/history.json` (the first
   release is build `1`).
3. Run locally: `scripts/check-version-identifiers.sh`, `scripts/test.sh --parallel`,
   `scripts/build-app.sh`, `scripts/verify-artifact.sh dist/Webby.app`,
   `scripts/check-extension.sh --app dist/Webby.app`.
4. Run the feature smoke rows (F1–F5 in `release/evidence/TEMPLATE.md`) on a development
   build in a test account.
5. Draft release notes (section 7). Merge only with a green `ci`.

## 3. Dry run, then the real run

1. Actions → Release → Run workflow on `main` with `version`, `build`, `confirm=release` and
   `dry_run` checked. The `preflight` job checks the ref, the clean tree, the version against
   `Webby.version`, the build against history, and that `ci` succeeded for the commit. A dry
   run stops there: no signing, no secrets, no upload.
2. Run again with `dry_run` unchecked. The `release` job waits for the environment reviewer,
   then: imports the `.p12` into a keychain under `$RUNNER_TEMP`; runs
   `scripts/build-app.sh --release` (bridge signed before the app, hardened runtime, secure
   timestamp, arm64 + x86_64); submits a temporary ZIP with
   `xcrun notarytool submit --wait`; requires `Accepted`; staples and validates the app;
   makes the final ZIP; re-extracts it and runs
   `scripts/verify-artifact.sh --release --team-id … --spctl` plus `stapler validate`; and
   uploads `Webby-<version>.zip`, `Webby-Extension-<version>.zip`, `SHA256SUMS` and
   `provenance.json`. The keychain and key files are deleted under `always()`.

### A rejected notarization

The job prints only the submission ID, the status and the issue summaries. Fetch the full
log on a trusted Mac with `xcrun notarytool log <id> --key … --key-id … --issuer …`. Common
causes: a missing timestamp, an unsigned nested binary, or an entitlement such as
`get-task-allow`. Fix on a PR and dispatch again with a **higher build number**. Two
rejections in a row abort the release (section 8).

## 4. Verify the downloaded artifacts

On a Mac, in a scratch folder:

```sh
shasum -a 256 -c SHA256SUMS
ditto -x -k Webby-<version>.zip .
codesign --verify --strict --deep --verbose=2 Webby.app
codesign -dv --verbose=4 Webby.app        # Authority, TeamIdentifier, Timestamp, flags=runtime
spctl --assess --type execute --verbose=4 Webby.app
xcrun stapler validate Webby.app
lipo -archs Webby.app/Contents/MacOS/Webby Webby.app/Contents/MacOS/webby-bridge
```

Compare the hashes, architectures and commit with `provenance.json`.

## 5. Clean-machine matrix and evidence PR

Copy `release/evidence/TEMPLATE.md` to `release/evidence/<version>.md` and run every row in
dedicated macOS test accounts, never the maintainer's own account, notes or Chrome profile.
Record Pass, Fail or Skipped (with a reason) and a short evidence pointer per row. Paths use
`$HOME`; never record note text, URLs or browsing history. Open a PR with the evidence.

## 6. History PR

After the evidence PR merges, open a separate PR appending the accepted entry to
`release/history.json`: `version`, `build`, `commit`, `acceptedAt` (date), and the
`appZip`, `extensionZip` and `extensionPayload` SHA-256 values from `provenance.json`.
`scripts/check-version-identifiers.sh` validates the schema and ordering. A release is
accepted only when both PRs have merged.

## 7. Release notes and upgrades

State: the bundle identifier changed to `io.github.jynlee7.webby` in 0.1.0, so Accessibility
must be approved again (`tccutil reset Accessibility com.webby.app` clears the old entry);
notes, settings and skins stay in `~/Library/Application Support/Webby`; upgrades are quit,
replace the app in Applications, relaunch, then **Reload** the Webby extension in
`chrome://extensions` (unpacked extensions do not update themselves).

## 8. Abort and rollback

- Abort on a red `ci`, two rejected notarizations, an install or registration matrix
  failure, or a version/history mismatch.
- Never delete a published artifact, retag or rewrite history; ship a higher build instead.
- Rollback means reinstalling the previous verified ZIP and reloading its matching extension.
  Notes are unaffected.
