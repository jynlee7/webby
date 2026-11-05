import Foundation

/// Tracks archive staging that runs off the main actor, so app termination can wait
/// for it briefly and remove the folders the preview never received. Thread-safe.
final class SkinStagingTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let inFlight = DispatchGroup()
    private var quitting = false
    private var unclaimed: Set<URL> = []

    /// Call before staging starts; balance with `finish(root:)`.
    func begin() {
        inFlight.enter()
    }

    /// Records a staged folder, or nil when staging failed. Returns false, after
    /// removing the folder, when the app is quitting.
    func finish(root: URL?) -> Bool {
        defer { inFlight.leave() }
        lock.lock()
        let isQuitting = quitting
        if !isQuitting, let root { unclaimed.insert(root) }
        lock.unlock()
        if isQuitting, let root {
            try? FileManager.default.removeItem(at: root)
            return false
        }
        return true
    }

    /// The main actor received the folder, and the preview window now owns it.
    /// Returns false when the app is quitting; the caller then discards it.
    func claim(_ root: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !quitting else { return false }
        unclaimed.remove(root)
        return true
    }

    /// For app termination: stops handing folders over, waits up to `timeout` for
    /// staging in progress, and removes every staged folder no preview received.
    /// Returns whether all staging finished in time.
    @discardableResult
    func discardUnclaimed(waitingUpTo timeout: TimeInterval) -> Bool {
        lock.lock()
        quitting = true
        lock.unlock()
        let finished = inFlight.wait(timeout: .now() + timeout) == .success
        lock.lock()
        let roots = unclaimed
        unclaimed.removeAll()
        lock.unlock()
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        return finished
    }
}
