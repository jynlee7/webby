import Foundation

/// The system and user accessibility inputs applied after skin resolution.
public struct AccessibilitySettings: Sendable, Equatable, Hashable {
    public let reduceTransparency: Bool
    public let increaseContrast: Bool
    public let reduceMotion: Bool
    public let textScale: Double

    public init(
        reduceTransparency: Bool = false,
        increaseContrast: Bool = false,
        reduceMotion: Bool = false,
        textScale: Double = 1
    ) {
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
        self.reduceMotion = reduceMotion
        self.textScale = textScale
    }
}

/// A transformed theme plus any repairs that were necessary.
public struct ThemeResolution: Sendable, Equatable {
    public let theme: ResolvedTheme
    public let diagnostics: [SkinDiagnostic]

    public init(theme: ResolvedTheme, diagnostics: [SkinDiagnostic] = []) {
        self.theme = theme
        self.diagnostics = diagnostics
    }
}

/// Applies the accessibility settings that always win over authored values.
public enum AccessibilityTransform {
    public static let minimumTextScale = 0.5
    public static let maximumTextScale = 3.0

    /// Applies text scale, Increase Contrast, Reduce Transparency, contrast repair
    /// and Reduce Motion, in that order. The function is pure and deterministic.
    public static func apply(
        theme: ResolvedTheme,
        in settings: AccessibilitySettings
    ) -> ThemeResolution {
        var diagnostics: [SkinDiagnostic] = []

        let textScale = sanitizedTextScale(settings.textScale)
        let authoredSize = theme.typography.effectiveSize
        let baseSize = authoredSize.isFinite && authoredSize > 0 ? authoredSize : 10
        let effectiveSize = sanitizedEffectiveSize(baseSize * textScale)
        let typography = ResolvedTypography(
            family: theme.typography.family,
            effectiveSize: effectiveSize,
            weight: theme.typography.weight,
            lineSpacing: theme.typography.lineSpacing
        )

        var surface = theme.surface
        var palette = theme.palette

        if settings.increaseContrast {
            let fill = theme.highContrast.surfaceFill ?? surface.fill.replacingAlpha(1)
            let text = theme.highContrast.surfaceTextColor ?? maxContrastText(for: fill)
            surface = replacingSurface(surface, fill: fill, text: text, border: ResolvedBorder(
                width: 1,
                color: text
            ))
        }

        if settings.reduceTransparency {
            surface = replacingSurface(
                surface,
                fill: surface.fill.replacingAlpha(1),
                material: .known(.none)
            )
        }

        let requiredRatio = Contrast.requiredRatio(
            pointSize: typography.effectiveSize,
            weight: typography.weight
        )
        if !passes(
            fill: surface.fill,
            text: surface.text,
            palette: palette,
            requiredRatio: requiredRatio
        ) {
            repairContrast(
                surface: &surface,
                palette: &palette,
                requiredRatio: requiredRatio,
                diagnostics: &diagnostics
            )
        }

        var orb = theme.orb
        if settings.reduceMotion {
            for (state, animation) in theme.orb {
                let frozenFrames = animation.frameKeys.first.map { [$0] } ?? []
                orb[state] = ResolvedOrbAnimation(
                    state: animation.state,
                    frameKeys: frozenFrames,
                    fps: 0,
                    loop: false,
                    audioReactive: 0,
                    tint: animation.tint
                )
            }
        }

        let accessibility = ResolvedAccessibility(
            reduceTransparency: settings.reduceTransparency,
            increaseContrast: settings.increaseContrast,
            reduceMotion: settings.reduceMotion,
            textScale: textScale
        )

        return ThemeResolution(
            theme: theme.replacing(
                surface: surface,
                typography: typography,
                palette: palette,
                orb: orb,
                accessibility: accessibility
            ),
            diagnostics: diagnostics
        )
    }

    private static func sanitizedTextScale(_ scale: Double) -> Double {
        guard scale.isFinite else {
            return 1
        }
        return min(max(scale, minimumTextScale), maximumTextScale)
    }

