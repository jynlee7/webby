import Foundation
import Testing
@testable import WebbyCore

private func accessibilityColor(_ hex: String) throws -> RGBAColor {
    try RGBAColor(hex: hex)
}

private func accessibilityTheme(
    fill: RGBAColor,
    text: RGBAColor,
    palette: [RGBAColor] = [],
    size: Double = 14,
    weight: SkinFontWeight = .known(.regular),
    material: SkinMaterial = .known(.popover),
    border: ResolvedBorder = ResolvedBorder(),
    highContrast: ResolvedHighContrast = ResolvedHighContrast(),
    orb: [SkinOrbState.Known: ResolvedOrbAnimation] = [:]
) -> ResolvedTheme {
    ResolvedTheme(
        skinID: "io.example.skin",
        baseID: "webby.clear",
        surface: ResolvedSurface(
            fill: fill,
            contrastBacking: ResolvedContrastBacking(
                overBlack: fill.replacingAlpha(1),
                overWhite: fill.replacingAlpha(1)
            ),
            material: material,
            border: border,
            text: text,
            placeholder: text,
            selection: .clear,
            caret: text
        ),
        typography: ResolvedTypography(
            family: nil,
            effectiveSize: size,
            weight: weight,
            lineSpacing: 2
        ),
        header: ResolvedHeader(height: 0, fill: fill, showsTitle: false),
        collapsed: ResolvedCollapsed(height: 24, fill: fill, showsFirstLine: true),
        icons: ResolvedIcons(tint: text),
        resizeHandle: ResolvedResizeHandle(tint: text),
        palette: palette,
        selectedIndex: palette.isEmpty ? nil : 0,
        library: ResolvedLibrary(accent: text, background: fill),
        orb: orb,
        sounds: ResolvedSounds(),
        accessibility: ResolvedAccessibility(),
        provenance: [.surface: "io.example.skin"],
        highContrast: highContrast
    )
}

private func assertAccessibilityPairsPass(
    _ theme: ResolvedTheme,
    requiredRatio: Double
) {
    let backdrops: [RGBAColor] = theme.surface.fill.a == 1
        ? [.white]
        : [.white, .black]

    for backdrop in backdrops {
        let surface = theme.surface.fill.composited(over: backdrop)
        let surfaceRatio = try? Contrast.contrastRatio(
            foreground: theme.surface.text,
            background: surface
        )
        #expect(
            (surfaceRatio ?? 0) >= requiredRatio,
            "text on surface is below \(requiredRatio):1"
        )

        for entry in theme.palette {
            let paletteFill = entry.composited(over: surface)
            let ratio = try? Contrast.contrastRatio(
                foreground: theme.surface.text,
                background: paletteFill
            )
            #expect(
                (ratio ?? 0) >= requiredRatio,
                "text on palette is below \(requiredRatio):1"
            )
        }
    }
}

@Test func defaultAccessibilitySettingsAreANoOp() {
    let theme = accessibilityTheme(fill: .white, text: .black)
    let resolution = AccessibilityTransform.apply(theme: theme, in: AccessibilitySettings())

    #expect(resolution.theme == theme)
    #expect(resolution.diagnostics.isEmpty)
    #expect(resolution.theme.accessibility == ResolvedAccessibility())
}

@Test func textScaleChangesEffectiveSizeAndTheRequiredRatioBoundary() throws {
    let fill = try accessibilityColor("#808080")
    let authoredText = try accessibilityColor("#333333")
    let theme = accessibilityTheme(fill: fill, text: authoredText)

    let unscaled = AccessibilityTransform.apply(theme: theme, in: AccessibilitySettings())
    #expect(unscaled.theme.typography.effectiveSize == 14)
    #expect(unscaled.theme.surface.text == .black)
    #expect(!unscaled.diagnostics.isEmpty)

    let scaled = AccessibilityTransform.apply(
        theme: theme,
        in: AccessibilitySettings(textScale: 1.5)
    )
    #expect(scaled.theme.typography.effectiveSize == 21)
    #expect(scaled.theme.accessibility.textScale == 1.5)
    #expect(scaled.theme.surface.text == authoredText)
    #expect(scaled.diagnostics.isEmpty)

    let largeBoundary = Contrast.requiredRatio(
        pointSize: scaled.theme.typography.effectiveSize,
        weight: scaled.theme.typography.weight
    )
    #expect(largeBoundary == 3)
    assertAccessibilityPairsPass(scaled.theme, requiredRatio: largeBoundary)
}

@Test func increaseContrastUsesOpaqueFillAndMaximumContrastWithoutOverrides() throws {
    let theme = accessibilityTheme(
        fill: try accessibilityColor("#80808080"),
        text: try accessibilityColor("#333333")
    )
    let resolution = AccessibilityTransform.apply(
        theme: theme,
        in: AccessibilitySettings(increaseContrast: true)
    )

    let expectedFill = try accessibilityColor("#808080")
    #expect(resolution.theme.surface.fill == expectedFill)
    #expect(resolution.theme.surface.fill.a == 1)
    #expect(resolution.theme.surface.text == .black)
    #expect(resolution.theme.surface.border == ResolvedBorder(width: 1, color: .black))
    #expect(resolution.theme.accessibility.increaseContrast)
    #expect(resolution.diagnostics.isEmpty)
    assertAccessibilityPairsPass(resolution.theme, requiredRatio: 4.5)
}

