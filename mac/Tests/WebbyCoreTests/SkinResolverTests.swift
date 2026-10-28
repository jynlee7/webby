import Foundation
import Testing
@testable import WebbyCore

// MARK: - Fixtures

private func resolverColor(_ hex: String) throws -> RGBAColor {
    try RGBAColor(hex: hex)
}

private func resolverColorToken(light: String, dark: String? = nil) -> Any {
    if let dark {
        return ["light": light, "dark": dark]
    }
    return light
}

private func resolverSurface(fill: Any, text: String = "#000000") -> [String: Any] {
    [
        "fill": fill,
        "text": ["color": text],
        "placeholderColor": text,
        "selection": "#00000000",
        "caret": text,
    ]
}

private func resolverManifest(
    _ id: String,
    base: String? = nil,
    values: [String: Any] = [:]
) throws -> SkinManifest {
    var object: [String: Any] = [
        "formatVersion": 1,
        "id": id,
        "name": id,
        "author": "Tests",
        "version": "1.0.0",
    ]
    if let base {
        object["base"] = base
    }
    for (key, value) in values {
        object[key] = value
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try JSONDecoder().decode(SkinManifest.self, from: data)
}

private func resolverClearManifest(
    surfaceFill: Any = "#FFFFFF",
    text: String = "#000000",
    palette: [Any] = ["#FFFFFF"],
    extra: [String: Any] = [:]
) throws -> SkinManifest {
    var values: [String: Any] = [
        "surface": resolverSurface(fill: surfaceFill, text: text),
        "typography": ["size": 14, "weight": "regular", "lineSpacing": 0],
        "header": ["height": 0, "fill": "#00000000", "showsTitle": false],
        "collapsed": ["height": 32, "showsFirstLine": false],
        "decoration": ["hidden": true],
        "icons": ["template": true, "tint": "#000000"],
        "resizeHandle": ["visibility": "hover", "tint": "#000000"],
        "library": [
            "accent": "#000000",
            "sidebarMaterial": "none",
            "cardStyle": "note",
            "background": "#FFFFFF",
        ],
        "palette": palette,
        "voiceOrb": ["states": [:]],
        "sounds": ["volume": 1, "mute": []],
    ]
    for (key, value) in extra {
        values[key] = value
    }
    return try resolverManifest("webby.clear", values: values)
}

private func resolverSkin(_ manifest: SkinManifest) -> InstalledSkin {
    InstalledSkin(id: manifest.id, manifest: manifest)
}

private func resolverSkin(
    _ manifest: SkinManifest,
    statuses: [SkinGroup: SkinGroupStatus]
) -> InstalledSkin {
    InstalledSkin(id: manifest.id, manifest: manifest, groups: statuses)
}

private func resolverAllUsableStatuses() -> [SkinGroup: SkinGroupStatus] {
    Dictionary(uniqueKeysWithValues: SkinGroup.allCases.map { ($0, .usable) })
}

private func resolverSettings(
    reduceTransparency: Bool = false,
    increaseContrast: Bool = false,
    reduceMotion: Bool = false
) -> AccessibilitySettings {
    AccessibilitySettings(
        reduceTransparency: reduceTransparency,
        increaseContrast: increaseContrast,
        reduceMotion: reduceMotion,
        textScale: 1
    )
}

private func resolverResolve(
    _ resolver: SkinResolver,
    workspace: String?,
    global: String?,
    appearance: AppearanceMode = .light,
    note: NoteAppearance? = nil,
    accessibility: AccessibilitySettings = resolverSettings()
) -> ThemeResolution {
    resolver.resolve(
        workspaceSkinID: workspace,
        globalSkinID: global,
        requested: appearance,
        noteAppearance: note,
        accessibility: accessibility,
        textScale: 1
    )
}

// MARK: - Selection and group fallback

@Test func resolverSelectionUsesWorkspaceThenGlobalThenClear() throws {
    let clear = resolverSkin(try resolverClearManifest())
    let global = resolverSkin(try resolverManifest(
        "test.global",
        values: [
            "surface": resolverSurface(fill: "#0000FF", text: "#FFFFFF"),
            "typography": ["size": 14, "weight": "regular"],
            "palette": ["#0000FF"],
        ]
    ))
    let workspace = resolverSkin(try resolverManifest(
        "test.workspace",
        values: [
            "surface": resolverSurface(fill: "#FF0000"),
            "typography": ["size": 14, "weight": "regular"],
            "palette": ["#FF0000"],
        ]
    ))

    let resolver = SkinResolver(
        builtIns: [clear, global, workspace],
        availableBaseIDs: ["webby.clear", "test.global", "test.workspace"]
    )

    let workspaceResult = resolverResolve(resolver, workspace: "test.workspace", global: "test.global")
    #expect(try workspaceResult.theme.surface.fill == resolverColor("#FF0000"))
    #expect(workspaceResult.theme.skinID == "test.workspace")
    #expect(workspaceResult.theme.provenance[.surface] == "test.workspace")

    let globalResult = resolverResolve(resolver, workspace: nil, global: "test.global")
    #expect(try globalResult.theme.surface.fill == resolverColor("#0000FF"))
    #expect(globalResult.theme.skinID == "test.global")

    let clearResult = resolverResolve(resolver, workspace: nil, global: nil)
    #expect(try clearResult.theme.surface.fill == resolverColor("#FFFFFF"))
    #expect(clearResult.theme.skinID == "webby.clear")
}

@Test func resolverMissingWorkspaceFallsToGlobal() throws {
    let clear = resolverSkin(try resolverClearManifest())
    let global = resolverSkin(try resolverManifest(
        "test.global",
        values: [
            "surface": resolverSurface(fill: "#0000FF", text: "#FFFFFF"),
            "typography": ["size": 14, "weight": "regular"],
            "palette": ["#0000FF"],
        ]
    ))
    let resolver = SkinResolver(
        builtIns: [clear, global],
        availableBaseIDs: ["webby.clear", "test.global"]
    )

    let result = resolverResolve(resolver, workspace: "test.missing", global: "test.global")
    #expect(try result.theme.surface.fill == resolverColor("#0000FF"))
    #expect(result.theme.skinID == "test.global")
    #expect(result.diagnostics.contains {
        $0.code == "skin-not-installed"
            && $0.severity == .warning
            && $0.path == [.key("workspaceSkinID")]
    })
}

