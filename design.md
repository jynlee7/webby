# Webby design principles

**Status: proposed.** These principles come from the skin directions moodboard of
27 Oct 2026. None of the visual design is built yet. [plan.md §5.4](plan.md#54-skins-osu-style)
owns the skin format, its checks and the accessibility rules. This file covers how notes
should look and behave, and the rules every skin should follow. Where the two disagree,
plan.md wins until a PR changes it.

The moodboard is published from [`site/`](site/) at <https://jynlee7.github.io/webby/>. It
renders every direction live, includes a skin lab that runs the import checks in the
browser and downloads any skin as a `.webbyskin`, and links to the 64 posts on X that
these rules came from.

## Principles for every note

1. **On the page, not part of it.** A note is an object placed over a page or an app. It
   must never look like that site's own UI. Each direction gets there in its own way: glass
   bends the page underneath, paper is taped down with a short hard shadow, an instrument
   tag clips on. The look has to hold over any background, light or dark, busy or plain.

2. **Readable before glossy.** Contrast comes before any effect.
   ([on Tahoe icon quality](https://x.com/flarup/status/1937043000410173813),
   [fishbowl glass in Metal](https://x.com/Codelaby/status/2028435064980136420))
   - Every text and fill pair meets 4.5:1, measured with the fill composited over both
     white and black, because the page behind a note is unknown. The 3:1 floor applies
     only to WCAG large text. The engine raises fill opacity to the floor
     ([plan §5.4.7](plan.md#547-accessibility)).
   - Texture goes in the edges, header, collapsed bar and decoration, never under body
     text. Any grain under text stays at or below 4% luminance variance. Check contrast
     against the darkest pixel, not the average fill.
   - Reduce Transparency switches to an opaque fill with no blur. Increase Contrast applies
     the skin's `highContrast` overrides. Accessibility settings are applied last and
     always win.
   - Handwriting, pixel, dot-matrix and LCD faces are for short labels and PNG art, never
     for long note text.

3. **One light, top left.** Every highlight on notes, buttons, the voice orb and the app
   icon comes from one source, about 45° from the top left. A highlight that disagrees
   with the others looks like a sticker. Add gloss only where it explains an edge.
   ([Figma's Glass panel](https://x.com/figma/status/2016198567631978909),
   [on the macOS specular angle](https://x.com/1000kilobytes/status/2056734658134778039))

4. **Motion only at the moments that matter.** Shapes animate when a note is created,
   collapsed or merged, and at no other time. Typing, dragging, scrolling and menus respond
   instantly. Most effects finish within about 250 ms. The longest is Clear's collapse
   spring, about 480 ms with a slight overshoot. With Reduce Motion on, changes are
   instant or cross-fade, and the orb holds its first frame. Skins supply frames, but
   Webby controls the timing.
   ([GlassEffectContainer morphing](https://x.com/SwiftyAlex/status/1932779330977083516),
   [on instant interfaces](https://x.com/shadcn/status/2096797264370950464))

5. **One idea per skin.** Use one material, one accent or signal colour, one decoration
   and one era. The paper, graphite, retro and hardware directions all warn about the same
   failure: textures, glows, stickers or eras piled up until the note reads as clutter.

6. **Decoration is passive.** Tape, stickers, plates and clips are never clickable. They
   never cover the first line or the icons, and nothing should look like a control that
   does nothing. Decorations and orb frames are hidden from VoiceOver. Icon hit areas stay
   at least 20×20 pt, whatever the artwork.

7. **Quiet sound.** Sounds are short, dry and quiet: about 300 ms or less, with no music
   and no reverb tails. Webby should follow the system setting for user interface sound
   effects.

8. **Evoke, don't copy.** Skins call up materials and eras with original artwork and
   generic names, such as "Desk Accessory" rather than "Mac OS 9". Skins don't use logos,
   system icons, trade dress, product names, system sounds or wallpapers. Built-in and
   featured skins use only original or licensed art.

## Clear Glass, the default

`webby.clear` is the default skin and the fallback for every other skin. It follows the
principles above most strictly and adds two of its own:

- **Lens, not sheet.** A note bends the page underneath it instead of covering it, so you
  keep your place. Text sits on a frosted inner layer, which keeps it readable over any
  page. ([Wait Until the Glass Starts Moving](https://x.com/HeyLabii/status/2099744554446630949),
  [Liquid DOM](https://x.com/AndrewPrifer/status/2056923983581446529))
- **Refraction should do a job.** Glass can reveal as well as decorate. Proposed: holding
  ⌥ over a note makes it fully clear, so you can read the page underneath (Peek).
  ([refraction as interaction](https://x.com/ty_kra_lab/status/2026334579091489103),
  [shading on a foldable](https://x.com/sentry_fka/status/2097901446108688583))

The amount of frost increases with the amount of text:

| Level | Used for | Values |
| --- | --- | --- |
| Clear | Notes of three lines or fewer | Mostly refraction with a little frost: frost 2, fill at 45% of the default. The contrast floor still applies. |
| Frost | Everything else (default) | Frost 18, saturate 180%. The page shows only as colour and shape. |
| Solid | Reduce Transparency or Increase Contrast | The skin's `highContrast` surface, with no blur and no rim. |

Proposed tokens, in the `skin.json` format: fill `#FFFFFF80` light and `#16181DB8` dark;
tints Amber `#FFC86B66`/`#FFB3472E`, Rose `#FF9DB566`/`#FF7A9A2E`, Mint
`#8FE3B866`/`#4FD69A29`, Sky `#93C5FF66`/`#5AA9FF2E` and Lilac `#C3AEFF66`/`#A98BFF2E`;
note text in the system font at 14 on 20; corner radius 16. Over any page, black text on
white glass needs a fill of at least 50% to keep 4.5:1, and light text on dark glass
needs about 62%.

**Do**

- Keep text on frost. Save visible refraction for the rim and the collapsed bar.
- Light every highlight from the top left.
- Morph only on create, collapse and merge.
- Switch to the solid surface when Reduce Transparency or Increase Contrast is on.
- Let the tint pick up the page's colour, but limit its saturation so notes don't look
  like ads.

**Don't**

- Put body text over refraction that hasn't been frosted.
- Animate typing, dragging, scrolling or menus.
- Stack glass on glass. A note's menu over a note needs more frost, or it becomes
  unreadable.
- Add gloss to flat shapes.
- Use rainbow dispersion on anything smaller than the note's own edge.

**Platform.** Webby targets macOS 14 and later. The moodboard proposed system Liquid Glass
on macOS 26 and later, but plan.md decision 21 keeps Liquid Glass off note bodies because
the HIG keeps it out of the content layer. Either way, the look has to work without true
refraction.

## The other directions

| Direction | Status | Idea | What keeps it in check |
| --- | --- | --- | --- |
| Paper & Tape (`webby.paper`) | Built-in in v1.1, once its @2x artwork exists | Real stationery stuck onto the web: grainy paper with honest edges, tape, a short hard shadow, ink-coloured type | Opaque, no blur. The character is in the edges and tape, not the grain. One decoration. Dark mode uses carbon paper, not inverted cream. |
| Graphite (`webby.graphite`) | Built-in in v1.1 | A quiet instrument panel: tuned near-black greys, 1 pt hairlines, mono metadata, one signal colour | Body text stays at about 14:1. Low-contrast grey is for metadata only. One accent, no glow. Ships a light variant and a sans variant for long notes. |
| Retro OS | Sample skin | A desk-accessory window from 1991–2005, built from crisp PNG chrome | One era per skin. Texture only in the header and edges. Pixel art scaled by whole numbers and never rotated. Generic names and original drawings. |
| Field Instrument | Sample skin | A small, well-made device: a moulded housing, a recessed display, printed labels and one safety-orange light | Orange only for fills, LEDs and the caret, because it is 2.6:1 on the housing. Orange text uses `#B8410E`. Passive plates, no fake knobs. |
| Mono (`webby.mono`) | Built-in in v1 ([plan §5.4.8](plan.md#548-implementation)) | Minimal and high-contrast friendly | Not on the moodboard yet. |

Each direction's full palette, type, materials, motion, sound, skin recipe and risks are
on the moodboard.

## Skins by anyone

The rules for the format and for the moment a skin is installed. They draw on how osu!,
Winamp and Obsidian themes work, and on plan §4f and §5.4.

- **A skin is data, not code.** It is one `skin.json` plus PNG images and WAV sounds with
  fixed file names. It contains no scripts, network fetches or bundled fonts, and it names
  system fonts with fallbacks.
- **A few tokens give the full look.** Any group a skin leaves out falls back to its base,
  so a partial or broken skin never blanks a note. Surface and palette fall back together,
  so text and fill colours from different authors never mix.
- **Preview on the real surface.** Before anything is applied, the install sheet renders a
  real note (expanded, collapsed and with its decoration) in light, dark and high contrast.
  It lists credits, and it lists problems by file.
- **Safe to try.** Links and double-clicks never change the skin without the sheet. A new
  skin can always be undone. Built-in skins are protected; you duplicate one to edit it.
- **Credit everyone.** Credits with roles live in `skin.json` and show at install and in
  the Library. Exports are named `<Name> (<Author>).webbyskin`.
- **Sharing never includes notes.** Exporting or sharing a skin can't carry note content
  or screenshots of real notes.

## Open questions

- Should `surface.material` get a `glass` value, with a defined fallback on macOS 14 and 15?
- Should the light angle and rim fringe be skin tokens or fixed by the app, so every skin
  agrees with the system light?
- Is Peek (hold ⌥ to clear a note) worth a global key, given that notes are panels above
  Chrome?
- How much tint pick-up is allowed before a note stops looking like Webby's?
- Should decision 21 change, so notes use system Liquid Glass on macOS 26 and later?
