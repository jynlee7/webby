import Foundation
import Testing
@testable import WebbyCore

/// A clock that only moves when a test advances it. Cancelled sleepers wake with
/// `CancellationError`, as `Task.sleep` does.
private final class ManualClock: @unchecked Sendable {
    private struct Sleeper {
        let id: UInt64
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var now: Duration = .zero
    private var nextID: UInt64 = 0
    private var sleepers: [Sleeper] = []

    var pendingSleepers: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }

    func sleep(_ duration: Duration) async throws {
        let (id, deadline) = reserve(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                park(Sleeper(id: id, deadline: deadline, continuation: continuation))
            }
        } onCancel: {
            self.wake(id: id, with: .failure(CancellationError()))
        }
    }

    private func reserve(_ duration: Duration) -> (UInt64, Duration) {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        return (nextID, now + duration)
    }

    /// Checking cancellation under the lock closes the race with `onCancel`.
    private func park(_ sleeper: Sleeper) {
        lock.lock()
        if Task.isCancelled {
            lock.unlock()
            sleeper.continuation.resume(throwing: CancellationError())
        } else {
            sleepers.append(sleeper)
            lock.unlock()
        }
    }

    func advance(by duration: Duration) {
        lock.lock()
        now += duration
        let due = sleepers.filter { $0.deadline <= now }
        sleepers.removeAll { $0.deadline <= now }
        lock.unlock()
        for sleeper in due { sleeper.continuation.resume() }
    }

    private func wake(id: UInt64, with result: Result<Void, any Error>) {
        lock.lock()
        let index = sleepers.firstIndex { $0.id == id }
        let sleeper = index.map { sleepers.remove(at: $0) }
        lock.unlock()
        sleeper?.continuation.resume(with: result)
    }
}

@MainActor
private final class Counter {
    var count = 0
}

/// Yields until `condition` holds or the attempt budget runs out.
@MainActor
private func settle(_ condition: () -> Bool) async {
    for _ in 0..<1_000 where !condition() {
        await Task.yield()
    }
}

@MainActor @Suite struct AutosaveDebouncerTests {
    private let clock = ManualClock()
    private let saves = Counter()

    private func makeDebouncer() -> AutosaveDebouncer {
        let clock = clock
        let saves = saves
        return AutosaveDebouncer(sleep: { try await clock.sleep($0) }, action: { saves.count += 1 })
    }

    /// Schedules and waits until the debouncer's task is parked on the clock.
    private func schedule(_ debouncer: AutosaveDebouncer) async {
        debouncer.schedule()
        await settle { clock.pendingSleepers == 1 }
        #expect(clock.pendingSleepers == 1)
    }

    @Test func savesOnlyAfterHalfASecondOfQuiet() async {
        let debouncer = makeDebouncer()
        await schedule(debouncer)

        clock.advance(by: .milliseconds(499))
        await settle { saves.count > 0 }
        #expect(saves.count == 0)
        #expect(debouncer.isPending)

        clock.advance(by: .milliseconds(1))
        await settle { saves.count > 0 }
        #expect(saves.count == 1)
        #expect(!debouncer.isPending)
    }

    @Test func aBurstOfChangesSavesOnceAfterTheLastOne() async {
        let debouncer = makeDebouncer()
        await schedule(debouncer)
        clock.advance(by: .milliseconds(300))
        await schedule(debouncer)
        clock.advance(by: .milliseconds(300))
        await schedule(debouncer)

        clock.advance(by: .milliseconds(499))
        await settle { saves.count > 0 }
        #expect(saves.count == 0)

        clock.advance(by: .milliseconds(1))
        await settle { saves.count > 0 }
        #expect(saves.count == 1)
    }

    @Test func fireNowSavesImmediatelyAndOnlyOnce() async {
        let debouncer = makeDebouncer()
        await schedule(debouncer)

        debouncer.fireNow()
        #expect(saves.count == 1)
        #expect(!debouncer.isPending)

        clock.advance(by: .seconds(1))
        await settle { saves.count > 1 }
        #expect(saves.count == 1)
    }

    @Test func fireNowWithNothingPendingDoesNothing() {
        let debouncer = makeDebouncer()
        debouncer.fireNow()
        #expect(saves.count == 0)
    }

    @Test func cancelDropsThePendingSave() async {
        let debouncer = makeDebouncer()
        await schedule(debouncer)

        debouncer.cancel()
        clock.advance(by: .seconds(1))
        await settle { saves.count > 0 }
        #expect(saves.count == 0)
        #expect(!debouncer.isPending)
    }

    @Test func aSaveAfterTheFirstStartsANewQuietPeriod() async {
        let debouncer = makeDebouncer()
        await schedule(debouncer)
        clock.advance(by: .milliseconds(500))
        await settle { saves.count == 1 }

        await schedule(debouncer)
        clock.advance(by: .milliseconds(499))
        await settle { saves.count > 1 }
        #expect(saves.count == 1)
        clock.advance(by: .milliseconds(1))
        await settle { saves.count > 1 }
        #expect(saves.count == 2)
    }

    @Test func retryBackoffDoublesUpToThirtySeconds() {
        let delays = (1...8).map { SaveRetryBackoff.delay(afterFailures: $0) }
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16),
                           .seconds(30), .seconds(30), .seconds(30)])
        #expect(SaveRetryBackoff.delay(afterFailures: 0) == .seconds(1))
    }
}
