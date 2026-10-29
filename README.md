# Webby

Clear, customizable sticky notes that stick to any Mac app — or to an exact web page in Chrome — and are still there when you come back.

> Work in progress. See open pull requests for the build plan.

Design principles are in [design.md](design.md), and the skin directions moodboard is at <https://jynlee7.github.io/webby/>.

## Chrome notes (local build)

1. Run `scripts/build-app.sh`, then open `dist/Webby.app`. Keep the app at a stable
   path; moving it requires relaunching it to update Chrome's native host path.
2. In `chrome://extensions`, enable Developer mode and load the repository's
   `extension/` folder unpacked.
3. Choose **Enable Window Access…** from Webby's menu and grant Accessibility
   access in System Settings. Webby uses the focused window's bounds to position
   notes and to avoid showing an old page's notes over an unreported private window.
4. With Chrome frontmost, choose **New Chrome Note**. The scope menu offers this
   page, its path and parent paths, the whole site, and the Chrome app.

Notes save automatically and return when a matching page is active. App notes also
appear on internal and incognito pages; web notes do not appear in incognito.
Without a verified focused window, overlays are hidden. A save failure is shown
in Webby's menu; **Retry Saving Notes** retries without discarding the in-memory
edits, and quitting warns before any unsaved edits are lost.

See [Chrome integration validation](CHROME-VALIDATION.md) for the recorded browser
observations and remaining manual checks.
