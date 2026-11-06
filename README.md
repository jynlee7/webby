# Webby

Clear, customizable sticky notes that stick to any Mac app — or to an exact web page in Chrome — and are still there when you come back.

> Work in progress. See open pull requests for the build plan.

Design principles are in [design.md](design.md), and the skin directions moodboard is at <https://jynlee7.github.io/webby/>.

## Requirements and install

- macOS 14 or later, on Apple silicon or Intel (release builds are universal).
- Google Chrome, for web notes. Without Chrome, app notes still work.

There is no published release yet. Once there is, a release is a ZIP:

1. Unzip it and move **Webby.app** to `/Applications` or `~/Applications`. Webby registers
   its Chrome bridge only from there; launched from Downloads or a disk image it asks to be
   moved instead.
2. Open Webby and allow Accessibility when asked, so notes can follow app windows. Notes
   work without it, at fixed positions. Builds before 0.1.0 used the identifier
   `com.webby.app`, so the permission has to be granted again.
3. Webby copies its Chrome extension to `~/Library/Application Support/Webby/Extension`. In
   Chrome, open `chrome://extensions`, turn on **Developer mode**, choose **Load unpacked**
   and pick that folder. The extension ID must be `ccehhpjcbcabmlalclppmdomonfdcbcl`.
4. After updating Webby, press **Reload** on the Webby extension in `chrome://extensions`.

To build from source: `scripts/build-app.sh` (an ad-hoc signed development build in
`dist/`). Maintainers cut releases with [RELEASING.md](RELEASING.md).

## Chrome notes (local build)

1. Run `scripts/build-app.sh`, then open `dist/Webby.app`. Keep the app at a stable
   path; moving it requires relaunching it to update Chrome's native host path.
2. In `chrome://extensions`, enable Developer mode and load unpacked the folder Webby
   copies at launch, `~/Library/Application Support/Webby/Extension` (the repository's
   `extension/` folder has the same ID and also works for extension development).
3. In Webby's **Settings…**, choose **Allow Accessibility…** and grant access in
   System Settings. Webby uses the focused window's bounds to position notes and to
   avoid showing an old page's notes over an unreported private window.
4. With Chrome frontmost, choose **New Note in Google Chrome** from Webby's menu. A
   new note sticks to this page; its ⋯ menu offers **Stick To** with the page's path
   and parent paths, the whole site, and the Chrome app.

Notes save automatically and return when a matching page is active. App notes also
appear on internal and incognito pages; web notes do not appear in incognito.
Web notes need a focused Chrome window whose Accessibility bounds match the bounds
the extension reported. Without that, Chrome gets its app context: web notes are
hidden and Chrome app notes stay at their stored offsets, which are then read as
screen positions. A save failure is shown in Webby's menu; **Retry Saving** retries
without discarding the in-memory edits, and quitting warns before unsaved edits
are lost.

See [Chrome integration validation](CHROME-VALIDATION.md) for the recorded browser
observations and remaining manual checks.
