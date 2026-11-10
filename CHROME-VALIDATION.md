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
Chrome's app context: web notes are hidden, while Chrome app notes still show.
Without a window frame those app notes are placed at their stored offsets read as
screen coordinates, as for any app without Accessibility. The extension sends fresh
inventories on focus loss, bounds changes and window removal, so an inaccessible
incognito window clears the last normal page even when its bounds happen to be
identical. Incognito context never supplies a page or tab to note creation. App
notes remain eligible in verified incognito windows.

`ContextMonitor` reads the focused window's frame through Accessibility when the
frontmost app changes and on window focus, move and resize notifications, with a
bounded AX messaging time, and places notes relative to that window. Chrome only
reports committed bounds; web notes may briefly hide during a window move until
the extension catches up.

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

## Issue #16: tab notes across a Chrome restart

Recorded on 2026-11-07 with Chrome for Testing 157.0.8103.38 on macOS, in a
disposable profile with "Continue where you left off" turned on and the extension
loaded unpacked. The packaged app was built from a temporary copy whose storage,
socket and Chrome folder pointed at temporary directories, and which treated Chrome
for Testing as Chrome. The app wrote the host manifest into the profile's
`NativeMessagingHosts` folder, and Chrome started the bridge from it. Without
Accessibility, the copy read the front window's frame from the window list. Chrome
was quit through DevTools (`Browser.close`), not the menu, and relaunched with
`open`. No personal profile or notes were used.

- **Quit.** One window with five tabs once sent `tabClosed` with
  `windowClosing: true` for the active tab only, and the process ended 0.09 s later.
  Another time the same five tabs sent five such closures within 11 ms, and the
  process ended 0.2 s after the first. Two windows sent none before the bridge disconnected, and the process ended
  0.12 s later. Every closure fell well inside the 3 s quit window. The termination
  notification kept the launch date, so it named the run that ended.
- **Restore.** Across three restores, `hello` arrived 0.9 to 3.8 s after launch. The
  first `inventory`, 1 to 4 ms later, already listed every restored window and tab
  with its URL. Background tabs that hadn't loaded yet had their address as the title,
  for example `127.0.0.1:8766/dup.html`. `active` followed only when a restored window
  had focus. No later inventory came from `windows.onCreated`, because the restored
  windows existed before the worker connected. Background tabs then sent title-only
  `tabUpdated` messages 1.9 to 2.9 s after `hello`. The check ran 3.0 s after the
  last one, 4.9 to 5.9 s after `hello`, so the quiet period ended every wait. The 30 s
  cap was never close.
- **Restarted while Webby was down.** The bridge replayed `hello` and `inventory`
  0.9 s after Webby started, and the check ran 3.0 s later.
- **Outcomes.** A tab with a unique URL re-attached with the "Restored" badge,
  including one in the background window. Two tabs with the same URL, and one tab
  that two old tabs claimed, left their notes in Closed Tabs. A tab the user closed
  stayed closed. Reattach and Keep on This Tab worked. Navigating across three hosts,
  closing tabs, relaunching Webby, two Chrome restarts, Reattach and Keep never
  changed a note's `revision` or `updatedAt`.
- **A note on a new tab across a Webby relaunch.** In headless Chrome for Testing, a
  new tab sent only `tabCreated`, `active` and `tabUpdated`. The inventory the bridge
  replayed to the relaunched app predated the tab, so its note moved to Closed Tabs
  while the tab stayed open. A new tab now sends an inventory as well, and the note
  stays on its tab.
- **Other processes with Chrome's bundle ID.** A browser started outside
  LaunchServices, as test tools start one, has no launch date, and its exit still
  posts `didTerminateApplicationNotification`. Such exits are now ignored. Before,
  one closed every tab note of the Chrome that was still running.

[The recorded restore](extension/tests/fixtures/browser-session-restore-recording.json)
is the two-window restore as the app received it, with the profile key replaced by
the tests' key. `background.test.js` checks that the worker emits it from the same
restored windows. `TabBindingReconcilerTests` replays it with the measured arrival
times through the restore schedule and matcher. It replaces a synthetic sequence that
had the restored background window arrive in a second inventory.

Not covered: quitting from Chrome's menu, branded Google Chrome, Accessibility
window frames, several Chrome profiles, and the restore offered after a crash.
