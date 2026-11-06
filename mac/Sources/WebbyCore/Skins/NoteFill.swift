import Foundation

extension ResolvedTheme {
    /// The note's palette color, or nil when it shows the bare surface.
    public var selectedPaletteColor: RGBAColor? {
        guard let index = selectedIndex, palette.indices.contains(index) else { return nil }
        return palette[index]
    }

    /// An opaque fill for text when artwork covers the surface: the selected
    /// palette color over the surface over a black or white page. These are the
    /// composites `ContrastReport` and the resolver measure, so text on this fill
    /// meets the floor whatever the artwork looks like (design.md principle 2).
    public func textBacking(page: AppearanceMode) -> RGBAColor {
        let base = page == .dark ? surface.contrastBacking.overBlack : surface.contrastBacking.overWhite
        return selectedPaletteColor.map { $0.composited(over: base) } ?? base
    }
}
