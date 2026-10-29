import Foundation
import Testing
@testable import WebbyCore

private func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) throws -> RGBAColor {
    try RGBAColor(r: r, g: g, b: b, a: a)
}

private func meetsContrast(
    _ alpha: Double,
    surface: RGBAColor,
    palette: [RGBAColor],
    text: RGBAColor,
    required: Double
) -> Bool {
    guard let candidate = try? RGBAColor(r: surface.r, g: surface.g, b: surface.b, a: alpha) else {
        return false
    }

    for backdrop in [RGBAColor.black, RGBAColor.white] {
        let surfaceBackground = candidate.composited(over: backdrop)
        // The untinted surface is rendered too, so it is part of the requirement.
        let backgrounds = [surfaceBackground]
            + palette.map { $0.composited(over: surfaceBackground) }

        for background in backgrounds {
            guard let ratio = try? Contrast.contrastRatio(foreground: text, background: background),
                  ratio >= required
            else {
                return false
            }
        }
    }
    return true
}

@Test func luminanceAnchorsAtBlackAndWhite() {
    #expect(Contrast.relativeLuminance(opaque: .black) == 0)
    #expect(abs(Contrast.relativeLuminance(opaque: .white) - 1) < 1e-12)
}

@Test func contrastRatioIsSymmetric() throws {
    let red = try color(1, 0, 0)
    let white = RGBAColor.white
    let forward = try Contrast.contrastRatio(foreground: red, background: white)
    let reverse = try Contrast.contrastRatio(foreground: white, background: red)
    #expect(abs(forward - reverse) < 1e-12)
}

@Test func midGrayOnWhiteIsJustBelowTheBodyFloor() throws {
    let gray = try RGBAColor(hex: "#777777")
    let ratio = try Contrast.contrastRatio(foreground: gray, background: .white)
    #expect(abs(ratio - 4.47809) < 1e-6)
    #expect(ratio < 4.5)
}

@Test func translucentForegroundIsCompositedBeforeMeasuring() throws {
    let translucentBlack = try color(0, 0, 0, 0.5)
    let ratio = try Contrast.contrastRatio(foreground: translucentBlack, background: .white)
    #expect(ratio > 3.97)
    #expect(ratio < 3.98)
    #expect(ratio < 4.5)

    let opaqueBlack = try color(0, 0, 0, 1)
    let opaqueRatio = try Contrast.contrastRatio(foreground: opaqueBlack, background: .white)
    #expect(abs(opaqueRatio - 21) < 1e-12)
}

@Test func contrastRequiresAnOpaqueBackground() throws {
    let translucentBackground = try color(1, 1, 1, 0.5)
    #expect(throws: Contrast.Error.backgroundNotOpaque) {
        try Contrast.contrastRatio(foreground: .black, background: translucentBackground)
    }
}

@Test func requiredRatioMatchesTheWCAGLargeTextBoundary() {
    #expect(Contrast.requiredRatio(pointSize: 13, weight: .bold) == 4.5)
    #expect(Contrast.requiredRatio(pointSize: 14, weight: .bold) == 3)
    #expect(Contrast.requiredRatio(pointSize: 18, weight: .regular) == 3)
    #expect(Contrast.requiredRatio(pointSize: 17.99, weight: .regular) == 4.5)
    #expect(Contrast.requiredRatio(pointSize: 14, weight: .regular) == 4.5)
    #expect(Contrast.requiredRatio(pointSize: 14, weight: .semibold) == 4.5)
    #expect(Contrast.requiredRatio(pointSize: 14, weight: .heavy) == 3)
}

@Test func requiredRatioConvenienceHandlesResolvedAndNumericWeights() {
    #expect(Contrast.requiredRatio(pointSize: 14, weight: SkinFontWeight.known(.bold)) == 3)
    #expect(Contrast.requiredRatio(pointSize: 14, weight: .unknown("700")) == 3)
    #expect(Contrast.requiredRatio(pointSize: 14, weight: .unknown("600")) == 4.5)
    #expect(Contrast.requiredRatio(pointSize: 13.99, weight: .unknown("900")) == 4.5)
    #expect(Contrast.requiredRatio(pointSize: 18, isBold: false) == 3)
    #expect(Contrast.requiredRatio(pointSize: 13.99, isBold: true) == 4.5)
}

