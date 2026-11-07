import Foundation
import Testing
@testable import Webby

@Suite struct SkinStagingTrackerTests {
    private func makeStagedFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("webby-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func quitRemovesAFolderNoPreviewReceived() throws {
        let tracker = SkinStagingTracker()
        let root = try makeStagedFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        tracker.begin()
        #expect(tracker.finish(root: root))

        #expect(tracker.discardUnclaimed(waitingUpTo: 1))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(!tracker.claim(root))
    }

    @Test func quitLeavesAClaimedFolderToItsWindow() throws {
        let tracker = SkinStagingTracker()
        let root = try makeStagedFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        tracker.begin()
        #expect(tracker.finish(root: root))
        #expect(tracker.claim(root))

        tracker.discardUnclaimed(waitingUpTo: 1)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func quitWaitsForStagingInProgressAndRemovesItsFolder() throws {
        let tracker = SkinStagingTracker()
        let root = try makeStagedFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        tracker.begin()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            _ = tracker.finish(root: root)
        }

        #expect(tracker.discardUnclaimed(waitingUpTo: 5))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func stagingThatFinishesAfterQuitRemovesItsOwnFolder() throws {
        let tracker = SkinStagingTracker()
        let root = try makeStagedFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        tracker.begin()
        #expect(!tracker.discardUnclaimed(waitingUpTo: 0.05))

        #expect(!tracker.finish(root: root))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
