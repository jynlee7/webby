import Foundation

/// Runs `action` once changes have been quiet for `delay` (500 ms for notes).
///
/// Each `schedule()` restarts the quiet period, so a burst of typing saves once.
/// `fireNow()` runs a pending save at once, for blur and Done; `cancel()` drops it
/// when the quit path takes over. The sleep is injected, so tests never wait.
@MainActor
public final class AutosaveDebouncer {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public let delay: Duration
    /// True between a `schedule()` and the action running or being cancelled.
    public private(set) var isPending = false

    private let sleep: Sleep
    private let action: @MainActor () -> Void
    private var task: Task<Void, Never>?
    private var token: UInt64 = 0

    public init(
        delay: Duration = .milliseconds(500),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        action: @escaping @MainActor () -> Void
    ) {
        self.delay = delay
        self.sleep = sleep
        self.action = action
    }

    /// Starts or restarts the quiet period.
    public func schedule() {
        token &+= 1
        let scheduled = token
        task?.cancel()
        isPending = true
        task = Task { [weak self, sleep, delay] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            self?.fire(ifCurrent: scheduled)
        }
    }

    /// Runs a pending action immediately. Does nothing when nothing is pending.
    public func fireNow() {
        guard isPending else { return }
        stop()
        action()
    }

    /// Drops a pending action without running it.
    public func cancel() {
        stop()
    }

    private func fire(ifCurrent scheduled: UInt64) {
        guard isPending, token == scheduled else { return }
        stop()
        action()
    }

    private func stop() {
        token &+= 1
        task?.cancel()
        task = nil
        isPending = false
    }
}

/// How long to wait before retrying a failed save: 1 s, doubling up to 30 s.
public enum SaveRetryBackoff {
    public static let first: Duration = .seconds(1)
    public static let longest: Duration = .seconds(30)

    /// The delay after `failures` consecutive failures (1 or more).
    public static func delay(afterFailures failures: Int) -> Duration {
        guard failures > 1 else { return first }
        let doublings = min(failures - 1, 5)
        return min(first * (1 << doublings), longest)
    }
}
