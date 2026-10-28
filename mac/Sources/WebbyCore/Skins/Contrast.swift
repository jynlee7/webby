import Foundation

/// WCAG 2.2 relative luminance, contrast ratios, and the translucent-fill solver.
public enum Contrast {
    public enum Error: Swift.Error, Equatable, Sendable {
        case backgroundNotOpaque
    }

    /// WCAG relative luminance of an opaque color.
    public static func relativeLuminance(opaque color: RGBAColor) -> Double {
        let red = linearize(color.r)
        let green = linearize(color.g)
        let blue = linearize(color.b)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    /// WCAG contrast ratio. A translucent foreground is composited over the
    /// background first; the background must be opaque.
    public static func contrastRatio(foreground: RGBAColor, background: RGBAColor) throws -> Double {
        guard background.a == 1 else {
            throw Error.backgroundNotOpaque
        }

        let fg = foreground.a == 1 ? foreground : foreground.composited(over: background)
        let foregroundLuminance = relativeLuminance(opaque: fg)
        let backgroundLuminance = relativeLuminance(opaque: background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// The WCAG floor for committed skin font weights.
    public static func requiredRatio(pointSize: Double, weight: SkinFontWeight.Known) -> Double {
        requiredRatio(pointSize: pointSize, isBold: isBoldOrHeavier(weight))
    }

    /// Convenience for resolved weights, including unrecognized values.
    public static func requiredRatio(pointSize: Double, weight: SkinFontWeight) -> Double {
        switch weight {
        case .known(let known):
            return requiredRatio(pointSize: pointSize, weight: known)
        case .unknown(let rawValue):
            return requiredRatio(pointSize: pointSize, isBold: isBoldOrHeavier(rawValue))
        }
    }

    /// Convenience for callers that already resolved a bold-or-heavier flag.
    public static func requiredRatio(pointSize: Double, isBold: Bool) -> Double {
        if pointSize >= 18 {
            return 3.0
        }
        if pointSize >= 14 && isBold {
            return 3.0
        }
        return 4.5
    }

    /// The smallest surface alpha at or above `minimumAlpha` that keeps `text`
    /// readable over every palette fill on both a white and a black backdrop.
    ///
    /// Feasibility is not assumed to be monotonic. The solver samples the whole
    /// interval, then bisects the boundary around the first feasible sample and
    /// returns a re-verified feasible value.
    public static func minimumFillAlpha(
        surface: RGBAColor,
        palette: [RGBAColor],
        text: RGBAColor,
        minimumAlpha: Double,
        requiredRatio: Double
    ) -> AlphaSolution {
        let start = min(max(minimumAlpha, 0), 1)

        if isFeasible(
            alpha: start,
            surface: surface,
            palette: palette,
            text: text,
            requiredRatio: requiredRatio
        ) {
            return .feasible(start)
        }

        guard start < 1 else {
            return .impossible
        }

        let sampleCount = 4096
        var previous = start
        for index in 1...sampleCount {
            let alpha = start + (1 - start) * Double(index) / Double(sampleCount)
            if isFeasible(
                alpha: alpha,
                surface: surface,
                palette: palette,
                text: text,
                requiredRatio: requiredRatio
            ) {
                return refinedSolution(
                    low: previous,
                    high: alpha,
                    surface: surface,
                    palette: palette,
                    text: text,
                    requiredRatio: requiredRatio
                )
            }
            previous = alpha
        }

        return .impossible
    }

    private static func refinedSolution(
        low: Double,
        high: Double,
        surface: RGBAColor,
        palette: [RGBAColor],
        text: RGBAColor,
        requiredRatio: Double
    ) -> AlphaSolution {
        let tolerance = 1e-7
        var lower = low
        var upper = high

        while upper - lower > tolerance {
            let middle = (lower + upper) / 2
            guard middle > lower, middle < upper else {
                break
            }
            if isFeasible(
                alpha: middle,
                surface: surface,
                palette: palette,
                text: text,
                requiredRatio: requiredRatio
            ) {
                upper = middle
            } else {
                lower = middle
            }
        }

        if isFeasible(
            alpha: upper,
            surface: surface,
            palette: palette,
            text: text,
            requiredRatio: requiredRatio
        ) {
            return .feasible(upper)
        }

        return .feasible(high)
    }

    private static func isFeasible(
        alpha: Double,
        surface: RGBAColor,
        palette: [RGBAColor],
        text: RGBAColor,
        requiredRatio: Double
    ) -> Bool {
        let candidate = surface.replacingAlpha(alpha)
        let overBlack = candidate.composited(over: .black)
        let overWhite = candidate.composited(over: .white)

        // The untinted surface is a real rendering too, so it has to pass on its own
        // before any palette fill is composited over it.
        guard passes(text: text, background: overBlack, requiredRatio: requiredRatio),
              passes(text: text, background: overWhite, requiredRatio: requiredRatio)
        else {
            return false
        }

        for fill in palette {
            let onBlack = fill.composited(over: overBlack)
            let onWhite = fill.composited(over: overWhite)
            guard passes(text: text, background: onBlack, requiredRatio: requiredRatio),
                  passes(text: text, background: onWhite, requiredRatio: requiredRatio)
            else {
                return false
            }
        }
        return true
    }

    private static func passes(
        text: RGBAColor,
        background: RGBAColor,
        requiredRatio: Double
    ) -> Bool {
        guard let ratio = try? contrastRatio(foreground: text, background: background) else {
            return false
        }
        return ratio >= requiredRatio
    }

    private static func linearize(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    private static func isBoldOrHeavier(_ weight: SkinFontWeight.Known) -> Bool {
        switch weight {
        case .bold, .heavy, .black:
            return true
        case .ultraLight, .thin, .light, .regular, .medium, .semibold:
            return false
        }
    }

    private static func isBoldOrHeavier(_ rawValue: String) -> Bool {
        switch rawValue.lowercased() {
        case "bold", "bolder", "heavy", "black":
            return true
        default:
            guard let numericWeight = Double(rawValue) else {
                return false
            }
            return numericWeight >= 700
        }
    }
}

public enum AlphaSolution: Sendable, Equatable, Hashable {
    case feasible(Double)
    case impossible
}
