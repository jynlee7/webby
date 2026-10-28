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

private func load(_ json: String) -> SkinManifestDocument {
    SkinManifestLoader.load(data: Data(json.utf8))
}

private func manifestJSON(formatVersion: Int, extra: String = "") -> String {
    """
    {
      "formatVersion": \(formatVersion),
      "id": "io.example.loader",
      "name": "Loader",
      "author": "A",
      "version": "1.0.0"\(extra)
    }
    """
}

private func diagnostics(
    _ document: SkinManifestDocument,
    code: String
) -> [SkinDiagnostic] {
    document.diagnostics.filter { $0.code == code }
}

@Test func planExampleLoadsStrictlyAndIsAccepted() {
    let document = load(planExampleJSON)

    #expect(document.manifest != nil)
    #expect(document.formatVersion == 1)
    #expect(document.isStrictJSON)
    #expect(document.isAccepted)
    #expect(document.diagnostics.isEmpty)
    #expect(document.originalData == Data(planExampleJSON.utf8))
}

@Test func json5CommentsProduceANonStrictWarning() {
    let document = load("""
    {
      // A hand-edited comment.
      "formatVersion": 1,
      /* A block comment. */
      "id": "io.example.comments",
      "name": "Comments",
      "author": "A",
      "version": "1.0.0",
      "surface": { "fill": "#FFFFFF" }
    }
    """)

    #expect(document.manifest?.id == "io.example.comments")
    #expect(!document.isStrictJSON)
    #expect(document.isAccepted)

    let warnings = diagnostics(document, code: "non-strict-json")
    #expect(warnings.count == 1)
    #expect(warnings.first?.severity == .warning)
    #expect(warnings.first?.jsonPath == "$")
}

@Test func malformedManifestIsFatalAndNeverThrows() {
    let document = load("{ \"formatVersion\": 1,")

    #expect(document.manifest == nil)
    #expect(document.formatVersion == nil)
    #expect(!document.isStrictJSON)
    #expect(!document.isAccepted)

    let fatal = diagnostics(document, code: "manifest-unparseable")
    #expect(fatal.count == 1)
    #expect(fatal.first?.severity == .fatal)
    #expect(fatal.first?.jsonPath == "$")
}

@Test func newerAndOlderFormatVersionsAreFatal() {
    let newer = load(manifestJSON(formatVersion: 2))
    #expect(newer.manifest != nil)
    #expect(newer.formatVersion == 2)
    #expect(!newer.isAccepted)
    let newerFatal = diagnostics(newer, code: "format-version-newer")
    #expect(newerFatal.count == 1)
    #expect(newerFatal.first?.severity == .fatal)
    #expect(newerFatal.first?.jsonPath == "$.formatVersion")

    let older = load(manifestJSON(formatVersion: 0))
    #expect(older.manifest != nil)
    #expect(older.formatVersion == 0)
    #expect(!older.isAccepted)
    let olderFatal = diagnostics(older, code: "format-version-unsupported")
    #expect(olderFatal.count == 1)
    #expect(olderFatal.first?.severity == .fatal)
    #expect(olderFatal.first?.jsonPath == "$.formatVersion")
}

@Test func unknownKeysReportExactPaths() {
    let json = """
    {
      "formatVersion": 1,
      "id": "io.example.unknown",
      "name": "Unknown",
      "author": "A",
      "version": "1.0.0",
      "mystery": true,
      "surface": { "fill": "#FFFFFF", "foo": 1 }
    }
    """

    let document = load(json)
    let warnings = diagnostics(document, code: "unknown-key")

    #expect(document.isAccepted)
    #expect(warnings.count == 2)
    #expect(Set(warnings.map(\.jsonPath)) == Set(["$.mystery", "$.surface.foo"]))
    #expect(warnings.first { $0.jsonPath == "$.surface.foo" }?.group == "surface")
    #expect(warnings.allSatisfy { $0.severity == .warning })
}

@Test func nonFiniteTypographyValuesAreGroupErrorsWithGroup() {
    let json = """
    {
      "formatVersion": 1,
      "id": "io.example.nonfinite",
      "name": "Non-finite",
      "author": "A",
      "version": "1.0.0",
      "typography": { "size": NaN, "lineSpacing": Infinity }
    }
    """

    let document = load(json)
    let errors = diagnostics(document, code: "non-finite-number")

    #expect(document.isAccepted)
    #expect(errors.count == 2)
    #expect(Set(errors.map(\.jsonPath)) == Set(["$.typography.size", "$.typography.lineSpacing"]))
    #expect(errors.allSatisfy { $0.severity == .groupError })
    #expect(errors.allSatisfy { $0.group == "typography" })

    #expect(document.manifest?.typography?.size?.isNaN == true)
    #expect(document.manifest?.typography?.lineSpacing?.isInfinite == true)
}

@Test func nonFiniteOrbFpsIsAGroupError() {
    let json = """
    {
      "formatVersion": 1,
      "id": "io.example.orb",
      "name": "Orb",
      "author": "A",
      "version": "1.0.0",
      "voiceOrb": { "states": { "idle": { "fps": Infinity } } }
    }
    """

    let document = load(json)
    let errors = diagnostics(document, code: "non-finite-number")

    #expect(document.isAccepted)
    #expect(errors.count == 1)
    #expect(errors.first?.severity == .groupError)
    #expect(errors.first?.group == "voiceOrb")
    #expect(errors.first?.jsonPath == "$.voiceOrb.states.idle.fps")
    #expect(document.manifest?.voiceOrb?.states?.idle?.fps?.isInfinite == true)
}

@Test func dottedHighContrastKeysRenderAsQuotedPathSegments() {
    let json = """
    {
      "formatVersion": 1,
      "id": "io.example.contrast",
      "name": "Contrast",
      "author": "A",
      "version": "1.0.0",
      "highContrast": {
        "surface.fill": { "light": "#FFFFFF", "dark": "#000000", "future": NaN },
        "surface.border": "#FFFFFF"
      }
    }
    """

    let document = load(json)
    let errors = diagnostics(document, code: "non-finite-number")
    let warnings = diagnostics(document, code: "unknown-key")

    #expect(document.isAccepted)
    #expect(errors.count == 1)
    #expect(errors.first?.severity == .groupError)
    #expect(errors.first?.group == "highContrast")
    #expect(errors.first?.jsonPath == #"$.highContrast["surface.fill"].future"#)

    #expect(warnings.count == 2)
    #expect(warnings.first { $0.jsonPath == #"$.highContrast["surface.fill"].future"# } != nil)
    #expect(warnings.first { $0.jsonPath == #"$.highContrast["surface.border"]"# } != nil)
    #expect(warnings.allSatisfy { $0.group == "highContrast" })
}

@Test func ungroupedNonFiniteNumberIsFatal() {
    let json = """
    {
      "formatVersion": 1,
      "id": "io.example.sparkles",
      "name": "Sparkles",
      "author": "A",
      "version": "1.0.0",
      "sparkles": NaN
    }
    """

    let document = load(json)
    let fatal = diagnostics(document, code: "non-finite-metadata")

    #expect(document.manifest != nil)
    #expect(!document.isAccepted)
    #expect(fatal.count == 1)
    #expect(fatal.first?.severity == .fatal)
    #expect(fatal.first?.group == nil)
    #expect(fatal.first?.jsonPath == "$.sparkles")
}