@Test func solverReturnsAnAlreadyPassingMinimum() throws {
    let surface = RGBAColor.white
    let solution = Contrast.minimumFillAlpha(
        surface: surface,
        palette: [],
        text: .black,
        minimumAlpha: 0.5,
        requiredRatio: 4.5
    )
    #expect(solution == .feasible(0.5))
}

@Test func solverFindsTheMinimalVerifiedRaise() throws {
    let surface = RGBAColor.white
    let solution = Contrast.minimumFillAlpha(
        surface: surface,
        palette: [],
        text: .black,
        minimumAlpha: 0.4,
        requiredRatio: 4.5
    )

    guard case .feasible(let alpha) = solution else {
        Issue.record("Expected a feasible opacity, got \(solution)")
        return
    }

    #expect(alpha > 0.4)
    #expect(alpha > 0.454)
    #expect(alpha < 0.457)
    #expect(meetsContrast(alpha, surface: surface, palette: [], text: .black, required: 4.5))
    #expect(!meetsContrast(alpha - 1e-4, surface: surface, palette: [], text: .black, required: 4.5))
}

@Test func solverReportsImpossibleWhenEveryAlphaFails() throws {
    let grayText = try RGBAColor(hex: "#777777")
    let solution = Contrast.minimumFillAlpha(
        surface: .white,
        palette: [.white],
        text: grayText,
        minimumAlpha: 0,
        requiredRatio: 4.5
    )
    #expect(solution == .impossible)
}

@Test func solverUsesTheWorstPaletteEntry() throws {
    let surface = RGBAColor.white
    let palette = [
        try color(1, 1, 1, 0.8),
        try color(1, 1, 1, 0.2),
    ]
    let solution = Contrast.minimumFillAlpha(
        surface: surface,
        palette: palette,
        text: .black,
        minimumAlpha: 0.2,
        requiredRatio: 4.5
    )

    guard case .feasible(let alpha) = solution else {
        Issue.record("Expected a feasible opacity, got \(solution)")
        return
    }

    // The untinted surface must also pass, which sets the floor near 0.455.
    #expect(alpha > 0.45)
    #expect(alpha < 0.46)
    #expect(meetsContrast(alpha, surface: surface, palette: palette, text: .black, required: 4.5))
    #expect(!meetsContrast(alpha - 1e-4, surface: surface, palette: palette, text: .black, required: 4.5))
}

@Test func solverCompositesTranslucentText() throws {
    let surface = RGBAColor.white
    let translucentText = try color(0, 0, 0, 0.8)
    let solution = Contrast.minimumFillAlpha(
        surface: surface,
        palette: [],
        text: translucentText,
        minimumAlpha: 0.5,
        requiredRatio: 4.5
    )

    guard case .feasible(let alpha) = solution else {
        Issue.record("Expected a feasible opacity, got \(solution)")
        return
    }

    #expect(alpha > 0.5)
    #expect(alpha < 0.55)
    #expect(meetsContrast(alpha, surface: surface, palette: [], text: translucentText, required: 4.5))
    #expect(!meetsContrast(0.5, surface: surface, palette: [], text: translucentText, required: 4.5))
}

@Test func solverDoesNotAssumeMonotonicFeasibility() throws {
    let surface = RGBAColor.white
    let grayText = try RGBAColor(hex: "#777777")
    let required = 4.4

    #expect(!meetsContrast(0.5, surface: surface, palette: [], text: grayText, required: required))
    #expect(!meetsContrast(0.75, surface: surface, palette: [], text: grayText, required: required))
    #expect(meetsContrast(1, surface: surface, palette: [], text: grayText, required: required))

    let solution = Contrast.minimumFillAlpha(
        surface: surface,
        palette: [],
        text: grayText,
        minimumAlpha: 0.5,
        requiredRatio: required
    )

    guard case .feasible(let alpha) = solution else {
        Issue.record("Expected a feasible opacity, got \(solution)")
        return
    }

    #expect(alpha > 0.9)
    #expect(meetsContrast(alpha, surface: surface, palette: [], text: grayText, required: required))
    #expect(!meetsContrast(alpha - 1e-4, surface: surface, palette: [], text: grayText, required: required))
}
