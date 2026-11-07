import Foundation
import Testing
@testable import WebbyCore

private typealias Support = SkinLibraryTestSupport

private struct SelectionFixture {
    let temp: URL
    let selection: SkinSelection
    let decorated: InstalledSkin

    init() throws {
        temp = try Support.makeTempDirectory()
        let folder = try Support.decoratedSkinFolder(id: "com.example.stamp", in: temp)
        decorated = try #require(Support.installedSkin(folder: folder, origin: .installed).skin)
        selection = SkinSelection(
            skins: Support.builtInSkins() + [decorated],
            availableBaseIDs: Set(Support.builtInIDs)
        )
    }
}

@Test func fixtureDecoratedSkinIsAccepted() throws {
    let fixture = try SelectionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.temp) }
    #expect(fixture.decorated.isAccepted)
}

@Test func workspaceSkinWinsOverGlobal() throws {
    let fixture = try SelectionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.temp) }
    let result = fixture.selection.select(workspaceSkinID: "webby.mono", globalSkinID: "com.example.stamp")
    #expect(result.effectiveSkinID == "webby.mono")
    #expect(result.light.theme.skinID == "webby.mono")
    #expect(result.dark.theme.skinID == "webby.mono")
    #expect(result.resolution(for: .dark) == result.dark)
}

@Test func missingOrRejectedWorkspaceSkinFallsBackToGlobal() throws {
    let fixture = try SelectionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.temp) }
    let missing = fixture.selection.select(workspaceSkinID: "com.example.gone", globalSkinID: "webby.mono")
    #expect(missing.effectiveSkinID == "webby.mono")

    let rejected = InstalledSkin(
        id: "com.example.bad",
        manifest: fixture.decorated.manifest,
        groups: fixture.decorated.groups,
        availableImagePaths: nil,
        isAccepted: false
    )
    let selection = SkinSelection(
        skins: Support.builtInSkins() + [rejected],
        availableBaseIDs: Set(Support.builtInIDs)
    )
    let result = selection.select(workspaceSkinID: "com.example.bad", globalSkinID: "webby.mono")
    #expect(result.effectiveSkinID == "webby.mono")
}

@Test func missingGlobalFallsBackToClear() throws {
    let fixture = try SelectionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.temp) }
    #expect(fixture.selection.select(workspaceSkinID: nil, globalSkinID: nil).effectiveSkinID == "webby.clear")
    #expect(fixture.selection.select(workspaceSkinID: nil, globalSkinID: "com.example.gone").effectiveSkinID == "webby.clear")
}

@Test func paletteSlotAppliesAndCountIsReported() throws {
    let fixture = try SelectionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.temp) }
    let plain = fixture.selection.select(workspaceSkinID: nil, globalSkinID: "webby.mono")
    #expect(plain.paletteSlotCount == 6)
    #expect(plain.light.theme.selectedIndex == nil)

    let picked = fixture.selection.select(
        workspaceSkinID: nil,
        globalSkinID: "webby.mono",
        noteAppearance: NoteAppearance(paletteIndex: 3)
    )
    #expect(picked.light.theme.selectedIndex == 3)
    #expect(picked.dark.theme.selectedIndex == 3)
}

@Test func hideDecorationHidesItAndHasDecorationReflectsSkin() throws {
    let fixture = try SelectionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.temp) }
    let shown = fixture.selection.select(workspaceSkinID: "com.example.stamp", globalSkinID: nil)
    #expect(shown.hasDecoration)
    #expect(shown.light.theme.decoration.hidden == false)

    let hidden = fixture.selection.select(
        workspaceSkinID: "com.example.stamp",
        globalSkinID: nil,
        noteAppearance: NoteAppearance(hideDecoration: true)
    )
    #expect(hidden.light.theme.decoration.hidden)
    #expect(hidden.hasDecoration)

    let mono = fixture.selection.select(workspaceSkinID: "webby.mono", globalSkinID: nil)
    #expect(!mono.hasDecoration)
}

@Test func increaseContrastGivesOpaqueFillAndBorderForBuiltInsAndFixture() throws {
    let fixture = try SelectionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.temp) }
    for id in ["webby.clear", "webby.mono", "com.example.stamp"] {
        let result = fixture.selection.select(
            workspaceSkinID: id,
            globalSkinID: nil,
            accessibility: AccessibilitySettings(increaseContrast: true)
        )
        for resolution in [result.light, result.dark] {
            #expect(resolution.theme.surface.fill.a == 1, "\(id)")
            #expect(resolution.theme.surface.border.width > 0, "\(id)")
        }
    }
}