@Test func increaseContrastUsesProvidedOverrides() throws {
    let highContrast = ResolvedHighContrast(
        surfaceFill: try accessibilityColor("#000000"),
        surfaceTextColor: try accessibilityColor("#FFFFFF")
    )
    let theme = accessibilityTheme(
        fill: try accessibilityColor("#F0E0C0E6"),
        text: try accessibilityColor("#333333"),
        highContrast: highContrast
    )
    let resolution = AccessibilityTransform.apply(
        theme: theme,
        in: AccessibilitySettings(increaseContrast: true)
    )

    let expectedFill = try accessibilityColor("#000000")
    let expectedText = try accessibilityColor("#FFFFFF")
    #expect(resolution.theme.surface.fill == expectedFill)
    #expect(resolution.theme.surface.text == expectedText)
    #expect(resolution.theme.surface.border == ResolvedBorder(
        width: 1,
        color: expectedText
    ))
    #expect(resolution.diagnostics.isEmpty)
}

@Test func reduceTransparencyForcesAnOpaqueFillAndNoMaterial() throws {
    let theme = accessibilityTheme(
        fill: try accessibilityColor("#00000080"),
        text: .white,
        material: .known(.popover)
    )
    let resolution = AccessibilityTransform.apply(
        theme: theme,
        in: AccessibilitySettings(reduceTransparency: true)
    )

    #expect(resolution.theme.surface.fill == .black)
    #expect(resolution.theme.surface.fill.a == 1)
    #expect(resolution.theme.surface.material == .known(.none))
    #expect(resolution.theme.accessibility.reduceTransparency)
    #expect(resolution.diagnostics.isEmpty)
}

@Test func contrastRepairMeetsTheBodyFloor() throws {
    let gray = try accessibilityColor("#777777")
    let theme = accessibilityTheme(fill: gray, text: gray, palette: [gray])
    let resolution = AccessibilityTransform.apply(theme: theme, in: AccessibilitySettings())

    #expect(!resolution.diagnostics.isEmpty)
    #expect(resolution.theme.surface.text == .black)
    assertAccessibilityPairsPass(resolution.theme, requiredRatio: 4.5)
}

@Test func contrastRepairReplacesAnUnsafePaletteEntry() throws {
    let gray = try accessibilityColor("#777777")
    let theme = accessibilityTheme(fill: .black, text: .white, palette: [gray])
    let resolution = AccessibilityTransform.apply(theme: theme, in: AccessibilitySettings())

    #expect(!resolution.diagnostics.isEmpty)
    #expect(resolution.theme.surface.fill == .black)
    #expect(resolution.theme.surface.text == .white)
    #expect(resolution.theme.palette == [.black])
    assertAccessibilityPairsPass(resolution.theme, requiredRatio: 4.5)
}

@Test func reduceMotionFreezesTheOrbAtFrameZero() throws {
    let frameZero = ResolvedOrbFrameKey(
        skinID: "io.example.skin",
        state: .listening,
        frame: 0,
        appearance: .light,
        scale: .one
    )
    let frameOne = ResolvedOrbFrameKey(
        skinID: "io.example.skin",
        state: .listening,
        frame: 1,
        appearance: .light,
        scale: .one
    )
    let idleFrame = ResolvedOrbFrameKey(
        skinID: "io.example.skin",
        state: .idle,
        frame: 0,
        appearance: .light,
        scale: .one
    )
    let theme = accessibilityTheme(
        fill: .white,
        text: .black,
        orb: [
            .listening: ResolvedOrbAnimation(
                state: .listening,
                frameKeys: [frameZero, frameOne],
                fps: 24,
                loop: true,
                audioReactive: 0.15,
                tint: .clear
            ),
            .idle: ResolvedOrbAnimation(
                state: .idle,
                frameKeys: [idleFrame],
                fps: 0,
                loop: false,
                audioReactive: 0,
                tint: .clear
            ),
        ]
    )
    let resolution = AccessibilityTransform.apply(
        theme: theme,
        in: AccessibilitySettings(reduceMotion: true)
    )

    let listening = try #require(resolution.theme.orb[.listening])
    #expect(listening.frameKeys == [frameZero])
    #expect(listening.fps == 0)
    #expect(listening.loop == false)
    #expect(listening.audioReactive == 0)

    let idle = try #require(resolution.theme.orb[.idle])
    #expect(idle.frameKeys == [idleFrame])
    #expect(resolution.theme.accessibility.reduceMotion)
}

@Test func accessibilityTransformIsDeterministic() throws {
    let frameZero = ResolvedOrbFrameKey(
        skinID: "io.example.skin",
        state: .speaking,
        frame: 0,
        appearance: .dark,
        scale: .two
    )
    let frameOne = ResolvedOrbFrameKey(
        skinID: "io.example.skin",
        state: .speaking,
        frame: 1,
        appearance: .dark,
        scale: .two
    )
    let gray = try accessibilityColor("#777777")
    let theme = accessibilityTheme(
        fill: try accessibilityColor("#FFFFFF80"),
        text: gray,
        palette: [.black],
        orb: [
            .speaking: ResolvedOrbAnimation(
                state: .speaking,
                frameKeys: [frameZero, frameOne],
                fps: 24,
                loop: true,
                audioReactive: 0.1,
                tint: gray
            ),
        ]
    )
    let settings = AccessibilitySettings(
        reduceTransparency: true,
        increaseContrast: true,
        reduceMotion: true,
        textScale: 1.5
    )

    let first = AccessibilityTransform.apply(theme: theme, in: settings)
    let second = AccessibilityTransform.apply(theme: theme, in: settings)

    #expect(first == second)
    #expect(first.diagnostics.map(\.summary) == second.diagnostics.map(\.summary))
    #expect(!first.diagnostics.isEmpty)
    assertAccessibilityPairsPass(first.theme, requiredRatio: 3)
}