    private static func sanitizedEffectiveSize(_ size: Double) -> Double {
        guard size.isFinite, size > 0 else {
            return 10
        }
        return size
    }

    private static func maxContrastText(for fill: RGBAColor) -> RGBAColor {
        let background = fill.replacingAlpha(1)
        let blackRatio = (try? Contrast.contrastRatio(foreground: .black, background: background)) ?? 0
        let whiteRatio = (try? Contrast.contrastRatio(foreground: .white, background: background)) ?? 0
        return blackRatio >= whiteRatio ? .black : .white
    }

    private static func replacingSurface(
        _ surface: ResolvedSurface,
        fill: RGBAColor? = nil,
        text: RGBAColor? = nil,
        material: SkinMaterial? = nil,
        border: ResolvedBorder? = nil
    ) -> ResolvedSurface {
        let resolvedFill = fill ?? surface.fill
        // Editing cues sit on the same surface as body text. When the surface or
        // text changes, an authored caret or placeholder can become invisible, so
        // repair them against the new fill instead of leaving them untouched.
        let repairedText = text ?? surface.text
        let caret = readable(surface.caret, on: resolvedFill, fallback: repairedText)
        let placeholder = readable(surface.placeholder, on: resolvedFill, fallback: repairedText)
        return ResolvedSurface(
            fill: resolvedFill,
            // The backing has to match the fills the contrast checks used, so a
            // translucent override over a black page is grey, not white.
            contrastBacking: ResolvedContrastBacking(
                overBlack: resolvedFill.composited(over: .black),
                overWhite: resolvedFill.composited(over: .white)
            ),
            material: material ?? surface.material,
            image: surface.image,
            cornerRadius: surface.cornerRadius,
            border: border ?? surface.border,
            shadow: surface.shadow,
            padding: surface.padding,
            text: repairedText,
            placeholder: placeholder,
            selection: surface.selection,
            caret: caret
        )
    }

    /// Keeps an authored colour when it clears 3:1 against the fill, otherwise uses
    /// the repaired text colour, which the caller has already contrast-checked.
    private static func readable(
        _ color: RGBAColor,
        on fill: RGBAColor,
        fallback: RGBAColor
    ) -> RGBAColor {
        let background = fill.replacingAlpha(1)
        if let ratio = try? Contrast.contrastRatio(foreground: color, background: background),
           ratio >= 3 {
            return color
        }
        return fallback
    }

