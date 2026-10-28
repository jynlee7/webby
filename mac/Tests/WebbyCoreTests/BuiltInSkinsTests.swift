import Foundation
import Testing
@testable import WebbyCore

// MARK: - Shared helpers

private func repositoryRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while url.path != "/" {
        if FileManager.default.fileExists(
            atPath: url.appendingPathComponent("mac/Resources/Skins/webby.clear/skin.json").path
        ) {
            return url
        }
        url.deleteLastPathComponent()
    }
    return url
}

private func builtInManifest(_ id: String) throws -> (manifest: SkinManifest, data: Data) {
    let url = repositoryRoot().appendingPathComponent("mac/Resources/Skins/\(id)/skin.json")
    let data = try Data(contentsOf: url)
    let manifest = try JSONDecoder().decode(SkinManifest.self, from: data)
    return (manifest, data)
}

private struct RGBAColor {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
}

private func rgba(_ hex: String) -> RGBAColor? {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard digits.count == 6 || digits.count == 8, let value = UInt32(digits, radix: 16) else {
        return nil
    }
    if digits.count == 6 {
        return RGBAColor(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: 1
        )
    }
    return RGBAColor(
        red: Double((value >> 24) & 0xFF) / 255,
        green: Double((value >> 16) & 0xFF) / 255,
        blue: Double((value >> 8) & 0xFF) / 255,
        alpha: Double(value & 0xFF) / 255
    )
}

private func composite(_ foreground: RGBAColor, over background: RGBAColor) -> RGBAColor {
    RGBAColor(
        red: foreground.red * foreground.alpha + background.red * (1 - foreground.alpha),
        green: foreground.green * foreground.alpha + background.green * (1 - foreground.alpha),
        blue: foreground.blue * foreground.alpha + background.blue * (1 - foreground.alpha),
        alpha: 1
    )
}

private func luminance(_ color: RGBAColor) -> Double {
    func channel(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(color.red)
        + 0.7152 * channel(color.green)
        + 0.0722 * channel(color.blue)
}

private func contrastRatio(_ first: RGBAColor, _ second: RGBAColor) -> Double {
    let firstLuminance = luminance(first)
    let secondLuminance = luminance(second)
    let lighter = max(firstLuminance, secondLuminance)
    let darker = min(firstLuminance, secondLuminance)
    return (lighter + 0.05) / (darker + 0.05)
}

private func assertTextContrast(
    _ manifest: SkinManifest,
    text: SkinColor,
    fill: SkinColor,
    palette: [SkinColor],
    placeholder: SkinColor?
) {
    for appearance in [SkinAppearance.light, .dark] {
        let textHex = appearance == .light ? text.light : text.dark
        let fillHex = appearance == .light ? fill.light : fill.dark
        #expect(rgba(textHex) != nil, "\(manifest.id) has an invalid text color")
        #expect(rgba(fillHex) != nil, "\(manifest.id) has an invalid fill color")

        for backdropHex in ["#FFFFFF", "#000000"] {
            guard let textColor = rgba(textHex),
                  let fillColor = rgba(fillHex),
                  let backdrop = rgba(backdropHex) else {
                continue
            }
            let surface = composite(fillColor, over: backdrop)
            #expect(
                contrastRatio(textColor, surface) >= 4.5,
                "\(manifest.id) \(appearance) text on surface is below 4.5:1"
            )

            for token in palette {
                let tintHex = appearance == .light ? token.light : token.dark
                guard let tint = rgba(tintHex) else {
                    Issue.record("\(manifest.id) has an invalid palette color \(tintHex)")
                    continue
                }
                let paletteFill = composite(tint, over: surface)
                #expect(
                    contrastRatio(textColor, paletteFill) >= 4.5,
                    "\(manifest.id) \(appearance) text on palette \(tintHex) is below 4.5:1"
                )
            }

            if let placeholder {
                let placeholderHex = appearance == .light ? placeholder.light : placeholder.dark
                guard let placeholderColor = rgba(placeholderHex) else {
                    Issue.record("\(manifest.id) has an invalid placeholder color")
                    continue
                }
                #expect(
                    contrastRatio(placeholderColor, surface) >= 4.5,
                    "\(manifest.id) \(appearance) placeholder on surface is below 4.5:1"
                )
            }
        }
    }
}