@Test func resolverInvalidGroupFallsToBase() throws {
    let clear = resolverSkin(try resolverClearManifest())
    let workspaceManifest = try resolverManifest(
        "test.workspace",
        values: [
            "surface": resolverSurface(fill: "#FF0000"),
            "typography": ["size": 14, "weight": "regular"],
            "palette": ["#FF0000"],
        ]
    )
    var statuses = resolverAllUsableStatuses()
    statuses[.surface] = .invalid
    let workspace = resolverSkin(workspaceManifest, statuses: statuses)
    let resolver = SkinResolver(
        builtIns: [clear, workspace],
        availableBaseIDs: ["webby.clear"]
    )

    let result = resolverResolve(resolver, workspace: "test.workspace", global: nil)
    #expect(try result.theme.surface.fill == resolverColor("#FFFFFF"))
    #expect(result.theme.provenance[.surface] == "webby.clear")
    #expect(result.diagnostics.contains {
        $0.code == "group-invalid"
            && $0.severity == .groupError
            && $0.group == "surface"
            && $0.path == [.key("surface")]
    })
}

@Test func resolverMissingBaseFallsToClear() throws {
    let clear = resolverSkin(try resolverClearManifest())
    let workspace = resolverSkin(try resolverManifest(
        "test.workspace",
        base: "test.not-installed",
        values: [
            "typography": ["size": 14, "weight": "regular"],
        ]
    ))
    let resolver = SkinResolver(
        builtIns: [clear, workspace],
        availableBaseIDs: ["webby.clear"]
    )

    let result = resolverResolve(resolver, workspace: "test.workspace", global: nil)
    #expect(try result.theme.surface.fill == resolverColor("#FFFFFF"))
    #expect(result.theme.provenance[.surface] == "webby.clear")
    #expect(result.diagnostics.contains {
        $0.code == "base-unavailable"
            && $0.path == [.key("base")]
    })
}