    private static func repairContrast(
        surface: inout ResolvedSurface,
        palette: inout [RGBAColor],
        requiredRatio: Double,
        diagnostics: inout [SkinDiagnostic]
    ) {
        let opaqueFill = surface.fill.replacingAlpha(1)
        let originalText = surface.text
        let originalPalette = palette

        // Prefer keeping the author's colors and simply making the surface opaque.
        if opaqueFill != surface.fill,
           passes(fill: opaqueFill, text: originalText, palette: palette, requiredRatio: requiredRatio)
        {
            surface = replacingSurface(surface, fill: opaqueFill)
            diagnostics.append(contrastDiagnostic(
                code: "accessibility-contrast-opaque-fill",
                group: SkinGroup.surface.rawValue,
                message: "Text contrast was below the floor; the surface fill was made opaque."
            ))
            return
        }

        // Next, keep the fill and use whichever of black or white reads best.
        let candidateText = maxContrastText(for: opaqueFill)
        if passes(
            fill: opaqueFill,
            text: candidateText,
            palette: palette,
            requiredRatio: requiredRatio
        ) {
            surface = replacingSurface(surface, fill: opaqueFill, text: candidateText)
            diagnostics.append(contrastDiagnostic(
                code: "accessibility-contrast-text-fallback",
                group: SkinGroup.surface.rawValue,
                message: "Text contrast was below the floor; black or white text was selected."
            ))
            return
        }

        // Keep the fill, take black or white text, and replace only the palette
        // entries that still cannot carry that text.
        for text in [RGBAColor.black, .white] {
            let repairedPalette = palette.map { entry in
                passes(
                    fill: opaqueFill,
                    text: text,
                    palette: [entry],
                    requiredRatio: requiredRatio
                ) ? entry : opaqueFill
            }
            if passes(
                fill: opaqueFill,
                text: text,
                palette: repairedPalette,
                requiredRatio: requiredRatio
            ) {
                surface = replacingSurface(surface, fill: opaqueFill, text: text)
                palette = repairedPalette
                diagnostics.append(contrastDiagnostic(
                    code: "accessibility-contrast-text-fallback",
                    group: SkinGroup.surface.rawValue,
                    message: "Text contrast was below the floor; black or white text was selected."
                ))
                if repairedPalette != originalPalette {
                    diagnostics.append(contrastDiagnostic(
                        code: "accessibility-contrast-palette-repair",
                        group: SkinGroup.palette.rawValue,
                        message: "Palette entries below the contrast floor were replaced with a safe fill."
                    ))
                }
                return
            }
        }

        // Guaranteed safe result: an extreme opaque fill with opposite maximum
        // contrast text. Any palette entry that still fails is replaced.
        for (safeFill, safeText) in [(RGBAColor.white, RGBAColor.black), (RGBAColor.black, .white)] {
            let repairedPalette = palette.map { entry in
                passes(
                    fill: safeFill,
                    text: safeText,
                    palette: [entry],
                    requiredRatio: requiredRatio
                ) ? entry : safeFill
            }
            if passes(
                fill: safeFill,
                text: safeText,
                palette: repairedPalette,
                requiredRatio: requiredRatio
            ) {
                surface = replacingSurface(surface, fill: safeFill, text: safeText)
                palette = repairedPalette
                diagnostics.append(contrastDiagnostic(
                    code: "accessibility-contrast-safe-fill",
                    group: SkinGroup.surface.rawValue,
                    message: "No authored fill could meet the contrast floor; a safe fill was selected."
                ))
                if repairedPalette != originalPalette {
                    diagnostics.append(contrastDiagnostic(
                        code: "accessibility-contrast-palette-repair",
                        group: SkinGroup.palette.rawValue,
                        message: "Palette entries below the contrast floor were replaced with a safe fill."
                    ))
                }
                return
            }
        }

        // The safe pair above always passes; this branch is defensive only.
        palette = []
        surface = replacingSurface(surface, fill: .white, text: .black)
        diagnostics.append(contrastDiagnostic(
            code: "accessibility-contrast-safe-fill",
            group: SkinGroup.surface.rawValue,
            message: "Palette entries were removed because no fill could meet the contrast floor."
        ))
    }

    private static func passes(
        fill: RGBAColor,
        text: RGBAColor,
        palette: [RGBAColor],
        requiredRatio: Double
    ) -> Bool {
        let backdrops = fill.a == 1 ? [RGBAColor.white] : [RGBAColor.white, RGBAColor.black]
        for backdrop in backdrops {
            let surface = fill.composited(over: backdrop)
            guard meets(text: text, background: surface, requiredRatio: requiredRatio) else {
                return false
            }
            for entry in palette {
                let fillColor = entry.composited(over: surface)
                guard meets(text: text, background: fillColor, requiredRatio: requiredRatio) else {
                    return false
                }
            }
        }
        return true
    }

    private static func meets(
        text: RGBAColor,
        background: RGBAColor,
        requiredRatio: Double
    ) -> Bool {
        guard let ratio = try? Contrast.contrastRatio(foreground: text, background: background) else {
            return false
        }
        return ratio >= requiredRatio
    }

    private static func contrastDiagnostic(
        code: String,
        group: String,
        message: String
    ) -> SkinDiagnostic {
        SkinDiagnostic(
            code: code,
            severity: .warning,
            path: [.key(group)],
            group: group,
            message: message
        )
    }
}
