import Foundation
import Testing
@testable import Webby

@MainActor
@Suite struct SkinExportReplaceTests {
    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("webby-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func replacesAnExistingExportAfterTheUserConfirmed() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("skin.webbyskin")
        try Data("old".utf8).write(to: destination)

        try SkinStore.write(replacing: destination) { temporary in
            #expect(!FileManager.default.fileExists(atPath: temporary.path))
            try Data("new".utf8).write(to: temporary, options: .withoutOverwriting)
        }

        #expect(try Data(contentsOf: destination) == Data("new".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["skin.webbyskin"])
    }

    @Test func writesANewExport() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("skin.webbyskin")

        try SkinStore.write(replacing: destination) { try Data("new".utf8).write(to: $0) }

        #expect(try Data(contentsOf: destination) == Data("new".utf8))
    }

    @Test func keepsTheOldExportWhenWritingFails() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("skin.webbyskin")
        try Data("old".utf8).write(to: destination)
        struct Failure: Error {}

        #expect(throws: Failure.self) {
            try SkinStore.write(replacing: destination) { _ in throw Failure() }
        }
        #expect(try Data(contentsOf: destination) == Data("old".utf8))
    }
}
