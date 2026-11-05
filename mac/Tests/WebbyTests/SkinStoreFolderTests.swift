import Foundation
import Testing
import WebbyCore
@testable import Webby

@MainActor
@Suite struct SkinStoreFolderTests {
    @Test func launchCreatesTheSkinsFolderSoLaterSkinsAreWatched() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webby-skins-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let skins = root.appendingPathComponent("Skins", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: skins.path))

        let store = SkinStore(
            userRoot: skins,
            builtInDirectory: nil,
            settings: SettingsStore(fileURL: root.appendingPathComponent("settings.json")),
            noteStore: NoteStore(fileURL: root.appendingPathComponent("notes.json"))
        )
        defer { store.stop() }

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: skins.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}
