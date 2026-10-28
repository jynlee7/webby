# Webby design principles

**Status: proposed.** These principles come from the skin directions moodboard of
27 Oct 2026. None of the visual design is built yet. [plan.md §5.4](plan.md#54-skins-osu-style)
owns the skin format, its checks and the accessibility rules. This file covers how notes
should look and behave, and the rules every skin should follow. Where the two disagree,
plan.md wins until a PR changes it.

The moodboard is published from [`site/`](site/) at <https://jynlee7.github.io/webby/>. It
renders every direction live and includes a skin lab that runs the import checks in the
browser and downloads any skin as a `.webbyskin`. The posts on X that these rules came
from are listed under [Sources](#sources).

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

## Sources

Collected on 27 Oct 2026 from public posts on X, grouped by the direction they informed.
The moodboard links to posts instead of copying their images or video, which belong to
their authors. Trademarked products appear only as references. Skins evoke materials and
eras and never copy logos, product names or system artwork (principle 8).

### Clear Glass

- [@uxuidesign](https://x.com/uxuidesign/status/2100038127691669680): quote of the seed
  post (16 Sep 2026)
- [@HeyLabii](https://x.com/HeyLabii/status/2099744554446630949): “Wait Until the Glass
  Starts Moving.”
- [@AndrewPrifer](https://x.com/AndrewPrifer/status/2056923983581446529): Liquid DOM
- [@figma](https://x.com/figma/status/2016198567631978909): “Do more with Glass”
- [@TheAppleDesign](https://x.com/TheAppleDesign/status/2027394686332387520): macOS glass
  concept
- [@flarup](https://x.com/flarup/status/1936884227049406685): Ghostty icon for Tahoe, and
  [on Tahoe icon quality](https://x.com/flarup/status/1937043000410173813)
- [@shadcn](https://x.com/shadcn/status/2096797264370950464): on glass and instant
  interfaces
- [@thetirthparmar](https://x.com/thetirthparmar/status/2070221314041036928):
  liquidglass-oss
- [@SwiftyAlex](https://x.com/SwiftyAlex/status/1932779330977083516): GlassEffectContainer
  morphing
- [@jh3yy](https://x.com/jh3yy/status/2016253370424553508): liquid glass with CSS and SVG,
  and [his cross-browser follow-up](https://x.com/jh3yy/status/2062991692941213798)
- [@abjt14](https://x.com/abjt14/status/2062934834402799710): Aave's glass on the web,
  including Safari
- [@Codelaby](https://x.com/Codelaby/status/2028435064980136420): fishbowl glass in Metal
- [@1000kilobytes](https://x.com/1000kilobytes/status/2056734658134778039): macOS 27
  specular angle, via [@LeakerApple](https://x.com/LeakerApple/status/2056850708918583454)
- [@ty_kra_lab](https://x.com/ty_kra_lab/status/2026334579091489103): refraction as
  interaction
- [@sentry_fka](https://x.com/sentry_fka/status/2097901446108688583): physical shading on
  a foldable

### Skins by anyone

- [@osuck_skins](https://x.com/osuck_skins/status/1744320884486119462): Community 'visual
  skin.ini editor' for osu! with live gameplay preview, local custom-skin upload by drag
  and drop, random colors, and skin.ini import/export. (8 Jan 2024)
- [@osuck_skins](https://x.com/osuck_skins/status/2070079704598560947): Skin release card
  listing aspect ratio, modes, size, release date and authors by role (sofram as Creator,
  MALISZEWSKI as Mixer), with the same four standard preview scenes every listing uses.
  (25 Jun 2026)
- [@captbaritone](https://x.com/captbaritone/status/1301551041784152064): Launch of the
  Winamp Skin Museum: infinite scroll through 65k skins with instant search; clicking one
  opens it live in Webamp with Download, Share and Report as NSFW links (seen at the end
  of the video). (3 Sep 2020)
- [@OldInternetFeel](https://x.com/OldInternetFeel/status/2073562372245954780): A fan-made
  Zelda Winamp skin resurfacing in 2026 and drawing about 1.8k likes; pure bitmap art, no
  code. (5 Jul 2026)
- [@obsdmd](https://x.com/obsdmd/status/2054234821875146898): Obsidian launched a
  directory for plugins and themes with author pages, screenshots, automated scans of
  every version, safety scorecards and capability disclosures. (12 May 2026)
- [@DylanMcD8](https://x.com/DylanMcD8/status/2075986736211951964): A developer discovers
  Xcode's new full color themes: a presets popover of miniature editor renders with Import
  in the same place. (11 Jul 2026)
- [@OpenAIDevs](https://x.com/OpenAIDevs/status/2032222631538409728): OpenAI added themes
  to the Codex app: pick built-ins, import themes you like, or share your own. (12 Mar
  2026)
- [@discord](https://x.com/discord/status/1963695484587196735): Discord launched Nitro
  custom themes: pick up to 5 colors and gradients and the entire client updates live. (4
  Sep 2025)
- [@linuz90](https://x.com/linuz90/status/2090094649482588356): A designer releases mnml,
  a quieter, more native-feeling fork of kepano's Minimal theme, crediting the original in
  the post and repo. (19 Aug 2026)
- [@iamdothash](https://x.com/iamdothash/status/2088308309476401242): A site of 3,088
  wallpapers, each with five generated theme variants, applied from the browser through a
  deep link or opened in the Aether editor to tweak. (14 Aug 2026)

### Paper & Tape

- [@jh3yy](https://x.com/jh3yy/status/2113040509966905792): Jhey's CSS/WebGL sticker
  playground, with separate materials (holo, glitter, vinyl), peel-off curls, sounds and
  wear marks. (21 Oct 2026)
- [@DannPetty](https://x.com/DannPetty/status/2112945791451193459): Dann Petty's portfolio
  leaves a faint 'sticky residue' outline wherever a card is lifted and moved. (21 Oct
  2026)
- [@stephenhaney](https://x.com/stephenhaney/status/2105007065106419936): Launch of
  Paper's rebuilt open-source paper shader, with fold lines, wrinkles, crumples, stripes,
  fibre and grain, shown as a cut-paper collage. (29 Sep 2026)
- [@nullbytes00](https://x.com/nullbytes00/status/2093755659628245221): Hold My Notes, an
  indie Mac sticky-notes app whose notes sit on the screen edge as labelled index tabs and
  peek out on hover. (29 Aug 2026)
- [@claudeai](https://x.com/claudeai/status/2111177838208377213): A demo that turns 120
  photographed notebook pages into a working handwriting font, presented entirely on ruled
  paper. (16 Oct 2026)
- [@pavlikgavrik](https://x.com/pavlikgavrik/status/2070067556715516014): Pavel Haimi's
  Figma risograph plugin, which uses real riso ink colour profiles and outputs
  misregistered halftone. (25 Jun 2026)
- [@keeyeny](https://x.com/keeyeny/status/1509948118657163267): Keeyen's washi tape
  designs for the FigJam washi tape launch, with patterns drawn from the editor's own UI
  elements. It's from 2022, older than the other refs, but the best tape reference found.
  (1 Apr 2022)
- [@jh3yy](https://x.com/jh3yy/status/2093865435603050655): Jhey's WebGL experiment that
  crumples a real HTML dialog into a paper ball when you discard it. (30 Aug 2026)
- [@codrops](https://x.com/codrops/status/2064331146956046759): Codrops feature on an
  interactive digital stamp collection with perforated stamps, postcards, shaders and a
  loupe for close inspection. (9 Jun 2026)
- [@excalidraw](https://x.com/excalidraw/status/2098076009027260626): Excalidraw shipping
  native sticky notes, with a hand-drawn wobble, a hard offset shadow and an automatic
  date stamp. (10 Sep 2026)

### Graphite

- [@linear](https://x.com/linear/status/2032145903578923156): Linear's 2026 interface
  refresh, announced as reducing noise and bringing structure back into focus. (12 Mar
  2026)
- [@iamdavidhill](https://x.com/iamdavidhill/status/2009254964908953995): David Hill shows
  opencode's pull-up keyboard cheatsheet, which you can open without leaving your flow and
  which tracks the shortcuts you have already used. (8 Jan 2026)
- [@adamdotdev](https://x.com/adamdotdev/status/1931382361477755198): Adam previews the
  opencode rewrite, which he calls his best TUI work yet. (7 Jun 2025)
- [@dkundel](https://x.com/dkundel/status/2037552817385467967): Dominik Kundel shows that
  the Codex app now accepts a matching Raycast theme, with dark mode as the highlight. (27
  Mar 2026)
- [@witsdev](https://x.com/witsdev/status/2093336820625060276): wits walks through how the
  new Vercel dashboard deployment filters were designed and engineered. (28 Aug 2026)
- [@buddyhadry](https://x.com/buddyhadry/status/2075285379943366891): Buddy Hadry launches
  Sidebridge, a native Swift sidebar that follows your active pane and shows what changed
  since you last looked. (9 Jul 2026)
- [@dominikmartn](https://x.com/dominikmartn/status/2112166646706319783): Dom's terminal
  redesign, made after Warp went open source and later released as Harp, with a compact
  legend of agent states. (19 Oct 2026)
- [@pablostanley](https://x.com/pablostanley/status/2077812435411767359): Pablo Stanley's
  tiny keyboard-driven TUI for downloading videos, with a clickable box-drawn UI. (16 Jul
  2026)
- [@charlieholtz](https://x.com/charlieholtz/status/1945870105109246401): Charlie Holtz
  introduces Conductor, a Mac app for running parallel Claude Code agents in isolated
  workspaces. (17 Jul 2025)
- [@samko_cx](https://x.com/samko_cx/status/1967762244265243056): Sam Ko announces that a
  Vercel theme now ships inside Ghostty 1.2. (16 Sep 2025)

### Retro OS

- [@ryolu_](https://x.com/ryolu_/status/1920230279773323267): Ryo Lu shows ryOS's AI chat
  persona of himself running inside a 1-bit, System 7-style window. (7 May 2025)
- [@ryolu_](https://x.com/ryolu_/status/1996620858497159658): Ryo Lu's 'consistency is not
  uniformity' post argues that Aqua's lickable buttons and sheets taught real mental
  models. It's shown with ryOS's brushed-metal player playing the Aqua introduction. (4
  Dec 2025)
- [@LundukeJournal](https://x.com/LundukeJournal/status/2011987063755907579): The Lunduke
  Journal shares MondySpartan's 2026 concept of a themed, graphite Mac OS 9 with a Notes
  app and calls it better-looking than modern desktops. (16 Jan 2026)
- [@tehmondspartan](https://x.com/tehmondspartan/status/2039182355152425094): MondySpartan
  reimagines Discord as a 2005 instant messenger with XP silver-style chrome. (1 Apr 2026)
- [@SamGuichelaar](https://x.com/SamGuichelaar/status/1976349140557984212): Sam Guichelaar
  themes macOS 26 to look like Snow Leopard with the Glow tool, which requires disabling
  SIP. (9 Oct 2025)
- [@BasicAppleGuy](https://x.com/BasicAppleGuy/status/1876404044438355973): Basic Apple
  Guy marks Aqua's 25th anniversary with screenshots of the original Mac OS X interface.
  (6 Jan 2025)
- [@pixquare_app](https://x.com/pixquare_app/status/2074892625539367258): Pixquare shows
  its pixel-art editor's UI themes, each a full repaint of the pixel chrome and icons. (8
  Jul 2026)
- [@tacocrepe](https://x.com/tacocrepe/status/1952062172340654571): tacocrepe's free
  'Windy XP' stream overlay redraws XP windows as pixel art. (3 Aug 2025)
- [@paolino](https://x.com/paolino/status/2094334032267899311): Carmine Paolino's native
  Spotify client loads any classic Winamp 2 skin and renders it as a period-accurate mini
  player with integer pixel scaling. (31 Aug 2026)
- [@aquavoice](https://x.com/aquavoice/status/2110819161727185341): Aqua Voice introduces
  Aqua Pet, a pixel pet on the macOS desktop that 'throws' your dictated words into the
  text field, with unlockable outfits and colors. (15 Oct 2026)

### Field Instrument

- [@mike_matas](https://x.com/mike_matas/status/2020850857819205700): Mike Matas
  (LoveFrom) unveils the Ferrari Luce interior, where tactile switches, glass keys and
  digital gauges were designed as one interface across industrial, interaction, type and
  sound design. (9 Feb 2026)
- [@juanbuis](https://x.com/juanbuis/status/2020926284118049095): Hands-on clip praising
  how every button and switch in the Ferrari Luce sounds, and the choice of real tactile
  controls over a touchscreen. (9 Feb 2026)
- [@nothing](https://x.com/nothing/status/2092195279114264652): Nothing announces Nothing
  OS 5.0. Its new clock faces set text, pill-shaped tokens and icons together on one
  monospaced grid. (25 Aug 2026)
- [@mrblackstudio](https://x.com/mrblackstudio/status/1922392009794265528): Lee Black
  shares Framer components built on Dieter Rams principles: knobs, toggles, sliders and
  buttons in white plastic with orange signals. (13 May 2025)
- [@emrekayganaci](https://x.com/emrekayganaci/status/1920437826153558451): Emre shows the
  dot-matrix and halo-light UI of the Somvai nap timer, where a ring of dots counts down
  the remaining time. (8 May 2025)
- [@streamlinehq](https://x.com/streamlinehq/status/1947651093795942857): Streamline
  highlights the dot-matrix UI icons Arkotype and Cory Schmitz designed for the game
  C-Smash VRS. (22 Jul 2025)
- [@iampetrknoll](https://x.com/iampetrknoll/status/1888904836516663529): Petr Knoll's CSS
  box-shadow experiment: a skeuomorphic push button that sinks into its housing when
  pressed. (10 Feb 2025)
- [@avstorm](https://x.com/avstorm/status/1820859577644302499): Andreas Storm praises the
  OP-1 field UI colours: muted blue, tan, grey and red labels with thin line art on a
  black screen. (6 Aug 2024)
- [@colderoshay](https://x.com/colderoshay/status/1782484051351437381): Cole's post on
  Teenage Engineering's screen UI, with close-ups of device displays including the TP-7
  field recorder. (22 Apr 2024)
- [@ilyamiskov](https://x.com/ilyamiskov/status/1744556590420705717): Ilya Miskov collects
  the EP-133 K.O. II icon set, which mixes segment-display digits with flat red, pink and
  blue pictograms. (9 Jan 2024)
