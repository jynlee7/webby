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

private struct FakeAssets: SkinAssetChecking {
    var records: [SkinAssetRecord] = []
    var images: [String: AssetCheck<ImageAssetMetadata>] = [:]
    var sounds: [String: AssetCheck<SoundAssetMetadata>] = [:]

    func inventory() -> [SkinAssetRecord] {
        records
    }

    func image(_ path: String) -> AssetCheck<ImageAssetMetadata> {
        images[path] ?? .missing
    }

    func sound(_ path: String) -> AssetCheck<SoundAssetMetadata> {
        sounds[path] ?? .missing
    }
}

private func manifest(extra: String = "") -> String {
    """
    {
      "formatVersion": 1,
      "id": "io.example.validator",
      "name": "Validator",
      "author": "A",
      "version": "1.0.0"\(extra)
    }
    """
}

private func imageMetadata(
    _ path: String,
    bytes: Int = 100,
    width: Int = 100,
    height: Int = 100
) -> ImageAssetMetadata {
    ImageAssetMetadata(
        path: path,
        bytes: bytes,
        png: PNGHeader(width: width, height: height, bitDepth: 8, colorType: 6, interlace: 0)
    )
}

private func validate(
    _ json: String,
    assets: FakeAssets = FakeAssets(),
    context: SkinValidationContext = SkinValidationContext()
) -> SkinValidationResult {
    let document = SkinManifestLoader.load(data: Data(json.utf8))
    return SkinValidator.validate(document: document, assets: assets, context: context)
}

private func codes(_ result: SkinValidationResult) -> Set<String> {
    Set(result.diagnostics.map(\.code))
}

@Test func planExampleValidatesWithOnlyMissingAssetWarnings() {
    let result = validate(planExampleJSON)

    #expect(result.isAccepted)
    #expect(result.manifest != nil)
    #expect(!result.diagnostics.isEmpty)
    #expect(result.diagnostics.allSatisfy { $0.code == "missing-asset" })
    #expect(result.diagnostics.allSatisfy { $0.severity == .warning })
    #expect(result.groups.count == SkinGroup.allCases.count)
    #expect(result.groups.values.allSatisfy { $0 == .usable })
}

@Test func newerFormatVersionIsFatalFromLoaderIntegration() {
    let result = validate(manifest(extra: "").replacingOccurrences(
        of: "\"formatVersion\": 1",
        with: "\"formatVersion\": 2"
    ))

    #expect(!result.isAccepted)
    #expect(result.diagnostics.contains { $0.code == "format-version-newer" && $0.severity == .fatal })
    #expect(result.groups.values.allSatisfy { $0 == .invalid })
    #expect(!result.groups.values.contains(.usable))
}

@Test func nonFiniteGroupValueKeepsTheGroupsInvalid() {
    let result = validate(manifest(extra: ",\n  \"typography\": { \"size\": NaN }"))

    #expect(result.isAccepted)
    #expect(result.groups[.typography] == .invalid)
    #expect(result.diagnostics.contains {
        $0.code == "non-finite-number"
            && $0.group == "typography"
            && $0.jsonPath == "$.typography.size"
    })
}

@Test func nonFiniteMetadataIsFatal() {
    let result = validate(manifest(extra: ",\n  \"sparkles\": Infinity"))

    #expect(!result.isAccepted)
    #expect(result.diagnostics.contains { $0.code == "non-finite-metadata" && $0.severity == .fatal })
    #expect(result.groups.values.allSatisfy { $0 == .invalid })
    #expect(!result.groups.values.contains(.usable))
}

@Test func reservedWebbyPrefixIsOnlyForBuiltInSkins() {
    let json = manifest(extra: "")
        .replacingOccurrences(of: "io.example.validator", with: "webby.thirdparty")

    let thirdParty = validate(json)
    #expect(!thirdParty.isAccepted)
    #expect(thirdParty.diagnostics.contains { $0.code == "reserved-id-prefix" && $0.severity == .fatal })

    let builtIn = validate(
        json,
        context: SkinValidationContext(isBuiltIn: true, availableBaseIDs: ["webby.clear"])
    )
    #expect(builtIn.isAccepted)
    #expect(!builtIn.diagnostics.contains { $0.code == "reserved-id-prefix" })
}

