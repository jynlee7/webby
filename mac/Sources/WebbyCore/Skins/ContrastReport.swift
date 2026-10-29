import Foundation

/// One text-on-fill pair the install preview lists.
public struct ContrastPair: Sendable, Equatable {
    public enum Fill: Sendable, Equatable {
        /// The surface alone, with no palette tint.
        case surface
        /// A palette slot composited over the surface.
        case palette(Int)
    }

    public let appearance: AppearanceMode
    public let fill: Fill
    /// The lowest ratio of the surface text over this fill, measured over a white
    /// page and over a black page.
    public let measuredRatio: Double
    public let requiredRatio: Double
    /// The smallest surface alpha at which this pair passes on both pages, or nil
    /// when no alpha does.
    public let minimumFillAlpha: Double?
    /// The surface alpha the resolved theme uses.
    public let fillAlpha: Double

    public var passes: Bool {
        measuredRatio >= requiredRatio
    }
}

/// Builds the contrast rows for a resolved theme. Pure; reuses `Contrast` so the
/// preview and the resolver judge pairs by the same rules.
public enum ContrastReport {
    /// The surface text over the bare surface and over each palette fill.
    ///
    /// `theme` is the resolver's output, whose surface alpha has already been
    /// raised to the floor, so authored skins normally pass; a failing row means the
    /// resolver could not repair that pair.
    public static func pairs(theme: ResolvedTheme, appearance: AppearanceMode) -> [ContrastPair] {
        let required = Contrast.requiredRatio(
            pointSize: theme.typography.effectiveSize,
            weight: theme.typography.weight
        )
        let surface = theme.surface
        let fills: [(ContrastPair.Fill, [RGBAColor])] =
            [(.surface, [])] + theme.palette.enumerated().map { (.palette($0.offset), [$0.element]) }

        return fills.map { fill, palette in
            let measured = [RGBAColor.black, RGBAColor.white].map { page -> Double in
                let base = surface.fill.composited(over: page)
                let background = palette.first.map { $0.composited(over: base) } ?? base
                return (try? Contrast.contrastRatio(foreground: surface.text, background: background)) ?? 0
            }.min() ?? 0

            let solved = Contrast.minimumFillAlpha(
                surface: surface.fill,
                palette: palette,
                text: surface.text,
                minimumAlpha: 0,
                requiredRatio: required
            )
            let floor: Double?
            if case .feasible(let alpha) = solved { floor = alpha } else { floor = nil }

            return ContrastPair(
                appearance: appearance,
                fill: fill,
                measuredRatio: measured,
                requiredRatio: required,
                minimumFillAlpha: floor,
                fillAlpha: surface.fill.a
            )
        }
    }
}
