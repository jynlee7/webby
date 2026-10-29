import Foundation
import Testing
@testable import WebbyCore

private typealias Support = SkinLibraryTestSupport

@Test func installMovesStagedFolderAndListsIt() throws {
    let temp = try Support.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let library = SkinLibraryFolder(root: temp.appendingPathComponent("Skins"))
    let staged = try Support.stagedCopy(of: "webby.mono", id: "com.example.paper", in: temp)

    let installed = try library.install(stagedFolder: staged, id: "com.example.paper")

    #expect(installed == library.folder(for: "com.example.paper"))
    #expect(!FileManager.default.fileExists(atPath: staged.path))
    #expect(library.installed().map(\.id) == ["com.example.paper"])
    let loaded = SkinFolderLoader.load(folder: installed, origin: .installed, availableBaseIDs: Set(Support.builtInIDs))
    #expect(loaded.isAccepted)
}

@Test func installReplacesExistingSkinWithSameID() throws {
    let temp = try Support.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let library = SkinLibraryFolder(root: temp.appendingPathComponent("Skins"))
    try library.install(stagedFolder: Support.stagedCopy(of: "webby.mono", id: "com.example.paper", in: temp), id: "com.example.paper")

    let second = try Support.stagedCopy(of: "webby.mono", id: "com.example.paper", in: temp)
    try Support.rewriteManifest(in: second) { $0["name"] = "Second" }
    try library.install(stagedFolder: second, id: "com.example.paper")

    let manifest = try Data(contentsOf: library.folder(for: "com.example.paper").appendingPathComponent("skin.json"))
    let object = try JSONSerialization.jsonObject(with: manifest) as? [String: Any]
    #expect(object?["name"] as? String == "Second")
    #expect(library.installed().count == 1)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: library.root.path)
    #expect(leftovers == ["com.example.paper"])
}

@Test func installRefusesReservedAndMalformedIDs() throws {
    let temp = try Support.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let library = SkinLibraryFolder(root: temp.appendingPathComponent("Skins"))
    let staged = try Support.stagedCopy(of: "webby.mono", id: "com.example.paper", in: temp)

    #expect(throws: SkinLibraryError.reservedID("webby.evil")) {
        try library.install(stagedFolder: staged, id: "webby.evil")
    }
    for bad in ["../escape", "a/b.c", "Upper.case", "single", ".hidden.id", ""] {
        #expect(throws: SkinLibraryError.invalidID(bad)) {
            try library.install(stagedFolder: staged, id: bad)
        }
    }
    #expect(throws: SkinLibraryError.idMismatch(expected: "com.example.other", found: "com.example.paper")) {
        try library.install(stagedFolder: staged, id: "com.example.other")
    }
    #expect(FileManager.default.fileExists(atPath: staged.path))
    #expect(!FileManager.default.fileExists(atPath: library.root.path))
}

@Test func duplicateBuiltInGetsUniqueIDsAndLoads() throws {
    let temp = try Support.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let library = SkinLibraryFolder(root: temp.appendingPathComponent("Skins"))
    let source = Support.builtInFolder("webby.mono")

    let first = try library.duplicate(folder: source)
    let second = try library.duplicate(folder: source)
    let third = try library.duplicate(folder: first.folder)

    #expect(first.id == "user.mono-copy")
    #expect(first.name == "Mono Copy")
    #expect(second.id == "user.mono-copy-2")
    #expect(second.name == "Mono Copy 2")
    #expect(third.id == "user.mono-copy-copy")
    #expect(Set(library.installed().map(\.id)) == [first.id, second.id, third.id])

    for copy in [first, second, third] {
        let loaded = SkinFolderLoader.load(folder: copy.folder, origin: .installed, availableBaseIDs: Set(Support.builtInIDs))
        #expect(loaded.isAccepted)
        #expect(loaded.manifest?.id == copy.id)
        #expect(loaded.manifest?.name == copy.name)
        #expect(loaded.manifest?.base == "webby.clear")
    }
    // The source is untouched and no scratch folder is left behind.
    #expect(try FileManager.default.contentsOfDirectory(atPath: library.root.path).allSatisfy { !$0.hasPrefix(".") })
}

@Test func duplicateAvoidsIDsTakenElsewhere() throws {
    let temp = try Support.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let library = SkinLibraryFolder(root: temp.appendingPathComponent("Skins"))
    let copy = try library.duplicate(
        folder: Support.builtInFolder("webby.mono"),
        avoiding: ["user.mono-copy"]
    )
    #expect(copy.id == "user.mono-copy-2")
}

@Test func removeDeletesOnlyTheNamedSkin() throws {
    let temp = try Support.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let library = SkinLibraryFolder(root: temp.appendingPathComponent("Skins"))
    let a = try library.duplicate(folder: Support.builtInFolder("webby.mono"))
    let b = try library.duplicate(folder: Support.builtInFolder("webby.clear"))
    try library.remove(id: a.id)
    #expect(library.installed().map(\.id) == [b.id])
    #expect(throws: SkinLibraryError.notFound(a.id)) { try library.remove(id: a.id) }
}