@Test func badSemverAndIdentifierAreFatal() {
    let json = manifest(extra: "")
        .replacingOccurrences(of: "io.example.validator", with: "single-label")
        .replacingOccurrences(of: "\"1.0.0\"", with: "\"1.0\"")

    let result = validate(json)

    #expect(!result.isAccepted)
    #expect(result.diagnostics.contains { $0.code == "invalid-version" })
    #expect(result.diagnostics.contains { $0.code == "invalid-id" })
    #expect(result.diagnostics.allSatisfy { $0.severity == .fatal })
}

@Test func unavailableBaseWarnsAndNormalizes() {
    let json = manifest(extra: ",\n  \"base\": \"webby.missing\"")
    let result = validate(json)

    #expect(result.isAccepted)
    #expect(result.manifest?.base == "webby.clear")
    #expect(result.diagnostics.contains {
        $0.code == "base-unavailable"
            && $0.severity == .warning
            && $0.jsonPath == "$.base"
    })
}

@Test func unknownEnumsColorsAndOutOfRangeValuesAreReported() {
    let json = manifest(extra: #"""
    ,
      "palette": [{ "light": "#FFFFFF", "dark": "#000000" }],
      "surface": {
        "fill": "#GGGGGG",
        "material": "futureMaterial",
        "image": {
          "element": "note-body",
          "insets": { "top": -1, "left": 0, "bottom": 0, "right": 0 },
          "mode": "futureMode"
        },
        "cornerRadius": 99,
        "border": { "width": -2, "color": "#12345" },
        "shadow": "futureShadow",
        "padding": { "top": -3 },
        "text": { "color": "#FFFFFF" },
        "placeholderColor": "#FFFFFF",
        "selection": "#FFFFFF",
        "caret": "#FFFFFF"
      },
      "typography": { "size": 50, "weight": "future", "lineSpacing": -2 },
      "header": { "height": 10, "fill": "#FFFFFF" },
      "collapsed": { "height": -5 },
      "decoration": {
        "element": "future",
        "anchor": "future",
        "origin": "future",
        "offset": { "x": 0, "y": 0 },
        "rotation": 0
      },
      "icons": { "tint": "#FFFFFF" },
      "resizeHandle": { "visibility": "future" },
      "library": {
        "accent": "#FFFFFF",
        "sidebarMaterial": "future",
        "cardStyle": "future"
      },
      "sounds": { "volume": 2, "mute": ["future"] },
      "voiceOrb": { "states": { "future": { "frames": 2, "fps": -2, "audioReactive": 1, "tint": "#FFFFFF" } } },
      "highContrast": { "surface.fill": "bad" }
    """#)

    let result = validate(json)
    let allCodes = codes(result)

    #expect(result.isAccepted)
    #expect(allCodes.contains("invalid-color"))
    #expect(allCodes.contains("unknown-enum-value"))
    #expect(allCodes.contains("value-clamped"))
    #expect(allCodes.contains("missing-asset"))
    #expect(result.groups[.palette] == .usable)
    #expect(result.groups[.surface] == .invalid)
    #expect(result.groups[.typography] == .invalid)
    #expect(result.groups[.header] == .usable)
    #expect(result.groups[.collapsed] == .usable)
    #expect(result.groups[.decoration] == .invalid)
    #expect(result.groups[.icons] == .usable)
    #expect(result.groups[.resizeHandle] == .invalid)
    #expect(result.groups[.library] == .invalid)
    #expect(result.groups[.sounds] == .invalid)
    #expect(result.groups[.voiceOrb] == .invalid)
}

@Test func paletteAboveTwelveEntriesInvalidatesTheGroup() {
    let entries = Array(repeating: "\"#FFFFFF\"", count: 13).joined(separator: ", ")
    let result = validate(manifest(extra: ",\n  \"palette\": [\(entries)]"))

    #expect(result.isAccepted)
    #expect(result.groups[.palette] == .invalid)
    #expect(result.diagnostics.contains {
        $0.code == "palette-too-large"
            && $0.group == "palette"
            && $0.severity == .groupError
    })
}

@Test func imageByteAndDimensionCapsAreGroupErrors() {
    let path = "images/note-body.png"
    let assets = FakeAssets(
        records: [SkinAssetRecord(path: path, bytes: 4_000_001)],
        images: [path: .available(imageMetadata(path, bytes: 4_000_001, width: 4096, height: 1))]
    )
    let result = validate(manifest(extra: #"""
    ,
      "surface": { "image": { "element": "note-body", "insets": { "top": 1, "left": 1, "bottom": 1, "right": 1 } } }
    """#), assets: assets)

    #expect(result.isAccepted)
    #expect(result.groups[.surface] == .invalid)
    #expect(codes(result).contains("image-too-large"))
    #expect(codes(result).contains("image-dimension-exceeded"))
}

@Test func decodedPixelBudgetIsEnforcedAcrossImages() {
    let paths = [
        "images/note-body.png",
        "images/note-header.png",
        "images/note-collapsed.png",
        "images/decoration.png",
        "images/icon-collapse.png",
        "images/icon-expand.png",
        "images/icon-close.png",
        "images/icon-more.png",
    ]
    var records: [SkinAssetRecord] = []
    var images: [String: AssetCheck<ImageAssetMetadata>] = [:]
    for path in paths {
        records.append(SkinAssetRecord(path: path, bytes: 100))
        images[path] = .available(imageMetadata(path, width: 2000, height: 2048))
    }

    let result = validate(manifest(extra: #"""
    ,
      "surface": { "image": { "element": "note-body", "insets": { "top": 1, "left": 1, "bottom": 1, "right": 1 } } },
      "header": { "height": 24 },
      "collapsed": { "height": 24 },
      "decoration": { "element": "decoration" },
      "icons": {}
    """#), assets: FakeAssets(records: records, images: images))

    #expect(result.isAccepted)
    #expect(result.diagnostics.filter { $0.code == "pixel-budget-exceeded" }.count == 1)
    #expect(result.diagnostics.contains {
        $0.code == "pixel-budget-exceeded" && $0.severity == .groupError
    })
}

@Test func oneXOnlyImageWarnsButKeepsTheGroupUsable() {
    let path = "images/note-body.png"
    let assets = FakeAssets(
        records: [SkinAssetRecord(path: path, bytes: 100)],
        images: [path: .available(imageMetadata(path))]
    )
    let result = validate(manifest(extra: #"""
    ,
      "surface": { "image": { "element": "note-body", "insets": { "top": 1, "left": 1, "bottom": 1, "right": 1 } } }
    """#), assets: assets)

    #expect(result.isAccepted)
    #expect(result.groups[.surface] == .usable)
    #expect(result.diagnostics.contains {
        $0.code == "image-missing-at2x" && $0.severity == .warning
    })
}

@Test func darkVariantMissingWarnsOnlyWhenDarkIsDeclared() {
    let path = "images/note-body.png"
    let assets = FakeAssets(
        records: [SkinAssetRecord(path: path, bytes: 100)],
        images: [path: .available(imageMetadata(path))]
    )
    let extra = #"""
    ,
      "appearances": ["light", "dark"],
      "surface": { "image": { "element": "note-body", "insets": { "top": 1, "left": 1, "bottom": 1, "right": 1 } } }
    """#

    let withDark = validate(manifest(extra: extra), assets: assets)
    #expect(withDark.groups[.surface] == .usable)
    #expect(withDark.diagnostics.contains {
        $0.code == "missing-dark-variant" && $0.severity == .warning
    })

    let withoutDark = validate(manifest(extra: extra.replacingOccurrences(
        of: "\"light\", \"dark\"",
        with: "\"light\""
    )), assets: assets)
    #expect(!withoutDark.diagnostics.contains { $0.code == "missing-dark-variant" })
}

@Test func orbFrameGapInvalidatesVoiceOrb() {
    let framePath = "images/orb-idle-0.png"
    let assets = FakeAssets(
        records: [SkinAssetRecord(path: framePath, bytes: 100)],
        images: [framePath: .available(imageMetadata(framePath))]
    )
    let result = validate(manifest(extra: #"""
    ,
      "voiceOrb": { "states": { "idle": { "frames": 2, "fps": 0 } } }
    """#), assets: assets)

    #expect(result.isAccepted)
    #expect(result.groups[.voiceOrb] == .invalid)
    #expect(result.diagnostics.contains {
        $0.code == "missing-orb-frame"
            && $0.severity == .groupError
            && $0.assetPath == "images/orb-idle-1.png"
    })
}

@Test func mutedSoundNeedsNoAsset() {
    let result = validate(manifest(extra: #"""
    ,
      "sounds": { "volume": 0.6, "mute": ["note-delete"] }
    """#))

    #expect(result.isAccepted)
    #expect(result.groups[.sounds] == .usable)
    #expect(!result.diagnostics.contains { $0.code == "missing-asset" })
}

@Test func hiddenDecorationNeedsNoAsset() {
    let result = validate(manifest(extra: #"""
    ,
      "decoration": { "element": "decoration", "hidden": true }
    """#))

    #expect(result.isAccepted)
    #expect(result.groups[.decoration] == .usable)
    #expect(!result.diagnostics.contains { $0.code == "missing-asset" })
}

@Test func checkerInvalidAssetIsAGroupError() {
    let path = "images/note-body.png"
    let assets = FakeAssets(
        records: [SkinAssetRecord(path: path, bytes: 100)],
        images: [path: .invalid(code: "decode-failed")]
    )
    let result = validate(manifest(extra: #"""
    ,
      "surface": { "image": { "element": "note-body", "insets": { "top": 1, "left": 1, "bottom": 1, "right": 1 } } }
    """#), assets: assets)

    #expect(result.isAccepted)
    #expect(result.groups[.surface] == .invalid)
    #expect(result.diagnostics.contains {
        $0.code == "invalid-asset"
            && $0.severity == .groupError
            && $0.group == "surface"
            && $0.assetPath == path
    })
}

@Test func soundCapsAndFormatAreGroupErrors() {
    let path = "sounds/note-create.wav"
    let assets = FakeAssets(
        records: [SkinAssetRecord(path: path, bytes: 1_000_001)],
        sounds: [path: .available(SoundAssetMetadata(
            path: path,
            bytes: 1_000_001,
            isPCM: false,
            duration: 4
        ))]
    )
    let result = validate(manifest(extra: #"""
    ,
      "sounds": { "volume": 0.6 }
    """#), assets: assets)

    #expect(result.isAccepted)
    #expect(result.groups[.sounds] == .invalid)
    #expect(codes(result).contains("sound-too-large"))
    #expect(codes(result).contains("sound-not-pcm"))
    #expect(codes(result).contains("sound-duration-exceeded"))
}

@Test func groupStatusMatrixCoversAbsentUsableAndInvalid() {
    let path = "images/note-body.png"
    let assets = FakeAssets(
        records: [SkinAssetRecord(path: path, bytes: 100)],
        images: [path: .available(imageMetadata(path))]
    )
    let entries = Array(repeating: "\"#FFFFFF\"", count: 13).joined(separator: ", ")
    let result = validate(manifest(extra: #"""
    ,
      "palette": [\#(entries)],
      "surface": { "image": { "element": "note-body", "insets": { "top": 1, "left": 1, "bottom": 1, "right": 1 } } },
      "typography": { "size": NaN },
      "decoration": { "element": "decoration", "hidden": true }
    """#), assets: assets)

    #expect(result.groups[.surface] == .usable)
    #expect(result.groups[.palette] == .invalid)
    #expect(result.groups[.typography] == .invalid)
    #expect(result.groups[.decoration] == .usable)
    #expect(result.groups[.header] == .absent)
    #expect(result.groups[.collapsed] == .absent)
    #expect(result.groups[.icons] == .absent)
    #expect(result.groups[.resizeHandle] == .absent)
    #expect(result.groups[.library] == .absent)
    #expect(result.groups[.voiceOrb] == .absent)
    #expect(result.groups[.sounds] == .absent)
}
