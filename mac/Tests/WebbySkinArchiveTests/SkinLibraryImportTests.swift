import Foundation
import Testing
import WebbyCore
@testable import WebbySkinArchive

private let baseIDs: Set<String> = ["webby.clear", "webby.mono"]

private func repoSkin(_ id: String) -> URL {
    var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while url.path != "/" {
        let candidate = url.appendingPathComponent("mac/Resources/Skins/\(id)", isDirectory: true)
        if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("skin.json").path) {
            return candidate
        }
        url.deleteLastPathComponent()
    }
    return url
}

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbySkinLibraryImportTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func manifestData(id: String) throws -> Data {
    let source = try Data(contentsOf: repoSkin("webby.mono").appendingPathComponent("skin.json"))
    var object = try JSONSerialization.jsonObject(with: source) as! [String: Any]
    object["id"] = id
    object["name"] = id
    return try JSONSerialization.data(withJSONObject: object)
}

private func archive(id: String) throws -> Data {
    ZIPFixture.make(entries: [ZIPFixtureEntry(path: "skin.json", contents: Array(try manifestData(id: id)))])
}

/// Every entry under `directory`, relative, to prove nothing was written.
private func listing(_ directory: URL) -> [String] {
    (FileManager.default.enumerator(atPath: directory.path)?.allObjects as? [String]) ?? []
}

@Test func validArchiveStagesPreviewsAndInstalls() throws {
    let temp = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let file = temp.appendingPathComponent("paper.webbyskin")
    let data = try archive(id: "com.example.paper")
    try data.write(to: file)
    let staging = temp.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

    let preview = try SkinArchiveImporter.stage(archiveAt: file, stagingNear: staging, availableBaseIDs: baseIDs)

    #expect(preview.isAccepted)
    #expect(preview.manifest?.id == "com.example.paper")
    #expect(preview.payloadBytes > 0)
    #expect(preview.groups[.surface] != nil)
    #expect(!preview.diagnostics.contains { $0.severity == .fatal })

    let library = SkinLibraryFolder(root: temp.appendingPathComponent("Skins"))
    let installed = try library.install(stagedFolder: preview.root, id: "com.example.paper")
    try preview.discard()
    #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("skin.json").path))
    #expect(library.installed().map(\.id) == ["com.example.paper"])
}

@Test func archiveWithTraversalThrowsAndLeavesNoStagingBytes() throws {
    let temp = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let file = temp.appendingPathComponent("evil.webbyskin")
    try ZIPFixture.make(entries: [
        ZIPFixtureEntry(path: "skin.json", contents: Array(try manifestData(id: "com.example.evil"))),
        ZIPFixtureEntry(path: "../evil", contents: [1, 2, 3]),
    ]).write(to: file)
    let staging = temp.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let before = listing(temp).sorted()

    #expect(throws: SkinArchiveError.self) {
        try SkinArchiveImporter.stage(archiveAt: file, stagingNear: staging, availableBaseIDs: baseIDs)
    }

    #expect(listing(staging).isEmpty)
    #expect(listing(temp).sorted() == before)
    #expect(!FileManager.default.fileExists(atPath: temp.appendingPathComponent("evil").path))
}

@Test func oversizedArchiveIsRefusedBeforeReading() throws {
    let temp = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let file = temp.appendingPathComponent("big.webbyskin")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: UInt64(SkinArchiveLimits.archiveByteCount + 1))
    try handle.close()

    #expect(throws: SkinArchiveError.archiveTooLarge(
        actual: SkinArchiveLimits.archiveByteCount + 1,
        limit: SkinArchiveLimits.archiveByteCount
    )) {
        try SkinArchiveImporter.stage(archiveAt: file, stagingNear: temp, availableBaseIDs: baseIDs)
    }
}

@Test func catalogLoadsBuiltInsThenUserSkinsAndSkipsCollisions() throws {
    let temp = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let builtIns = temp.appendingPathComponent("BuiltIn", isDirectory: true)
    try FileManager.default.createDirectory(at: builtIns, withIntermediateDirectories: true)
    for id in ["webby.clear", "webby.mono"] {
        try FileManager.default.copyItem(at: repoSkin(id), to: builtIns.appendingPathComponent(id))
    }
    let library = SkinLibraryFolder(root: temp.appendingPathComponent("Skins"))
    let good = try library.duplicate(folder: repoSkin("webby.mono"))

    // A user folder that declares a built-in id (copied in by hand) and a folder whose
    // name disagrees with its manifest.
    let collide = library.folder(for: "com.example.collide")
    try FileManager.default.copyItem(at: repoSkin("webby.mono"), to: collide)
    let mismatch = library.folder(for: "com.example.mismatch")
    try FileManager.default.copyItem(at: library.folder(for: good.id), to: mismatch)

    let catalog = SkinCatalogLoader.load(builtInDirectory: builtIns, library: library)

    #expect(catalog.entries.map(\.skin.id) == ["webby.clear", "webby.mono", good.id])
    #expect(catalog.entries.map(\.origin) == [.builtIn, .builtIn, .installed])
    #expect(catalog.entries.allSatisfy { $0.skin.isAccepted })
    #expect(catalog.availableBaseIDs == baseIDs)
    #expect(catalog.entry(id: good.id)?.folder == library.folder(for: good.id))
    #expect(catalog.skipped.count == 2)
    #expect(catalog.skipped.allSatisfy { $0.diagnostics.contains { $0.severity == .fatal } })

    let selection = catalog.selection.select(workspaceSkinID: good.id, globalSkinID: nil)
    #expect(selection.effectiveSkinID == good.id)
}

@Test func catalogWithoutBuiltInsStillLoadsUserSkinsAndRejectsReservedIDs() throws {
    let temp = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let library = SkinLibraryFolder(root: temp.appendingPathComponent("Skins"))
    // A user skin may not use the webby. prefix; here a hand-placed folder is the only way in.
    try FileManager.default.createDirectory(at: library.root, withIntermediateDirectories: true)
    let reserved = library.folder(for: "webby.sneaky")
    try FileManager.default.copyItem(at: repoSkin("webby.mono"), to: reserved)
    try JSONSerialization.data(withJSONObject: [
        "formatVersion": 1, "id": "webby.sneaky", "name": "x", "author": "a", "version": "1.0.0",
    ]).write(to: reserved.appendingPathComponent("skin.json"))

    let catalog = SkinCatalogLoader.load(builtInDirectory: nil, library: library)
    #expect(catalog.entries.allSatisfy { $0.skin.id != "webby.sneaky" || !$0.skin.isAccepted })
}
