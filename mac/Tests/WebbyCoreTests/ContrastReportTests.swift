import Foundation
import Testing
@testable import WebbyCore

private typealias Support = SkinLibraryTestSupport

private func monoSelection() -> SkinSelection {
    SkinSelection(skins: Support.builtInSkins(), availableBaseIDs: Set(Support.builtInIDs))
}

@Test func reportListsSurfaceAndEveryPaletteFillForBothAppearances() throws {
    let result = monoSelection().select(workspaceSkinID: "webby.mono", globalSkinID: nil)
    for (mode, resolution) in [(AppearanceMode.light, result.light), (.dark, result.dark)] {
        let pairs = ContrastReport.pairs(theme: resolution.theme, appearance: mode)
        #expect(pairs.count == 1 + resolution.theme.palette.count)
        #expect(pairs.first?.fill == .surface)
        let expectedFills: [ContrastPair.Fill] = (0..<6).map { .palette($0) }
        #expect(pairs.dropFirst().map(\.fill) == expectedFills)
        #expect(pairs.allSatisfy { $0.appearance == mode })
        #expect(pairs.allSatisfy { $0.passes })
    }
}

@Test func reportMatchesKnownRatioForMonoLightSurface() throws {
    let result = monoSelection().select(workspaceSkinID: "webby.mono", globalSkinID: nil)
    let pair = try #require(ContrastReport.pairs(theme: result.light.theme, appearance: .light).first)

    // #111318 text on an opaque #FFFFFF surface; the page behind is irrelevant.
    let expected = try Contrast.contrastRatio(
        foreground: try RGBAColor(hex: "#111318"),
        background: try RGBAColor(hex: "#FFFFFF")
    )
    #expect(abs(pair.measuredRatio - expected) < 1e-9)
    #expect(pair.requiredRatio == 4.5)
    #expect(pair.fillAlpha == 1)
    let floor = try #require(pair.minimumFillAlpha)
    #expect(floor <= pair.fillAlpha)
}

@Test func translucentSurfaceReportsWorstBackdropAndSolvedFloor() throws {
    let result = monoSelection().select(workspaceSkinID: "webby.clear", globalSkinID: nil)
    let pairs = ContrastReport.pairs(theme: result.light.theme, appearance: .light)
    let surface = try #require(pairs.first)
    // webby.clear is translucent; the report takes the worse of white and black pages.
    #expect(surface.fillAlpha < 1)
    #expect(surface.measuredRatio >= surface.requiredRatio)
    let floor = try #require(surface.minimumFillAlpha)
    #expect(floor <= surface.fillAlpha + 1e-6)

    let theme = result.light.theme
    let overBlack = theme.surface.fill.composited(over: .black)
    let overWhite = theme.surface.fill.composited(over: .white)
    let worst = min(
        try Contrast.contrastRatio(foreground: theme.surface.text, background: overBlack),
        try Contrast.contrastRatio(foreground: theme.surface.text, background: overWhite)
    )
    #expect(abs(surface.measuredRatio - worst) < 1e-9)
}

@Test func contrastPairPassesWhenMeasuredMeetsRequired() {
    let make = { (measured: Double) in
        ContrastPair(
            appearance: .light, fill: .surface, measuredRatio: measured,
            requiredRatio: 4.5, minimumFillAlpha: nil, fillAlpha: 1
        )
    }
    #expect(make(4.5).passes)
    #expect(!make(4.49).passes)
}
