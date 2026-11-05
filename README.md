# Webby

Clear, customizable sticky notes that stick to any Mac app — or to an exact web page in Chrome — and are still there when you come back.

> Work in progress. See open pull requests for the build plan.

Design principles are in [design.md](design.md), and the skin directions moodboard is at <https://jynlee7.github.io/webby/>.

## Chrome notes (local build)

1. Run `scripts/build-app.sh`, then open `dist/Webby.app`. Keep the app at a stable
   path; moving it requires relaunching it to update Chrome's native host path.
2. In `chrome://extensions`, enable Developer mode and load the repository's
   `extension/` folder unpacked.
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
