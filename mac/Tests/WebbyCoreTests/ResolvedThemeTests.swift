import Foundation
import Testing
@testable import WebbyCore

private func resolvedThemeRepositoryRoot() -> URL {
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

private func resolvedThemeBuiltInManifest(_ id: String) throws -> SkinManifest {
    let url = resolvedThemeRepositoryRoot()
        .appendingPathComponent("mac/Resources/Skins/\(id)/skin.json")
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(SkinManifest.self, from: data)
}

private func resolvedThemeColor(
    _ token: SkinColor,
    _ appearance: SkinAppearance
) throws -> RGBAColor {
    try RGBAColor(hex: appearance == .light ? token.light : token.dark)
}

private func resolvedThemeFromBuiltInManifest() throws -> (theme: ResolvedTheme, manifest: SkinManifest) {
    let manifest = try resolvedThemeBuiltInManifest("webby.clear")
    let appearance = SkinAppearance.dark
    let surface = try #require(manifest.surface)
    let typography = try #require(manifest.typography)
    let header = try #require(manifest.header)
    let collapsed = try #require(manifest.collapsed)
    let decoration = try #require(manifest.decoration)
    let icons = try #require(manifest.icons)
    let resizeHandle = try #require(manifest.resizeHandle)
    let paletteTokens = try #require(manifest.palette)
    let highContrast = try #require(manifest.highContrast)

    let fill = try resolvedThemeColor(try #require(surface.fill), appearance)
    let text = try resolvedThemeColor(try #require(surface.text?.color), appearance)
    let placeholder = try resolvedThemeColor(try #require(surface.placeholderColor), appearance)
    let selection = try resolvedThemeColor(try #require(surface.selection), appearance)
    let caret = try resolvedThemeColor(try #require(surface.caret), appearance)
    let borderColor = try resolvedThemeColor(
        surface.border?.color ?? surface.text?.color ?? SkinColor("#000000"),
        appearance
    )
    let palette = try paletteTokens.map { try resolvedThemeColor($0, appearance) }

    let surfaceImageKey = ResolvedImageKey(
        skinID: manifest.id,
        element: .noteBody,
        appearance: appearance,
        scale: .two
    )
    let surfaceImage = ResolvedSurfaceImage(
        key: surfaceImageKey,
        availableScales: [.one, .two],
        insets: surface.image?.insets ?? SkinInsets(top: 14, left: 14, bottom: 18, right: 14),
        mode: .known(.stretch),
        tintWithPalette: true
    )

    let headerImageKey = ResolvedImageKey(
        skinID: manifest.id,
        element: .noteHeader,
        appearance: appearance,
        scale: .one
    )
    let headerImage = ResolvedImage(key: headerImageKey, availableScales: [.one, .two])

    let decorationKey = ResolvedImageKey(
        skinID: manifest.id,
        element: .decoration,
        appearance: appearance,
        scale: .two
    )
    let decorationImage = ResolvedImage(key: decorationKey, availableScales: [.one, .two])

    let iconTint = try resolvedThemeColor(try #require(icons.tint), appearance)
    let resizeTint = try resolvedThemeColor(
        resizeHandle.tint ?? icons.tint ?? surface.caret ?? SkinColor("#000000"),
        appearance
    )

    var orbFrames: [ResolvedOrbFrameKey] = []
    for frame in 0..<2 {
        orbFrames.append(ResolvedOrbFrameKey(
            skinID: manifest.id,
            state: .listening,
            frame: frame,
            appearance: appearance,
            scale: .two
        ))
    }

    let sounds = ResolvedSounds(
        byEvent: [
            .known(.noteSave): ResolvedSoundKey(
                skinID: manifest.id,
                event: .known(.noteSave)
            ),
        ],
        volume: 0.6,
        muted: [.known(.noteDelete)]
    )

    let theme = ResolvedTheme(
        skinID: manifest.id,
        baseID: manifest.base ?? "webby.clear",
        surface: ResolvedSurface(
            fill: fill,
            contrastBacking: ResolvedContrastBacking(
                overBlack: fill.composited(over: .black),
                overWhite: fill.composited(over: .white)
            ),
            material: .known(.popover),
            image: surfaceImage,
            cornerRadius: try #require(surface.cornerRadius),
            border: ResolvedBorder(
                width: surface.border?.width ?? 1,
                color: borderColor
            ),
            shadow: .known(.soft),
            padding: try #require(surface.padding),
            text: text,
            placeholder: placeholder,
            selection: selection,
            caret: caret
        ),
        typography: ResolvedTypography(
            family: typography.font?.family,
            effectiveSize: try #require(typography.size),
            weight: try #require(typography.weight),
            lineSpacing: try #require(typography.lineSpacing)
        ),
        header: ResolvedHeader(
            height: try #require(header.height),
            fill: fill,
            showsTitle: header.showsTitle ?? false,
            image: headerImage
        ),
        collapsed: ResolvedCollapsed(
            height: try #require(collapsed.height),
            fill: fill,
            showsFirstLine: collapsed.showsFirstLine ?? false,
            image: headerImage
        ),
        decoration: ResolvedDecoration(
            image: decorationImage,
            anchor: .known(.topCenter),
            origin: .known(.center),
            offset: ResolvedOffset(x: 1, y: -2),
            rotation: -3,
            hidden: decoration.hidden ?? false
        ),
        icons: ResolvedIcons(
            collapse: ResolvedImage(key: ResolvedImageKey(
                skinID: manifest.id,
                element: .iconCollapse,
                appearance: appearance,
                scale: .one
            )),
            expand: ResolvedImage(key: ResolvedImageKey(
                skinID: manifest.id,
                element: .iconExpand,
                appearance: appearance,
                scale: .one
            )),
            close: ResolvedImage(key: ResolvedImageKey(
                skinID: manifest.id,
                element: .iconClose,
                appearance: appearance,
                scale: .one
            )),
            more: ResolvedImage(key: ResolvedImageKey(
                skinID: manifest.id,
                element: .iconMore,
                appearance: appearance,
                scale: .one
            )),
            template: icons.template ?? false,
            tint: iconTint
        ),
        resizeHandle: ResolvedResizeHandle(
            visibility: try #require(resizeHandle.visibility),
            tint: resizeTint,
            image: ResolvedImage(key: ResolvedImageKey(
                skinID: manifest.id,
                element: .resizeHandle,
                appearance: appearance,
                scale: .one
            ))
        ),
        palette: palette,
        selectedIndex: 2,
        library: ResolvedLibrary(
            accent: try resolvedThemeColor(try #require(surface.caret), appearance),
            sidebarMaterial: .known(.sidebar),
            cardStyle: .known(.note),
            background: fill
        ),
        orb: [
            .listening: ResolvedOrbAnimation(
                state: .listening,
                frameKeys: orbFrames,
                fps: 24,
                loop: true,
                audioReactive: 0.15,
                tint: fill
            ),
        ],
        sounds: sounds,
        accessibility: ResolvedAccessibility(),
        provenance: [
            .surface: manifest.id,
            .palette: manifest.id,
            .icons: manifest.id,
        ],
        highContrast: ResolvedHighContrast(
            surfaceFill: try resolvedThemeColor(
                try #require(highContrast.surfaceFill),
                appearance
            ),
            surfaceTextColor: try resolvedThemeColor(
                try #require(highContrast.surfaceTextColor),
                appearance
            )
        )
    )
    return (theme, manifest)
}

@Test func resolvedThemeHoldsEveryBuiltInLikeValue() throws {
    let (theme, manifest) = try resolvedThemeFromBuiltInManifest()
    let expectedText = try RGBAColor(hex: "#F1F2F4")
    let expectedPlaceholder = try RGBAColor(hex: "#B9BFCA")
    let expectedSelection = try RGBAColor(hex: "#F1F2F426")
    let expectedPaletteEntry = try RGBAColor(hex: "#5C2A36E6")
    let expectedHighContrastFill = try RGBAColor(hex: "#000000")
    let expectedHighContrastText = try RGBAColor(hex: "#FFFFFF")

    #expect(theme.skinID == "webby.clear")
    #expect(theme.baseID == "webby.clear")
    #expect(theme.provenance[.surface] == manifest.id)
    #expect(theme.provenance[.palette] == manifest.id)

    #expect(theme.surface.fill.a == 230.0 / 255.0)
    #expect(theme.surface.contrastBacking.overWhite == theme.surface.fill.composited(over: .white))
    #expect(theme.surface.contrastBacking.overBlack == theme.surface.fill.composited(over: .black))
    #expect(theme.surface.material == .known(.popover))
    #expect(theme.surface.image?.key.element == .noteBody)
    #expect(theme.surface.image?.key.appearance == .dark)
    #expect(theme.surface.image?.key.scale == .two)
    #expect(theme.surface.image?.availableScales == [.one, .two])
    #expect(theme.surface.image?.insets == SkinInsets(top: 14, left: 14, bottom: 18, right: 14))
    #expect(theme.surface.image?.mode == .known(.stretch))
    #expect(theme.surface.image?.tintWithPalette == true)
    #expect(theme.surface.cornerRadius == 16)
    #expect(theme.surface.border.width == 1)
    #expect(theme.surface.shadow == .known(.soft))
    #expect(theme.surface.padding == SkinInsets(top: 12, left: 14, bottom: 14, right: 14))
    #expect(theme.surface.text == expectedText)
    #expect(theme.surface.placeholder == expectedPlaceholder)
    #expect(theme.surface.selection == expectedSelection)
    #expect(theme.surface.caret == expectedText)

    #expect(theme.typography.family == nil)
    #expect(theme.typography.effectiveSize == 14)
    #expect(theme.typography.weight == .known(.regular))
    #expect(theme.typography.lineSpacing == 3)

    #expect(theme.header.height == 0)
    #expect(theme.header.showsTitle == false)
    #expect(theme.header.image?.key.element == .noteHeader)
    #expect(theme.collapsed.height == 32)
    #expect(theme.collapsed.showsFirstLine == true)
    #expect(theme.collapsed.image?.key.element == .noteHeader)

    #expect(theme.decoration.image?.key.element == .decoration)
    #expect(theme.decoration.anchor == .known(.topCenter))
    #expect(theme.decoration.origin == .known(.center))
    #expect(theme.decoration.offset == ResolvedOffset(x: 1, y: -2))
    #expect(theme.decoration.rotation == -3)
    #expect(theme.decoration.hidden == true)

    #expect(theme.icons.collapse?.key.element == .iconCollapse)
    #expect(theme.icons.expand?.key.element == .iconExpand)
    #expect(theme.icons.close?.key.element == .iconClose)
    #expect(theme.icons.more?.key.element == .iconMore)
    #expect(theme.icons.template == true)
    #expect(theme.icons.tint == expectedText)
    #expect(theme.resizeHandle.visibility == .known(.hover))
    #expect(theme.resizeHandle.image?.key.element == .resizeHandle)

    #expect(theme.palette.count == 6)
    #expect(theme.selectedIndex == 2)
    #expect(theme.palette[2] == expectedPaletteEntry)

    #expect(theme.library.sidebarMaterial == .known(.sidebar))
    #expect(theme.library.cardStyle == .known(.note))
    #expect(theme.library.background == theme.surface.fill)

    #expect(theme.orb[.listening]?.frameKeys.map(\.frame) == [0, 1])
    #expect(theme.orb[.listening]?.fps == 24)
    #expect(theme.orb[.listening]?.loop == true)
    #expect(theme.orb[.listening]?.audioReactive == 0.15)
    #expect(theme.sounds.volume == 0.6)
    #expect(theme.sounds.byEvent[.known(.noteSave)]?.event == .known(.noteSave))
    #expect(theme.sounds.muted == [.known(.noteDelete)])

    #expect(theme.accessibility == ResolvedAccessibility())
    #expect(theme.highContrast.surfaceFill == expectedHighContrastFill)
    #expect(theme.highContrast.surfaceTextColor == expectedHighContrastText)
}

@Test func resolvedImageKeysCarryAppearanceAndScale() throws {
    let lightOneX = ResolvedImageKey(
        skinID: "io.example.skin",
        element: .noteBody,
        appearance: .light,
        scale: .one
    )
    let darkTwoX = ResolvedImageKey(
        skinID: "io.example.skin",
        element: .noteBody,
        appearance: .dark,
        scale: .two
    )

    #expect(lightOneX.relativeName == "images/note-body.png")
    #expect(darkTwoX.relativeName == "images/note-body~dark@2x.png")
    #expect(ResolvedImage(key: lightOneX).availableScales == [.one])

    let orbFrame = ResolvedOrbFrameKey(
        skinID: "io.example.skin",
        state: .thinking,
        frame: 4,
        appearance: .dark,
        scale: .two
    )
    #expect(orbFrame.relativeName == "images/orb-thinking-4~dark@2x.png")

    let sound = ResolvedSoundKey(skinID: "io.example.skin", event: .known(.voiceError))
    #expect(sound.relativeStem == "sounds/voice-error")
}

@Test func resolvedThemeKeepsTheSelectedPaletteEntry() throws {
    let (theme, _) = try resolvedThemeFromBuiltInManifest()
    let selectedIndex = try #require(theme.selectedIndex)
    let expectedPaletteEntry = try RGBAColor(hex: "#5C2A36E6")

    #expect(theme.palette.indices.contains(selectedIndex))
    #expect(theme.palette[selectedIndex] == expectedPaletteEntry)
    #expect(theme.replacing(palette: [.black, .white]).selectedIndex == selectedIndex)
}