// MARK: - Built-in manifests

@Test func builtInSkinManifestsDecodeWithExpectedMetadata() throws {
    let cases: [(id: String, name: String, base: String?)] = [
        ("webby.clear", "Clear Glass", nil),
        ("webby.mono", "Mono", "webby.clear"),
    ]

    for expected in cases {
        let (manifest, _) = try builtInManifest(expected.id)
        #expect(manifest.formatVersion == 1)
        #expect(manifest.id == expected.id)
        #expect(manifest.name == expected.name)
        #expect(manifest.author == "Webby")
        #expect(manifest.version == "1.0.0")
        #expect(manifest.license == "MIT")
        #expect(manifest.base == expected.base)
        #expect(manifest.schema == nil)
        #expect(manifest.credits == [SkinCredit(name: "Webby", role: "original token design")])
        #expect(manifest.appearances == [.light, .dark])
    }

    let (clear, _) = try builtInManifest("webby.clear")
    let (mono, _) = try builtInManifest("webby.mono")
    #expect(clear.id == "webby.clear")
    #expect(clear.base == nil)
    #expect(mono.id == "webby.mono")
    #expect(mono.base == "webby.clear")
}

@Test func builtInSkinManifestsHaveNoAssetReferences() throws {
    for id in ["webby.clear", "webby.mono"] {
        let (manifest, data) = try builtInManifest(id)
        let raw = String(decoding: data, as: UTF8.self)

        #expect(manifest.surface?.image == nil)
        #expect(manifest.decoration?.element == nil)
        #expect(manifest.voiceOrb == nil)
        #expect(manifest.sounds == nil)
        #expect(manifest.typography?.font == nil)

        for token in [
            "\"$schema\"",
            "\"image\"",
            "\"element\"",
            "\"voiceOrb\"",
            "\"sounds\"",
            "preview",
            "images/",
            "sounds/",
            "fonts/",
            "orb-",
        ] {
            #expect(!raw.contains(token), "\(id) contains an asset reference: \(token)")
        }
    }
}

@Test func clearManifestMatchesItsDocumentedTokens() throws {
    let (manifest, _) = try builtInManifest("webby.clear")
    let surface = try #require(manifest.surface)

    #expect(surface.fill == .paired(light: "#FFFFFFE6", dark: "#16181DE6"))
    #expect(surface.material == .paired(light: .known(.popover), dark: .known(.popover)))
    #expect(surface.cornerRadius == 16)
    #expect(surface.shadow == .known(.soft))
    #expect(surface.padding == SkinInsets(top: 12, left: 14, bottom: 14, right: 14))
    #expect(surface.text?.color == .paired(light: "#0B0C0F", dark: "#F1F2F4"))
    #expect(manifest.typography == SkinTypography(size: 14, weight: .known(.regular), lineSpacing: 3))
    #expect(manifest.header == SkinHeader(height: 0, showsTitle: false))
    #expect(manifest.collapsed == SkinCollapsed(height: 32, showsFirstLine: true))
    #expect(manifest.decoration == SkinDecoration(hidden: true))
    #expect(manifest.icons == SkinIcons(
        tint: .paired(light: "#0B0C0F", dark: "#F1F2F4"),
        template: true
    ))
    #expect(manifest.resizeHandle == SkinResizeHandle(visibility: .known(.hover)))
    #expect(manifest.palette?.count == 6)
    #expect(manifest.highContrast == SkinHighContrast(
        surfaceFill: .paired(light: "#FFFFFF", dark: "#000000"),
        surfaceTextColor: .paired(light: "#000000", dark: "#FFFFFF")
    ))

    let palette = try #require(manifest.palette)
    #expect(palette.first == .paired(light: "#FFFFFF00", dark: "#16181D00"))

    assertTextContrast(
        manifest,
        text: try #require(surface.text?.color),
        fill: try #require(surface.fill),
        palette: palette,
        placeholder: surface.placeholderColor
    )
}

