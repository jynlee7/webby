import Foundation

/// The theme a note shows in both appearances, plus what the note menu needs.
public struct SkinSelectionResult: Sendable, Equatable {
    public let light: ThemeResolution
    public let dark: ThemeResolution
    /// The skin that was actually applied after fallbacks.
    public let effectiveSkinID: String
    /// How many palette slots the effective skin offers; zero hides the color menu.
    public let paletteSlotCount: Int
    /// Whether the effective skin has a decoration image at all, shown or hidden.
    public let hasDecoration: Bool

    public func resolution(for appearance: AppearanceMode) -> ThemeResolution {
        appearance == .dark ? dark : light
    }
}

/// Picks the theme for a note: workspace skin, then global skin, then `webby.clear`.
/// A thin layer over `SkinResolver` that resolves both appearances at once.
public struct SkinSelection: Sendable {
    private let resolver: SkinResolver

    /// `skins` is the whole catalog, built-in and user, in any order.
    public init(skins: [InstalledSkin], availableBaseIDs: Set<String>) {
        resolver = SkinResolver(builtIns: skins, availableBaseIDs: availableBaseIDs)
    }

    public func select(
        workspaceSkinID: String?,
        globalSkinID: String?,
        noteAppearance: NoteAppearance? = nil,
        accessibility: AccessibilitySettings = AccessibilitySettings(),
        textScale: Double = 1
    ) -> SkinSelectionResult {
        func resolve(_ mode: AppearanceMode) -> ThemeResolution {
            resolver.resolve(
                workspaceSkinID: workspaceSkinID,
                globalSkinID: globalSkinID,
                requested: mode,
                noteAppearance: noteAppearance,
                accessibility: accessibility,
                textScale: textScale
            )
        }
        let light = resolve(.light)
        let dark = resolve(.dark)
        return SkinSelectionResult(
            light: light,
            dark: dark,
            effectiveSkinID: light.theme.skinID,
            paletteSlotCount: light.theme.palette.count,
            hasDecoration: light.theme.decoration.image != nil || dark.theme.decoration.image != nil
        )
    }
}
