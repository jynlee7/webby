import Foundation
import Testing
@testable import WebbyCore

private let planExampleJSON = #"""
{
  "$schema": "https://jynlee7.github.io/webby/schemas/webbyskin-1.json",
  "formatVersion": 1,
  "id": "io.github.jynlee7.frosted-kraft",
  "name": "Frosted Kraft",
  "author": "jynlee7",
  "version": "1.2.0",
  "description": "Kraft paper with washi tape; frosted glass in dark mode.",
  "license": "CC-BY-4.0",
  "credits": [{ "name": "A. Artist", "role": "tape artwork" }],
  "basedOn": null,
  "base": "webby.clear",
  "tags": ["paper", "warm"],
  "appearances": ["light", "dark"],
  "palette": [
    { "light": "#F3E2B8", "dark": "#2B2620" },
    { "light": "#FFD6E0", "dark": "#3A2A30" },
    { "light": "#CDEBFF", "dark": "#22303A" }
  ],
  "surface": {
    "fill":     { "light": "#F3E2B8E6", "dark": "#2B2620CC" },
    "material": { "light": "none", "dark": "hudWindow" },
    "image":    { "element": "note-body", "insets": { "top": 14, "left": 14, "bottom": 18, "right": 14 },
                  "mode": "stretch", "tintWithPalette": true },
    "cornerRadius": 6,
    "border":   { "width": 1, "color": { "light": "#00000014", "dark": "#FFFFFF1F" } },
    "shadow":   "soft",
    "padding":  { "top": 10, "left": 12, "bottom": 12, "right": 12 },
    "text":     { "color": { "light": "#2A2118", "dark": "#F2EBDD" } },
    "placeholderColor": { "light": "#2A211880", "dark": "#F2EBDD80" },
    "selection": { "light": "#E8B04A66", "dark": "#E8B04A55" },
    "caret":     { "light": "#8A5A12",   "dark": "#F5C46B" }
  },
  "typography": { "font": { "family": "Avenir Next" }, "size": 14, "weight": "regular", "lineSpacing": 2 },
  "header":     { "height": 0 },
  "collapsed":  { "height": 24, "showsFirstLine": true },
  "decoration": { "element": "decoration", "anchor": "topCenter", "origin": "center",
                  "offset": { "x": 0, "y": -2 }, "rotation": -3 },
  "icons":      { "template": true, "tint": { "light": "#2A2118B3", "dark": "#F2EBDDB3" } },
  "resizeHandle": { "visibility": "hover" },
  "library":    { "accent": { "light": "#B7791F", "dark": "#F5C46B" }, "sidebarMaterial": "sidebar", "cardStyle": "note" },
  "voiceOrb": { "states": {
    "idle":      { "frames": 1,  "fps": 0 },
    "listening": { "frames": 24, "fps": 24, "loop": true, "audioReactive": 0.15 },
    "thinking":  { "frames": 16, "fps": -1, "loop": true },
    "speaking":  { "frames": 24, "fps": 24, "loop": true, "audioReactive": 0.1 } } },
  "sounds": { "volume": 0.6, "mute": ["note-delete"] },
  "highContrast": {
    "surface.fill":       { "light": "#FFF6DD", "dark": "#1C1914" },
    "surface.text.color": { "light": "#000000", "dark": "#FFFFFF" }
  }
}
"""#

private func decodeManifest(_ json: String) throws -> SkinManifest {
    try JSONDecoder().decode(SkinManifest.self, from: Data(json.utf8))
}

@Test func planExampleDecodesEveryTokenGroup() throws {
    let manifest = try decodeManifest(planExampleJSON)

    #expect(manifest.schema == "https://jynlee7.github.io/webby/schemas/webbyskin-1.json")
    #expect(manifest.formatVersion == 1)
    #expect(manifest.id == "io.github.jynlee7.frosted-kraft")
    #expect(manifest.name == "Frosted Kraft")
    #expect(manifest.author == "jynlee7")
    #expect(manifest.version == "1.2.0")
    #expect(manifest.description == "Kraft paper with washi tape; frosted glass in dark mode.")
    #expect(manifest.license == "CC-BY-4.0")
    #expect(manifest.basedOn == nil)
    #expect(manifest.base == "webby.clear")
    #expect(manifest.credits == [SkinCredit(name: "A. Artist", role: "tape artwork")])
    #expect(manifest.tags == ["paper", "warm"])
    #expect(manifest.appearances == [.light, .dark])
    #expect(manifest.palette == [
        .paired(light: "#F3E2B8", dark: "#2B2620"),
        .paired(light: "#FFD6E0", dark: "#3A2A30"),
        .paired(light: "#CDEBFF", dark: "#22303A"),
    ])

    let surface = try #require(manifest.surface)
    #expect(surface.fill == .paired(light: "#F3E2B8E6", dark: "#2B2620CC"))
    #expect(surface.material == .paired(light: .known(.none), dark: .known(.hudWindow)))
    #expect(surface.image?.element == "note-body")
    #expect(surface.image?.insets == SkinInsets(top: 14, left: 14, bottom: 18, right: 14))
    #expect(surface.image?.mode == .known(.stretch))
    #expect(surface.image?.tintWithPalette == true)
    #expect(surface.cornerRadius == 6)
    #expect(surface.border == SkinBorder(width: 1, color: .paired(light: "#00000014", dark: "#FFFFFF1F")))
    #expect(surface.shadow == .known(.soft))
    #expect(surface.padding == SkinInsets(top: 10, left: 12, bottom: 12, right: 12))
    #expect(surface.text?.color == .paired(light: "#2A2118", dark: "#F2EBDD"))
    #expect(surface.placeholderColor == .paired(light: "#2A211880", dark: "#F2EBDD80"))
    #expect(surface.selection == .paired(light: "#E8B04A66", dark: "#E8B04A55"))
    #expect(surface.caret == .paired(light: "#8A5A12", dark: "#F5C46B"))

    #expect(manifest.typography == SkinTypography(
        font: SkinFont(family: "Avenir Next"),
        size: 14,
        weight: .known(.regular),
        lineSpacing: 2
    ))
    #expect(manifest.header == SkinHeader(height: 0))
    #expect(manifest.collapsed == SkinCollapsed(height: 24, showsFirstLine: true))
    #expect(manifest.decoration == SkinDecoration(
        element: "decoration",
        anchor: .known(.topCenter),
        origin: .known(.center),
        offset: SkinOffset(x: 0, y: -2),
        rotation: -3
    ))
    #expect(manifest.icons == SkinIcons(
        tint: .paired(light: "#2A2118B3", dark: "#F2EBDDB3"),
        template: true
    ))
    #expect(manifest.resizeHandle == SkinResizeHandle(visibility: .known(.hover)))
    #expect(manifest.library == SkinLibrary(
        accent: .paired(light: "#B7791F", dark: "#F5C46B"),
        sidebarMaterial: .known(.sidebar),
        cardStyle: .known(.note)
    ))

    let states = try #require(manifest.voiceOrb?.states)
    #expect(states.idle == SkinOrbAnimation(frames: 1, fps: 0))
    #expect(states.listening == SkinOrbAnimation(frames: 24, fps: 24, loop: true, audioReactive: 0.15))
    #expect(states.thinking == SkinOrbAnimation(frames: 16, fps: -1, loop: true))
    #expect(states.speaking == SkinOrbAnimation(frames: 24, fps: 24, loop: true, audioReactive: 0.1))
    #expect(states.error == nil)

    #expect(manifest.sounds == SkinSounds(volume: 0.6, mute: [.known(.noteDelete)]))
    #expect(manifest.highContrast == SkinHighContrast(
        surfaceFill: .paired(light: "#FFF6DD", dark: "#1C1914"),
        surfaceTextColor: .paired(light: "#000000", dark: "#FFFFFF")
    ))
}

@Test func sparseManifestLeavesOptionalGroupsAndMembersAbsent() throws {
    let manifest = try decodeManifest(#"""
    {"formatVersion": 1, "id": "io.example.sparse", "name": "Sparse", "author": "A", "version": "1.0.0"}
    """#)

    #expect(manifest.schema == nil)
    #expect(manifest.description == nil)
    #expect(manifest.license == nil)
    #expect(manifest.basedOn == nil)
    #expect(manifest.base == nil)
    #expect(manifest.credits == nil)
    #expect(manifest.tags == nil)
    #expect(manifest.appearances == nil)
    #expect(manifest.palette == nil)
    #expect(manifest.surface == nil)
    #expect(manifest.typography == nil)
    #expect(manifest.header == nil)
    #expect(manifest.collapsed == nil)
    #expect(manifest.decoration == nil)
    #expect(manifest.icons == nil)
    #expect(manifest.resizeHandle == nil)
    #expect(manifest.library == nil)
    #expect(manifest.voiceOrb == nil)
    #expect(manifest.sounds == nil)
    #expect(manifest.highContrast == nil)
}

@Test func emptyGroupsDoNotInventTokens() throws {
    let manifest = try decodeManifest(#"""
    {
      "formatVersion": 1, "id": "io.example.empty", "name": "Empty", "author": "A", "version": "1.0.0",
      "surface": {},
      "typography": {},
      "header": {},
      "collapsed": {},
      "decoration": {},
      "icons": {},
      "resizeHandle": {},
      "library": {},
      "voiceOrb": { "states": {} },
      "sounds": {}
    }
    """#)

    let surface = try #require(manifest.surface)
    #expect(surface.fill == nil)
    #expect(surface.material == nil)
    #expect(surface.image == nil)
    #expect(surface.cornerRadius == nil)
    #expect(surface.border == nil)
    #expect(surface.shadow == nil)
    #expect(surface.padding == nil)
    #expect(surface.text == nil)
    #expect(surface.placeholderColor == nil)
    #expect(surface.selection == nil)
    #expect(surface.caret == nil)

    #expect(manifest.typography == SkinTypography())
    #expect(manifest.header == SkinHeader())
    #expect(manifest.collapsed == SkinCollapsed())
    #expect(manifest.decoration == SkinDecoration())
    #expect(manifest.icons == SkinIcons())
    #expect(manifest.resizeHandle == SkinResizeHandle())
    #expect(manifest.library == SkinLibrary())
    #expect(manifest.voiceOrb?.states?.animations.isEmpty == true)
    #expect(manifest.sounds == SkinSounds())
}

@Test func scalarAndPairedColorsAndMaterialsAreDistinct() throws {
    let manifest = try decodeManifest(#"""
    {
      "formatVersion": 1, "id": "io.example.scalar", "name": "Scalar", "author": "A", "version": "1.0.0",
      "surface": {
        "fill": "#FFF200",
        "material": "none",
        "text": { "color": "#FFFFFF" }
      },
      "header": { "fill": { "light": "#111111", "dark": "#222222" } },
      "palette": ["#FF00FF", { "light": "#00FF00", "dark": "#0000FF" }]
    }
    """#)

    #expect(manifest.surface?.fill == .bare("#FFF200"))
    #expect(manifest.surface?.material == .bare(.known(.none)))
    #expect(manifest.surface?.text?.color == .bare("#FFFFFF"))
    #expect(manifest.header?.fill == .paired(light: "#111111", dark: "#222222"))
    #expect(manifest.palette == [
        .bare("#FF00FF"),
        .paired(light: "#00FF00", dark: "#0000FF"),
    ])

    let encoded = try JSONEncoder().encode(manifest)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let surface = try #require(object["surface"] as? [String: Any])
    #expect(surface["fill"] as? String == "#FFF200")
    #expect(surface["material"] as? String == "none")
    let header = try #require(object["header"] as? [String: Any])
    #expect(header["fill"] as? [String: String] == ["light": "#111111", "dark": "#222222"])

    #expect(try JSONDecoder().decode(SkinManifest.self, from: encoded) == manifest)
}

@Test func unknownEnumValuesArePreserved() throws {
    let manifest = try decodeManifest(#"""
    {
      "formatVersion": 1, "id": "io.example.unknown", "name": "Unknown", "author": "A", "version": "1.0.0",
      "surface": {
        "material": "frosted",
        "shadow": "glow",
        "image": { "mode": "fit" }
      },
      "typography": { "weight": "chunky" },
      "decoration": { "anchor": "middle", "origin": "center" },
      "resizeHandle": { "visibility": "sometimes" },
      "library": { "cardStyle": "grid" },
      "sounds": { "mute": ["note-create", "explode"] },
      "voiceOrb": { "states": { "idle": {}, "processing": { "frames": 2 } } }
    }
    """#)

    #expect(manifest.surface?.material == .bare(.unknown("frosted")))
    #expect(manifest.surface?.shadow == .unknown("glow"))
    #expect(manifest.surface?.image?.mode == .unknown("fit"))
    #expect(manifest.typography?.weight == .unknown("chunky"))
    #expect(manifest.decoration?.anchor == .unknown("middle"))
    #expect(manifest.decoration?.origin == .known(.center))
    #expect(manifest.resizeHandle?.visibility == .unknown("sometimes"))
    #expect(manifest.library?.cardStyle == .unknown("grid"))
    #expect(manifest.sounds?.mute == [.known(.noteCreate), .unknown("explode")])
    #expect(manifest.voiceOrb?.states?.idle == SkinOrbAnimation())
    #expect(manifest.voiceOrb?.states?.animations[.unknown("processing")] == SkinOrbAnimation(frames: 2))
    #expect(SkinOrbState(rawValue: "processing") == .unknown("processing"))

    let encoded = try JSONEncoder().encode(manifest)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let surface = try #require(object["surface"] as? [String: Any])
    #expect(surface["material"] as? String == "frosted")
    #expect(try JSONDecoder().decode(SkinManifest.self, from: encoded) == manifest)
}

@Test func highContrastUsesOnlyDottedKeysAndRoundTrips() throws {
    let manifest = try decodeManifest(#"""
    {
      "formatVersion": 1, "id": "io.example.contrast", "name": "Contrast", "author": "A", "version": "1.0.0",
      "highContrast": {
        "surface.fill": "#FFF6DD",
        "surface.text.color": { "light": "#000000", "dark": "#FFFFFF" },
        "surface": { "fill": "#FF0000" },
        "surfaceFill": "#00FF00"
      }
    }
    """#)

    #expect(manifest.highContrast?.surfaceFill == .bare("#FFF6DD"))
    #expect(manifest.highContrast?.surfaceTextColor == .paired(light: "#000000", dark: "#FFFFFF"))

    let encoded = try JSONEncoder().encode(manifest)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let highContrast = try #require(object["highContrast"] as? [String: Any])
    #expect(Set(highContrast.keys) == ["surface.fill", "surface.text.color"])
    #expect(try JSONDecoder().decode(SkinManifest.self, from: encoded) == manifest)
}

@Test func unknownTopLevelKeysAreIgnored() throws {
    let manifest = try decodeManifest(#"""
    {
      "formatVersion": 1, "id": "io.example.future", "name": "Future", "author": "A", "version": "1.0.0",
      "sparkles": true,
      "futureGroup": { "anything": [1, 2, 3] }
    }
    """#)

    #expect(manifest.id == "io.example.future")
    #expect(manifest.surface == nil)
}

@Test func malformedMetadataDecodesWithoutValidation() throws {
    let manifest = try decodeManifest(#"""
    {
      "formatVersion": 99, "id": "not reverse dns", "name": "", "author": "", "version": "",
      "palette": [], "credits": [], "tags": [], "appearances": []
    }
    """#)

    #expect(manifest.formatVersion == 99)
    #expect(manifest.id == "not reverse dns")
    #expect(manifest.name == "")
    #expect(manifest.author == "")
    #expect(manifest.version == "")
    #expect(manifest.palette == [])
    #expect(manifest.credits == [])
    #expect(manifest.tags == [])
    #expect(manifest.appearances == [])
}

@Test func planExampleRoundTrips() throws {
    let manifest = try decodeManifest(planExampleJSON)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(manifest)
    let decoded = try JSONDecoder().decode(SkinManifest.self, from: encoded)
    #expect(decoded == manifest)
}

@Test func assetNamingHelpersCoverImagesOrbsAndSounds() {
    #expect(SkinAsset.orbKey(state: .listening, frame: 3) == "orb-listening-3")
    #expect(SkinAsset.orbKey(.idle, frame: 11) == "orb-idle-11")
    #expect(SkinAsset.orbKey(state: .idle, frame: nil) == "orb-idle")
    #expect(SkinAsset.orbImageKey(state: .speaking, frame: 0) == "orb-speaking-0")

    let noteBody = SkinAsset.image(element: .noteBody, appearance: nil, scale: .one)
    #expect(noteBody.fileStem == "note-body")
    #expect(noteBody.relativePath == "images/note-body.png")
    #expect(noteBody.kind == .image)
    #expect(noteBody.element == .noteBody)
    #expect(noteBody.scale == .one)
    #expect(noteBody.appearance == nil)
    #expect(noteBody.frame == nil)
    #expect(noteBody.orbState == nil)
    #expect(noteBody.soundEvent == nil)

    let orb = SkinAsset.orb(state: .listening, frame: 3, appearance: .dark, scale: .two)
    #expect(orb.fileStem == "orb-listening-3~dark@2x")
    #expect(orb.relativePath == "images/orb-listening-3~dark@2x.png")
    #expect(orb.kind == .orb)
    #expect(orb.orbState == .listening)
    #expect(orb.frame == 3)
    #expect(orb.appearance == .dark)
    #expect(orb.scale == .two)

    let sound = SkinAsset.sound(event: .known(.noteDelete))
    #expect(sound.fileStem == "note-delete")
    #expect(sound.relativePath == nil)
    #expect(sound.kind == .sound)
    #expect(sound.soundEvent == .known(.noteDelete))
}

@Test func assetsAndEntriesRoundTrip() throws {
    let assets: [SkinAsset] = [
        .image(element: .noteHeader, appearance: .light, scale: .two),
        .orb(state: .thinking, frame: 0, appearance: nil, scale: .one),
        .sound(event: .unknown("custom")),
    ]

    let encoded = try JSONEncoder().encode(assets)
    #expect(try JSONDecoder().decode([SkinAsset].self, from: encoded) == assets)

    let dispositions: [SkinEntryDisposition] = [
        .accepted(SkinEntry(path: "images/note-body.png", asset: assets[0])),
        .skipped,
        .warning("unknown file"),
        .rejected("absolute path"),
    ]
    let entryData = try JSONEncoder().encode(dispositions)
    #expect(try JSONDecoder().decode([SkinEntryDisposition].self, from: entryData) == dispositions)
    #expect(dispositions.first == .accepted(SkinEntry(path: "images/note-body.png", asset: assets[0])))
}

@Test func diagnosticPathsRenderKeysAndIndices() {
    #expect(SkinDiagnostic.render(path: [.key("surface"), .key("fill")]) == "$.surface.fill")
    #expect(SkinDiagnostic.render(path: [.key("surface.fill")]) == "$[\"surface.fill\"]")
    #expect(SkinDiagnostic.render(path: [.key("palette"), .index(0), .key("light")]) == "$.palette[0].light")
    #expect(SkinDiagnostic.render(path: [.index(2), .key("a b")]) == "$[2][\"a b\"]")

    let diagnostic = SkinDiagnostic(
        code: "contrast.fill",
        severity: .groupError,
        path: [.key("surface"), .key("fill")],
        group: "surface",
        assetPath: "images/note-body.png",
        message: "Fill is too transparent."
    )
    #expect(diagnostic.jsonPath == "$.surface.fill")
    #expect(diagnostic.summary == "groupError: contrast.fill at $.surface.fill: Fill is too transparent.")
    #expect(diagnostic.summary.count <= SkinDiagnostic.maxSummaryLength)
    #expect(diagnostic.severity == .groupError)
    #expect(diagnostic.code == "contrast.fill")
    #expect(diagnostic.group == "surface")
    #expect(diagnostic.assetPath == "images/note-body.png")
    #expect(diagnostic.message == "Fill is too transparent.")

    let long = SkinDiagnostic(
        code: "long",
        severity: .warning,
        message: String(repeating: "x", count: 2_000)
    )
    #expect(long.summary.count <= SkinDiagnostic.maxSummaryLength)

    do {
        let encoded = try JSONEncoder().encode(diagnostic)
        let decoded = try JSONDecoder().decode(SkinDiagnostic.self, from: encoded)
        #expect(decoded == diagnostic)
    } catch {
        Issue.record("SkinDiagnostic failed to round trip: \(error)")
    }
}

@Test func everyKnownTokenCaseIsAvailable() {
    #expect(SkinMaterial.Known.allCases.map(\.rawValue) == [
        "none", "titlebar", "selection", "menu", "popover", "sidebar", "headerView",
        "sheet", "windowBackground", "hudWindow", "fullScreenUI", "toolTip",
        "contentBackground", "underWindowBackground", "underPageBackground",
    ])
    #expect(SkinShadow.Known.allCases.map(\.rawValue) == ["system", "none", "soft"])
    #expect(SkinImageMode.Known.allCases.map(\.rawValue) == ["stretch", "tile"])
    #expect(SkinFontWeight.Known.allCases.map(\.rawValue) == [
        "ultraLight", "thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black",
    ])
    #expect(SkinAlignment.Known.allCases.count == 9)
    #expect(SkinVisibility.Known.allCases.map(\.rawValue) == ["always", "hover", "never"])
    #expect(SkinCardStyle.Known.allCases.map(\.rawValue) == ["note", "uniform"])
    #expect(SkinSoundEvent.Known.allCases.map(\.rawValue) == [
        "note-create", "note-save", "note-delete", "note-collapse",
        "voice-start", "voice-stop", "voice-error",
    ])
    #expect(SkinOrbState.Known.allCases.map(\.rawValue) == [
        "idle", "listening", "thinking", "speaking", "error",
    ])
    #expect(SkinImageElement.allCases.map(\.rawValue) == [
        "note-body", "note-header", "note-collapsed", "decoration", "icon-collapse",
        "icon-expand", "icon-close", "icon-more", "resize-handle", "library-empty",
    ])
    #expect(SkinScale.allCases.map(\.rawValue) == [1, 2])
    #expect(SkinAppearance.allCases == [.light, .dark])
}