@Test func monoManifestMatchesItsDocumentedTokens() throws {
    let (manifest, _) = try builtInManifest("webby.mono")
    let surface = try #require(manifest.surface)

    #expect(surface.fill == .paired(light: "#FFFFFF", dark: "#0E1013"))
    #expect(surface.material == .bare(.known(.none)))
    #expect(surface.cornerRadius == 6)
    #expect(surface.border?.width == 1)
    #expect(surface.border?.color == .paired(light: "#1F2329", dark: "#F4F5F7"))
    #expect(surface.shadow == .known(.none))
    #expect(surface.text?.color == .paired(light: "#111318", dark: "#F4F5F7"))
    #expect(manifest.typography == SkinTypography(size: 14, weight: .known(.regular), lineSpacing: 2))
    #expect(manifest.palette?.count == 6)
    #expect(manifest.highContrast == SkinHighContrast(
        surfaceFill: .paired(light: "#FFFFFF", dark: "#000000"),
        surfaceTextColor: .paired(light: "#000000", dark: "#FFFFFF")
    ))

    assertTextContrast(
        manifest,
        text: try #require(surface.text?.color),
        fill: try #require(surface.fill),
        palette: try #require(manifest.palette),
        placeholder: surface.placeholderColor
    )
}

// MARK: - Draft schema

