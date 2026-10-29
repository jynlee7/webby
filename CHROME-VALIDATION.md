# Issue #11: Chrome notes validation

## Real browser observations

Recorded on 2026-10-28 using Google Chrome for Testing 153.0.8010.12 on macOS,
in a disposable profile and a temporary extension with `tabs` permission. No
personal browser profile or notes were used. The probe's extension used Webby's
`protocol.js` to encode the captured events. All temporary browser processes and
profile directories were removed afterward.

- Navigating to `https://bücher.invalid/example` produced
  `tab.url = "https://xn--bcher-kva.invalid/example"`; `tab.title` was
  `"bücher.invalid"`. Chrome sends the ASCII/Punycode host, independently of its
  display title. This change leaves PageURL's existing normalization intact.
- `chrome.windows.getAll` returned `{left:120, top:140, width:1000, height:700}`.
  `CGWindowListCopyWindowInfo` for that same isolated browser process returned
  `{X:120, Y:140, Width:1000, Height:700}`. The display's AppKit frame was
  1470×956 points with `backingScaleFactor = 2`. Chrome's bounds are top-left
  screen coordinates in logical points, not physical Retina pixels.
- The recorded activation initially had an empty URL, followed by a `tabUpdated`
  containing the URL. The monitor handles that transition without reusing the
  preceding page's identity.

[The recorded stream](extension/tests/fixtures/browser-recording.json) captures
inventory, activation, URL/title updates, navigation and closure. The Swift replay
test decodes the wire JSON and checks the resulting page context. The
[incognito-enabled recording](extension/tests/fixtures/browser-incognito-recording.json)
and [incognito-disabled recording](extension/tests/fixtures/browser-incognito-denied-recording.json)
exercise real private-window transitions at exactly the same bounds as the normal
window. With access enabled, Chrome reported `incognito: true`; with access disabled,
the inventory omitted the private window and marked the normal window unfocused.
Replay tests assert app-only visibility and app-only note creation in both cases.
Additional synthetic replay tests cover unavailable/mismatched bounds, overlapping
profile IDs, reconnect ownership, restart persistence, prefix boundaries and
separate YouTube videos. These synthetic cases are not claimed as live recordings.

## Implementation boundaries

Window verification requires Accessibility access. Denial, revocation, unknown
bounds, conflicting profile focus reports and disconnected bridges fall back to
app context. If no focused frame is available, overlays are hidden. The extension
sends fresh inventories on focus loss, bounds changes and window removal, so an
inaccessible incognito window clears the last normal page even when its bounds
happen to be identical. Incognito context never supplies a page or tab to note
creation. App notes remain eligible in verified incognito windows.

The monitor polls the focused window every 100 ms, with bounded AX messaging time,
and places notes relative to that window. Chrome only reports committed bounds;
web notes may briefly hide during a window move until the extension catches up.

## Validation

- Swift tests: full suite, plus browser replay and cross-actor save-request tests.
- Extension: Node tests, syntax, manifest and pinned host/extension identity checks.
- Import/macro checks; release app packaging and ad-hoc signature verification.
- ShellCheck unavailable in this environment.

Still needs an interactive acceptance pass with the packaged app: Accessibility
permission changes, typing/dragging notes, full-screen and multiple displays,
multiple Chrome profiles, and switching between normal and incognito windows
with extension incognito access both enabled and disabled. API observations above
are real; they do not substitute for that end-to-end UI pass.
