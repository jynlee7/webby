import Foundation
import Testing
@testable import WebbyCore

private typealias Support = SkinLibraryTestSupport

private func select(_ skinID: String, paletteIndex: Int?) -> SkinSelectionResult {
    SkinSelection(skins: Support.builtInSkins(), availableBaseIDs: Set(Support.builtInIDs))
        .select(
            workspaceSkinID: skinID,
            globalSkinID: nil,
            noteAppearance: NoteAppearance(paletteIndex: paletteIndex)
        )
}

@Test(arguments: Support.builtInIDs)
func eachPaletteSlotGivesImageFreeBuiltInsADifferentColor(skinID: String) throws {
    let plain = select(skinID, paletteIndex: nil)
    #expect(plain.light.theme.surface.image == nil)
    #expect(plain.light.theme.selectedPaletteColor == nil)

    let count = plain.paletteSlotCount
    #expect(count > 1)
    var colors: [RGBAColor] = []
    for index in 0..<count {
        let theme = select(skinID, paletteIndex: index).light.theme
        colors.append(try #require(theme.selectedPaletteColor))
    }
    #expect(Set(colors.map { "\($0)" }).count == count)
}

@Test(arguments: Support.builtInIDs)
func textBackingIsOpaqueAndMeetsTheFloorForEverySlot(skinID: String) throws {
    let count = select(skinID, paletteIndex: nil).paletteSlotCount
    for index in [nil] + (0..<count).map(Optional.some) {
        let result = select(skinID, paletteIndex: index)
        for (mode, theme) in [(AppearanceMode.light, result.light.theme), (.dark, result.dark.theme)] {
            let required = Contrast.requiredRatio(pointSize: theme.typography.effectiveSize, weight: theme.typography.weight)
            for page in AppearanceMode.allCases {
                let backing = theme.textBacking(page: page)
                #expect(backing.a == 1)
                let ratio = try Contrast.contrastRatio(foreground: theme.surface.text, background: backing)
                #expect(ratio >= required, "\(skinID) \(mode) slot \(String(describing: index)) on \(page)")
            }
        }
    }
}

@Test func textBackingFollowsTheSelectedSlot() throws {
    let plain = select("webby.clear", paletteIndex: nil).light.theme
    let tinted = select("webby.clear", paletteIndex: 1).light.theme
    #expect(plain.textBacking(page: .light) == plain.surface.contrastBacking.overWhite)
    let color = try #require(tinted.selectedPaletteColor)
    #expect(tinted.textBacking(page: .light) == color.composited(over: tinted.surface.contrastBacking.overWhite))
    #expect(tinted.textBacking(page: .dark) == color.composited(over: tinted.surface.contrastBacking.overBlack))
}

@Test func anIndexPastAShrunkenPaletteResolvesToTheFirstSlot() throws {
    let theme = select("webby.mono", paletteIndex: 99).light.theme
    #expect(theme.selectedIndex == 0)
    #expect(theme.selectedPaletteColor == theme.palette.first)
}
