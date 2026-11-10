# Webby <version> release evidence

Copy this file to `release/evidence/<version>.md` for each release candidate. Run every row
in a dedicated macOS test account, never the maintainer's own account, notes or Chrome
profile. Use `$HOME` in paths. Never record note text, URLs or browsing history; screenshots
show only app chrome. A release is accepted only when every row is Pass, or Skipped with an
approved reason, and this file and the `release/history.json` entry have both merged.

## Artifact

| Field | Value |
|---|---|
| Version / build | |
| Commit | |
| Workflow run | |
| `Webby-<version>.zip` SHA-256 | |
| `Webby-Extension-<version>.zip` SHA-256 | |
| `extensionPayload` | |
| Tester | |

Paste trimmed output (no credentials) for the downloaded app:

```text
$ codesign -dv --verbose=4 Webby.app
$ codesign --verify --strict --deep --verbose=2 Webby.app
$ spctl -a -vvv Webby.app
$ xcrun stapler validate Webby.app
$ lipo -archs Webby.app/Contents/MacOS/Webby Webby.app/Contents/MacOS/webby-bridge
```

## Environments

| ID | Machine / chip | macOS build | Chrome version | Notes |
|---|---|---|---|---|
| E1 | clean macOS 14, arm64 | | | |
| E2 | current macOS, arm64 | | | |
| E3 | macOS 14, Intel x86_64 (required while universal builds are advertised) | | | |
| E4 | Chrome installed, never launched | | | |
| E5 | existing Chrome profile plus a second profile | | | |
| E6 | quarantined download launched from Downloads | | | |
| E7 | dirty upgrade from a 0.0.1 build (`com.webby.app`) | | | |

Reset between rows: quit and delete Webby, `tccutil reset Accessibility io.github.jynlee7.webby`,
remove `$HOME/Library/Application Support/Webby`, remove
`$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.webby.bridge.json`
and remove the unpacked extension. Never reset a Chrome profile destructively.

## Rows

Result is Pass, Fail or Skipped. Evidence is a short pointer (output excerpt, screenshot name).

| Row | Env | Check | #20 criterion | Result | Evidence / reason |
|---|---|---|---|---|---|
| I1 | E1 | Fresh ZIP install into `/Applications` launches | Clean install | | |
| I2 | E1 | First launch offline after stapling is accepted | Gatekeeper offline | | |
| I3 | E6 | Quarantined download accepted without bypass flags | Gatekeeper online | | |
| I4 | E1 | Identity, version, Team ID and architectures match `provenance.json` | Developer ID, runtime, timestamp, 0.1.0 | | |
| I5 | E2 | Runs from `~/Applications` as well as `/Applications` | Approved locations | | |
| X1 | E1 | Load unpacked from the copied folder gives `ccehhpjcbcabmlalclppmdomonfdcbcl` and a working bridge | Guided install, pinned ID | | |
| X2 | E1 | Without Chrome, no `NativeMessagingHosts` folder is created | No Chrome tree | | |
| X3 | E4 | Chrome installed but never launched: nothing written until its support folder exists | No Chrome tree | | |
| X4 | E5 | Existing profile: the manifest is rewritten only when needed, with a `.previous` backup | Registration recovery | | |
| X5 | E5 | Second profile connects through the same registration | Registration | | |
| X6 | E2 | App update refreshes the host path and asks for Reload | Never downgraded, Reload | | |
| X7 | E2 | Deleted or moved app is reported as dangling and re-registers from Applications | Dangling target | | |
| X8 | E2 | Malformed installed extension folder is preserved until Repair | Invalid install preserved | | |
| X9 | E5 | A profile reporting an older extension version shows Reload needed | Reload guidance | | |
| U1 | E6 | Translocated launch installs nothing and prompts Move to Applications | Translocation | | |
| U2 | E6 | Translocated launch keeps an existing working registration | Preserve registration | | |
| U3 | E2 | Non-quarantined launch from Downloads does not rewrite the manifest | Unstable path | | |
| U4 | E2 | Launch from a mounted disk image does not rewrite the manifest | Unstable path | | |
| U5 | E2 | A development build registers only under the development policy | Development selector | | |
| P1 | E1 | Accessibility denied: notes still work at fixed positions | Permissions | | |
| P2 | E1 | Accessibility allowed: notes follow app windows | Permissions | | |
| P3 | E7 | The bundle-ID change asks for Accessibility again; the old grant no longer applies | Re-consent | | |
| P4 | E7 | Notes, settings and skins survive the upgrade and rename | No data moved | | |
| P5 | E2 | Quitting and replacing the app never loses a note | Upgrade path | | |
| F1 | E2 | Web notes (#11) | Feature smoke | | |
| F2 | E2 | Tab notes and Closed tabs (#16) | Feature smoke | | |
| F3 | E2 | Skin import, selection and live edit (#19) | Feature smoke | | |
| F4 | E2 | Library grouping and search (#13) | Feature smoke | | |
| F5 | E2 | Export, import and `webby://` links (#15) | Feature smoke | | |
| R1 | E2 | An interrupted extension copy leaves the previous folder usable | Recoverable replacement | | |
| R2 | E2 | A failed host rewrite keeps the prior manifest | Registration recovery | | |
| R3 | E2 | Rolling back to the previous verified ZIP keeps notes and asks for the matching Reload | Rollback | | |
| R4 | — | A rejected notarization produced no downloadable artifact and no history entry | Release gate | | |

## Sign-off

| Role | Name | Date |
|---|---|---|
| Tester | | |
| Reviewer | | |
