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