@Test func resolverBaseCycleStopsDeterministically() throws {
    let first = resolverSkin(try resolverManifest(
        "test.first",
        base: "test.second",
        values: ["typography": ["size": 14, "weight": "regular"]]
    ))
    let second = resolverSkin(try resolverManifest(
        "test.second",
        base: "test.first",
        values: ["typography": ["size": 14, "weight": "regular"]]
    ))
    let resolver = SkinResolver(
        builtIns: [first, second],
        availableBaseIDs: ["test.first", "test.second"]
    )

    let result = resolverResolve(resolver, workspace: "test.first", global: nil)
    #expect(result.theme.skinID == "test.first")
    #expect(try result.theme.surface.fill == resolverColor("#FFFFFF"))
    #expect(result.diagnostics.contains { $0.code == "base-cycle" })
}

@Test func resolverLibraryComesFromGlobalButPaletteFromWorkspace() throws {
    let clear = resolverSkin(try resolverClearManifest())
    let global = resolverSkin(try resolverManifest(
        "test.global",
        values: [
            "surface": resolverSurface(fill: "#0000FF", text: "#FFFFFF"),
            "typography": ["size": 14, "weight": "regular"],
            "palette": ["#0000FF"],
            "library": [
                "accent": "#0000FF",
                "sidebarMaterial": "sidebar",
                "cardStyle": "uniform",
                "background": "#EEEEEE",
            ],
        ]
    ))
    let workspace = resolverSkin(try resolverManifest(
        "test.workspace",
        values: [
            "surface": resolverSurface(fill: "#FF0000"),
            "typography": ["size": 14, "weight": "regular"],
            "palette": ["#FF0000"],
            "library": [
                "accent": "#FF0000",
                "sidebarMaterial": "none",
                "cardStyle": "note",
                "background": "#00FF00",
            ],
        ]
    ))
    let resolver = SkinResolver(
        builtIns: [clear, global, workspace],
        availableBaseIDs: ["webby.clear", "test.global", "test.workspace"]
    )

    let result = resolverResolve(resolver, workspace: "test.workspace", global: "test.global")
    #expect(try result.theme.library.accent == resolverColor("#0000FF"))
    #expect(result.theme.library.cardStyle == .known(.uniform))
    #expect(result.theme.provenance[.library] == "test.global")
    #expect(result.theme.provenance[.palette] == "test.workspace")
}

// MARK: - Contrast unit

@Test func resolverBrokenPaletteAndValidSurfaceFallBackTogether() throws {
    let clear = resolverSkin(try resolverClearManifest())
    let workspace = resolverSkin(try resolverManifest(
        "test.workspace",
        values: [
            "surface": resolverSurface(fill: "#FF0000", text: "#0B0C0F"),
            "typography": ["size": 14, "weight": "regular"],
            "palette": ["#777777"],
        ]
    ))
    let resolver = SkinResolver(
        builtIns: [clear, workspace],
        availableBaseIDs: ["webby.clear"]
    )

    let result = resolverResolve(resolver, workspace: "test.workspace", global: nil)
    #expect(try result.theme.surface.fill == resolverColor("#FFFFFF"))
    #expect(try result.theme.palette == [resolverColor("#FFFFFF")])
    #expect(result.theme.provenance[.surface] == "webby.clear")
    #expect(result.theme.provenance[.palette] == "webby.clear")
    #expect(result.diagnostics.contains {
        $0.code == "contrast-impossible"
            && $0.severity == .groupError
            && $0.path == [.key("surface"), .key("fill")]
    })
}

