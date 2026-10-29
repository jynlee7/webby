import Foundation
import Testing
@testable import WebbyCore

private typealias Support = SkinLibraryTestSupport

/// A sleep that returns only when the test advances it; cancelled sleeps throw.
private final class GateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UInt64: CheckedContinuation<Void, any Error>] = [:]
    private var next: UInt64 = 0
    private(set) var requestedDelays: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        let id: UInt64 = lock.withLock { next += 1; requestedDelays.append(duration); return next }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                waiters[id] = continuation
                lock.unlock()
                if Task.isCancelled { release(id, throwing: CancellationError()) }
            }
        } onCancel: {
            release(id, throwing: CancellationError())
        }
    }

    private func release(_ id: UInt64, throwing error: (any Error)? = nil) {
        let continuation = lock.withLock { waiters.removeValue(forKey: id) }
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }

    var pending: Int { lock.withLock { waiters.count } }

    /// Lets every parked sleep finish, as if the quiet period elapsed.
    func advance() {
        let ids = lock.withLock { Array(waiters.keys) }
        for id in ids { release(id) }
    }
}

@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
@Test func burstOfEventsReloadsOnceAfterQuietPeriod() async {
    let clock = GateClock()
    var reloads = 0
    let debouncer = SkinReload.makeDebouncer(sleep: { try await clock.sleep($0) }) { reloads += 1 }

    for _ in 0..<5 {
        debouncer.schedule()
        await settle()
    }
    #expect(reloads == 0)
    #expect(clock.pending == 1)

    clock.advance()
    await settle()
    #expect(reloads == 1)
    #expect(clock.requestedDelays.allSatisfy { $0 == .milliseconds(250) })
}

@MainActor
@Test func eventsAfterQuietPeriodReloadAgain() async {
    let clock = GateClock()
    var reloads = 0
    let debouncer = SkinReload.makeDebouncer(sleep: { try await clock.sleep($0) }) { reloads += 1 }

    debouncer.schedule()
    await settle()
    clock.advance()
    await settle()
    #expect(reloads == 1)

    debouncer.schedule()
    await settle()
    clock.advance()
    await settle()
    #expect(reloads == 2)
}

@Test func invalidJSONKeepsLastGoodSkin() throws {
    let temp = try Support.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let folder = try Support.stagedCopy(of: "webby.mono", id: "com.example.live", in: temp)

    let first = Support.installedSkin(folder: folder, origin: .installed)
    let good = try #require(first.skin)
    let accepted = SkinReload.keepLastGood(previous: nil, fresh: good, diagnostics: first.diagnostics)
    #expect(accepted.usedNewLoad)
    #expect(accepted.skin == good)

    try Data("{ not json".utf8).write(to: folder.appendingPathComponent("skin.json"))
    let broken = Support.installedSkin(folder: folder, origin: .installed)
    let kept = SkinReload.keepLastGood(previous: good, fresh: broken.skin, diagnostics: broken.diagnostics)
    #expect(!kept.usedNewLoad)
    #expect(kept.skin == good)
    #expect(kept.diagnostics.contains { $0.severity == .fatal })
}

@Test func acceptedEditReplacesPreviousSkin() throws {
    let temp = try Support.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let folder = try Support.stagedCopy(of: "webby.mono", id: "com.example.live", in: temp)
    let good = try #require(Support.installedSkin(folder: folder, origin: .installed).skin)

    try Support.rewriteManifest(in: folder) { $0["name"] = "Edited" }
    let edited = Support.installedSkin(folder: folder, origin: .installed)
    let outcome = SkinReload.keepLastGood(previous: good, fresh: edited.skin, diagnostics: edited.diagnostics)
    #expect(outcome.usedNewLoad)
    #expect(outcome.skin?.manifest.name == "Edited")
}
