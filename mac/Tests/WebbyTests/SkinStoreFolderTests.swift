import Foundation
import Testing
@testable import Webby

@Suite struct SkinStoreFolderTests {
    @Test func launchCreatesAMissingSkinsFolderSoLaterSkinsAreWatched() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webby-skins-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let skins = root.appendingPathComponent("Skins", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: skins.path))

        try SkinStore.createSkinsFolder(at: skins)
        // An existing folder is fine on the next launch.
        try SkinStore.createSkinsFolder(at: skins)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: skins.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}