@Test func resolverImpossibleContrastUsesTerminalClearFallback() throws {
    let clear = resolverSkin(try resolverClearManifest())
    let workspace = resolverSkin(try resolverManifest(
        "test.workspace",
        values: [
            "surface": resolverSurface(fill: "#777777", text: "#0B0C0F"),
            "typography": ["size": 14, "weight": "regular"],
            "palette": ["#777777"],
        ]
    ))
    let resolver = SkinResolver(
        builtIns: [clear, workspace],
        availableBaseIDs: ["webby.clear"]
    )

    let result = resolverResolve(resolver, workspace: "test.workspace", global: nil)
    #expect(try result.theme.surface.fill == resolverColor("#FFFFFF"))
    #expect(try result.theme.surface.text == resolverColor("#000000"))
    #expect(try result.theme.palette == [resolverColor("#FFFFFF")])
    #expect(result.theme.provenance[.surface] == "webby.clear")
}

// MARK: - Note overrides and appearance

@Test func resolverAppliesPaletteSlotAndHidesDecoration() throws {
    let clear = resolverSkin(try resolverClearManifest(
        palette: ["#FF0000", "#00FF00"],
        extra: [
            "decoration": ["element": "decoration", "hidden": false],
        ]
    ))
    let resolver = SkinResolver(
        builtIns: [clear],
        availableBaseIDs: ["webby.clear"]
    )

    let result = resolverResolve(
        resolver,
        workspace: nil,
        global: nil,
        note: NoteAppearance(paletteIndex: 1, hideDecoration: true)
    )
    #expect(result.theme.selectedIndex == 1)
    #expect(result.theme.decoration.hidden)
    #expect(result.theme.decoration.image?.key.element == .decoration)
}

@Test func resolverOutOfRangePaletteSlotUsesZeroWithWarning() throws {
    let clear = resolverSkin(try resolverClearManifest(palette: ["#FFFFFF"]))
    let resolver = SkinResolver(
        builtIns: [clear],
        availableBaseIDs: ["webby.clear"]
    )

    let result = resolverResolve(
        resolver,
        workspace: nil,
        global: nil,
        note: NoteAppearance(paletteIndex: 4)
    )
    #expect(result.theme.selectedIndex == 0)
    #expect(result.diagnostics.contains {
        $0.code == "palette-index-out-of-range"
            && $0.severity == .warning
            && $0.path == [.key("appearance"), .key("paletteIndex")]
    })
}

@Test func resolverSelectsTheRequestedAppearance() throws {
    let clear = resolverSkin(try resolverClearManifest(
        surfaceFill: resolverColorToken(light: "#FFFFFF", dark: "#000000"),
        text: "#FFFFFF",
        palette: [resolverColorToken(light: "#FFFFFF", dark: "#000000")]
    ))
    let resolver = SkinResolver(
        builtIns: [clear],
        availableBaseIDs: ["webby.clear"]
    )

    let result = resolverResolve(resolver, workspace: nil, global: nil, appearance: .dark)
    #expect(try result.theme.surface.fill == resolverColor("#000000"))
    #expect(result.theme.surface.image == nil)
}

// MARK: - Determinism

@Test func resolverIsDeterministic() throws {
    let clear = resolverSkin(try resolverClearManifest())
    let global = resolverSkin(try resolverManifest(
        "test.global",
        values: [
            "surface": resolverSurface(fill: "#0000FF", text: "#FFFFFF"),
            "typography": ["size": 14, "weight": "regular"],
            "palette": ["#0000FF"],
        ]
    ))
    let workspace = resolverSkin(try resolverManifest(
        "test.workspace",
        base: "test.global",
        values: [
            "surface": resolverSurface(fill: "#FF0000"),
            "typography": ["size": 14, "weight": "regular"],
            "palette": ["#FF0000"],
        ]
    ))
    let resolver = SkinResolver(
        builtIns: [clear, global, workspace],
        availableBaseIDs: ["webby.clear", "test.global", "test.workspace"]
    )

    let first = resolverResolve(
        resolver,
        workspace: "test.workspace",
        global: "test.global",
        note: NoteAppearance(paletteIndex: 0, hideDecoration: true)
    )
    let second = resolverResolve(
        resolver,
        workspace: "test.workspace",
        global: "test.global",
        note: NoteAppearance(paletteIndex: 0, hideDecoration: true)
    )

    #expect(first == second)
}