private func schemaRoot() throws -> [String: Any] {
    let url = repositoryRoot().appendingPathComponent("schemas/webbyskin-1.json")
    let data = try Data(contentsOf: url)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func schemaValue(_ path: [String], in root: [String: Any]) -> Any? {
    var current: Any = root
    for key in path {
        guard let object = current as? [String: Any], let next = object[key] else {
            return nil
        }
        current = next
    }
    return current
}

private func schemaNumber(_ path: [String], _ key: String, in root: [String: Any]) -> Double? {
    guard let object = schemaValue(path, in: root) as? [String: Any],
          let number = object[key] as? NSNumber else {
        return nil
    }
    return number.doubleValue
}

private func schemaEnum(_ path: [String], in root: [String: Any]) -> [String]? {
    guard let object = schemaValue(path, in: root) as? [String: Any],
          let values = object["enum"] as? [String] else {
        return nil
    }
    return values
}

@Test func draftSchemaCoversEveryManifestKey() throws {
    let schema = try schemaRoot()

    let coverage: [String: [String]] = [
        "schema": ["properties", "$schema"],
        "formatVersion": ["properties", "formatVersion"],
        "id": ["properties", "id"],
        "name": ["properties", "name"],
        "author": ["properties", "author"],
        "version": ["properties", "version"],
        "description": ["properties", "description"],
        "license": ["properties", "license"],
        "basedOn": ["properties", "basedOn"],
        "base": ["properties", "base"],
        "credits": ["properties", "credits"],
        "tags": ["properties", "tags"],
        "appearances": ["properties", "appearances"],
        "palette": ["properties", "palette"],
        "surface": ["properties", "surface"],
        "typography": ["properties", "typography"],
        "header": ["properties", "header"],
        "collapsed": ["properties", "collapsed"],
        "decoration": ["properties", "decoration"],
        "icons": ["properties", "icons"],
        "resizeHandle": ["properties", "resizeHandle"],
        "library": ["properties", "library"],
        "voiceOrb": ["properties", "voiceOrb"],
        "sounds": ["properties", "sounds"],
        "highContrast": ["properties", "highContrast"],
        "highContrast.surface.fill": ["properties", "highContrast", "properties", "surface.fill"],
        "highContrast.surface.text.color": ["properties", "highContrast", "properties", "surface.text.color"],
    ]

    for (name, path) in coverage {
        #expect(schemaValue(path, in: schema) != nil, "schema does not cover \(name)")
    }

    #expect(schema["$schema"] as? String == "https://json-schema.org/draft/2020-12/schema")
    #expect(schema["additionalProperties"] as? Bool == true)

    let states = schemaValue(["properties", "voiceOrb", "properties", "states", "properties"], in: schema)
        as? [String: Any]
    #expect(Set((states ?? [:]).keys) == ["idle", "listening", "thinking", "speaking", "error"])

    let highContrast = schemaValue(["properties", "highContrast", "properties"], in: schema) as? [String: Any]
    #expect(Set((highContrast ?? [:]).keys).isSuperset(of: ["surface.fill", "surface.text.color"]))
}

@Test func draftSchemaUsesDecoderEnumsAndDocumentedRanges() throws {
    let schema = try schemaRoot()

    let expectedEnums: [String: Set<String>] = [
        "material": [
            "none", "titlebar", "selection", "menu", "popover", "sidebar", "headerView",
            "sheet", "windowBackground", "hudWindow", "fullScreenUI", "toolTip",
            "contentBackground", "underWindowBackground", "underPageBackground",
        ],
        "shadow": ["system", "none", "soft"],
        "imageMode": ["stretch", "tile"],
        "fontWeight": [
            "ultraLight", "thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black",
        ],
        "alignment": [
            "topLeft", "topCenter", "topRight", "centerLeft", "center",
            "centerRight", "bottomLeft", "bottomCenter", "bottomRight",
        ],
        "visibility": ["always", "hover", "never"],
        "cardStyle": ["note", "uniform"],
        "soundEvent": [
            "note-create", "note-save", "note-delete", "note-collapse",
            "voice-start", "voice-stop", "voice-error",
        ],
        "appearance": ["light", "dark"],
    ]

    for (name, expected) in expectedEnums {
        #expect(Set(schemaEnum(["$defs", name], in: schema) ?? []) == expected, "enum \(name) differs")
    }

    let color = schemaValue(["$defs", "color"], in: schema) as? [String: Any]
    #expect(color?["pattern"] as? String == "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$")

    #expect(schemaNumber(["properties", "surface", "properties", "cornerRadius"], "minimum", in: schema) == 0)
    #expect(schemaNumber(["properties", "surface", "properties", "cornerRadius"], "maximum", in: schema) == 32)
    #expect(schemaNumber(["properties", "surface", "properties", "border", "properties", "width"], "minimum", in: schema) == 0)
    #expect(schemaNumber(["properties", "surface", "properties", "border", "properties", "width"], "maximum", in: schema) == 4)
    #expect(schemaNumber(["properties", "typography", "properties", "size"], "minimum", in: schema) == 10)
    #expect(schemaNumber(["properties", "typography", "properties", "size"], "maximum", in: schema) == 32)
    #expect(schemaNumber(["properties", "sounds", "properties", "volume"], "minimum", in: schema) == 0)
    #expect(schemaNumber(["properties", "sounds", "properties", "volume"], "maximum", in: schema) == 1)
    #expect(schemaNumber(["properties", "palette"], "maxItems", in: schema) == 12)
    #expect(schemaNumber(["$defs", "orbAnimation", "properties", "frames"], "minimum", in: schema) == 1)
    #expect(schemaNumber(["$defs", "orbAnimation", "properties", "frames"], "maximum", in: schema) == 60)
    #expect(schemaNumber(["$defs", "orbAnimation", "properties", "audioReactive"], "minimum", in: schema) == 0)
    #expect(schemaNumber(["$defs", "orbAnimation", "properties", "audioReactive"], "maximum", in: schema) == 0.3)

    let headerHeight = schemaValue(["properties", "header", "properties", "height"], in: schema) as? [String: Any]
    let alternatives = headerHeight?["anyOf"] as? [[String: Any]] ?? []
    #expect(alternatives.contains { ($0["const"] as? Int) == 0 })
    #expect(alternatives.contains {
        ($0["minimum"] as? Int) == 16 && ($0["maximum"] as? Int) == 36
    })
}

// MARK: - Packaging

@Test func buildScriptPreflightsAndCopiesBothBuiltInSkinsBeforeSigning() throws {
    let url = repositoryRoot().appendingPathComponent("scripts/build-app.sh")
    let script = try String(contentsOf: url, encoding: .utf8)

    let skinList = try #require(script.range(of: "for skin in webby.clear webby.mono; do"))
    let preflight = try #require(script.range(of: "Resources/Skins/$skin/skin.json"))
    let copy = try #require(script.range(of: "cp -R Resources/Skins \"$app/Contents/Resources/Skins\""))
    let signing = try #require(script.range(of: "codesign --force --sign - \"$app/Contents/MacOS/webby-bridge\""))

    #expect(skinList.lowerBound < preflight.lowerBound)
    #expect(preflight.lowerBound < copy.lowerBound)
    #expect(copy.lowerBound < signing.lowerBound)
}
