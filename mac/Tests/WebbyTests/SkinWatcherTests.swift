import Foundation
import Testing
@testable import Webby

@MainActor
@Suite struct SkinWatcherTests {
    /// FSEvents calls back on a private queue. This used to trap on the main-actor
    /// isolation check as soon as the first file changed.
    @Test func aFileChangeReachesTheMainActorWithoutTrapping() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webby-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var fired = 0
        let watcher = SkinWatcher(root: root) { fired += 1 }
        watcher.startIfPossible()
        #expect(watcher.isWatching)
        try await Task.sleep(for: .milliseconds(300))
        try Data("x".utf8).write(to: root.appendingPathComponent("a.txt"))
        try await Task.sleep(for: .seconds(1.5))
        watcher.stop()
        #expect(fired > 0)
    }
}
