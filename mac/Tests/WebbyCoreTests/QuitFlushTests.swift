import Foundation
import Testing
@testable import WebbyCore

private struct TestSaveError: Error, LocalizedError, Equatable, Sendable {
    var errorDescription: String? { "test save failed" }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var flushCallCount = 0
    private var fallbackCallCount = 0
    private var recordedOutcomes: [QuitOutcome] = []
    private var recordedSuddenStates: [Bool] = []

    func recordFlush() {
        lock.lock()
        flushCallCount += 1
        lock.unlock()
    }

    func recordFallback() {
        lock.lock()
        fallbackCallCount += 1
        lock.unlock()
    }

    func recordOutcome(_ outcome: QuitOutcome) {
        lock.lock()
        recordedOutcomes.append(outcome)
        lock.unlock()
    }

    func recordSudden(_ disabled: Bool) {
        lock.lock()
        recordedSuddenStates.append(disabled)
        lock.unlock()
    }

    var flushCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return flushCallCount
    }

    var fallbackCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return fallbackCallCount
    }

    var outcomes: [QuitOutcome] {
        lock.lock()
        defer { lock.unlock() }
        return recordedOutcomes
    }

    var suddenStates: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSuddenStates
    }
}

/// A continuation that never resolves unless its task is cancelled.
private final class SuspendedGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var wasCancelled = false

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if wasCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        lock.lock()
        wasCancelled = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

private let hangingSleep: QuitFlushCoordinator.Sleep = { _ in
    try await SuspendedGate().wait()
}

private let immediateSleep: QuitFlushCoordinator.Sleep = { _ in }

@Test func cleanStateTerminatesWithoutFlushing() async {
    let recorder = Recorder()
    let coordinator = QuitFlushCoordinator(
        now: { .zero },
        sleep: hangingSleep,
        flush: {
            recorder.recordFlush()
            return 1
        },
        fallback: {
            recorder.recordFallback()
            return 1
        },
        isReadOnly: { false },
        hasUnsavedChanges: { false },
        onOutcome: { recorder.recordOutcome($0) }
    )

    #expect(coordinator.plan() == .terminateNow)
    #expect(await coordinator.handleTermination())
    #expect(recorder.flushCalls == 0)
    #expect(recorder.fallbackCalls == 0)
    #expect(recorder.outcomes == [.nothingToSave])
}

@Test func readOnlyTerminatesImmediatelyEvenWhenDirty() async {
    let recorder = Recorder()
    let coordinator = QuitFlushCoordinator(
        now: { .zero },
        sleep: hangingSleep,
        flush: {
            recorder.recordFlush()
            return 1
        },
        fallback: {
            recorder.recordFallback()
            return 1
        },
        isReadOnly: { true },
        hasUnsavedChanges: { true },
        onOutcome: { recorder.recordOutcome($0) }
    )
    coordinator.noteMutation(generation: 1)

    #expect(coordinator.plan() == .terminateNow)
    #expect(await coordinator.handleTermination())
    #expect(recorder.flushCalls == 0)
    #expect(recorder.fallbackCalls == 0)
    #expect(recorder.outcomes == [.nothingToSave])
}

@Test func flushSuccessTerminatesWithoutFallback() async {
    let recorder = Recorder()
    let coordinator = QuitFlushCoordinator(
        now: { .zero },
        sleep: hangingSleep,
        flush: {
            recorder.recordFlush()
            return 42
        },
        fallback: {
            recorder.recordFallback()
            return 0
        },
        isReadOnly: { false },
        hasUnsavedChanges: { false },
        onOutcome: { recorder.recordOutcome($0) }
    )
    coordinator.noteMutation(generation: 1)
    #expect(coordinator.hasPendingChanges)

    #expect(await coordinator.handleTermination())
    #expect(recorder.flushCalls == 1)
    #expect(recorder.fallbackCalls == 0)
    #expect(recorder.outcomes == [.flushed(generation: 42)])
    #expect(!coordinator.hasPendingChanges)
}

@Test func flushFailureFallsBackOnce() async {
    let recorder = Recorder()
    let coordinator = QuitFlushCoordinator(
        now: { .zero },
        sleep: hangingSleep,
        flush: {
            recorder.recordFlush()
            throw TestSaveError()
        },
        fallback: {
            recorder.recordFallback()
            return 9
        },
        isReadOnly: { false },
        hasUnsavedChanges: { false },
        onOutcome: { recorder.recordOutcome($0) }
    )
    coordinator.noteMutation(generation: 1)

    #expect(await coordinator.handleTermination())
    #expect(recorder.flushCalls == 1)
    #expect(recorder.fallbackCalls == 1)
    #expect(recorder.outcomes == [.fallback(generation: 9)])
    #expect(!coordinator.hasPendingChanges)
}

@Test func timeoutRunsSynchronousFallbackExactlyOnce() async {
    let recorder = Recorder()
    let gate = SuspendedGate()
    let coordinator = QuitFlushCoordinator(
        timeout: .milliseconds(10),
        now: { .zero },
        sleep: immediateSleep,
        flush: {
            recorder.recordFlush()
            try await gate.wait()
            return 1
        },
        fallback: {
            recorder.recordFallback()
            return 7
        },
        isReadOnly: { false },
        hasUnsavedChanges: { false },
        onOutcome: { recorder.recordOutcome($0) }
    )
    coordinator.noteMutation(generation: 1)

    #expect(await coordinator.handleTermination())
    #expect(recorder.fallbackCalls == 1)
    #expect(recorder.outcomes == [.fallback(generation: 7)])
}

@Test func timeoutFallbackFailureReportsFalse() async {
    let recorder = Recorder()
    let gate = SuspendedGate()
    let coordinator = QuitFlushCoordinator(
        timeout: .milliseconds(10),
        now: { .zero },
        sleep: immediateSleep,
        flush: {
            recorder.recordFlush()
            try await gate.wait()
            return 1
        },
        fallback: {
            recorder.recordFallback()
            throw TestSaveError()
        },
        isReadOnly: { false },
        hasUnsavedChanges: { false },
        onOutcome: { recorder.recordOutcome($0) }
    )
    coordinator.noteMutation(generation: 1)

    #expect(await coordinator.handleTermination() == false)
    #expect(recorder.fallbackCalls == 1)
    #expect(recorder.outcomes == [.failed(QuitFailure(TestSaveError()))])
}

@Test func flushCancellationIsNotSuccess() async {
    let recorder = Recorder()
    let coordinator = QuitFlushCoordinator(
        now: { .zero },
        sleep: hangingSleep,
        flush: {
            recorder.recordFlush()
            throw CancellationError()
        },
        fallback: {
            recorder.recordFallback()
            return 5
        },
        isReadOnly: { false },
        hasUnsavedChanges: { false },
        onOutcome: { recorder.recordOutcome($0) }
    )
    coordinator.noteMutation(generation: 1)

    #expect(await coordinator.handleTermination())
    #expect(recorder.fallbackCalls == 1)
    #expect(recorder.outcomes == [.fallback(generation: 5)])
}

@Test func doubleTerminationDoesNotFallbackTwice() async {
    let recorder = Recorder()
    let coordinator = QuitFlushCoordinator(
        now: { .zero },
        sleep: hangingSleep,
        flush: {
            recorder.recordFlush()
            throw TestSaveError()
        },
        fallback: {
            recorder.recordFallback()
            return 3
        },
        isReadOnly: { false },
        hasUnsavedChanges: { false },
        onOutcome: { recorder.recordOutcome($0) }
    )
    coordinator.noteMutation(generation: 1)

    #expect(await coordinator.handleTermination())
    #expect(await coordinator.handleTermination())
    #expect(recorder.fallbackCalls == 1)
    #expect(recorder.outcomes == [.fallback(generation: 3)])
}

@Test func staleCommitDoesNotClearDirty() {
    let coordinator = QuitFlushCoordinator(
        now: { .zero },
        sleep: hangingSleep,
        flush: { 1 },
        fallback: { 1 },
        isReadOnly: { false },
        hasUnsavedChanges: { false }
    )

    coordinator.noteMutation(generation: 5)
    #expect(coordinator.hasPendingChanges)

    coordinator.noteCommitted(generation: 4)
    #expect(coordinator.hasPendingChanges)

    coordinator.noteCommitted(generation: 5)
    #expect(!coordinator.hasPendingChanges)

    coordinator.noteMutation(generation: 6)
    coordinator.noteCommitted(generation: 7)
    #expect(!coordinator.hasPendingChanges)
}

@Test func suddenTerminationEdgesAreBalanced() {
    let recorder = Recorder()
    let coordinator = QuitFlushCoordinator(
        now: { .zero },
        sleep: hangingSleep,
        flush: { 1 },
        fallback: { 1 },
        isReadOnly: { false },
        hasUnsavedChanges: { false },
        suddenTermination: { recorder.recordSudden($0) }
    )

    #expect(recorder.suddenStates.isEmpty)

    coordinator.noteMutation(generation: 1)
    coordinator.noteMutation(generation: 2)
    #expect(recorder.suddenStates == [true])

    coordinator.noteCommitted(generation: 1)
    #expect(recorder.suddenStates == [true])

    coordinator.noteCommitted(generation: 2)
    #expect(recorder.suddenStates == [true, false])
}

private final class DurationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Duration.zero

    var elapsed: Duration {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ duration: Duration) {
        lock.lock()
        value += duration
        lock.unlock()
    }
}

private final class OutcomeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [QuitOutcome] = []

    func record(_ outcome: QuitOutcome) {
        lock.lock()
        recorded.append(outcome)
        lock.unlock()
    }

    var values: [QuitOutcome] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// Small thread-safe model of a store's dirty state for termination tests.
private final class QuitState: @unchecked Sendable {
    private let lock = NSLock()
    private var newestMutation: UInt64 = 0
    private var committed: UInt64 = 0

    func noteMutation(generation: UInt64) {
        lock.lock()
        newestMutation = max(newestMutation, generation)
        lock.unlock()
    }

    func noteCommitted(generation: UInt64) {
        lock.lock()
        committed = max(committed, generation)
        lock.unlock()
    }

    var isDirty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return newestMutation > committed
    }

    var newest: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return newestMutation
    }
}

@Test func newerEditDuringFlushBlocksTermination() async throws {
    let state = QuitState()
    state.noteMutation(generation: 1)
    let coordinator = QuitFlushCoordinator(
        sleep: { _ in try await Task.sleep(for: .seconds(30)) },
        flush: {
            // A newer edit lands while the flush is in flight.
            state.noteMutation(generation: 2)
            state.noteCommitted(generation: 1)
            return 1
        },
        fallback: {
            state.noteCommitted(generation: 2)
            return 2
        },
        isReadOnly: { false },
        hasUnsavedChanges: { state.isDirty }
    )

    let mayTerminate = await coordinator.handleTermination()
    #expect(mayTerminate)
    #expect(!state.isDirty)
}

@Test func unsavedEditAfterFailedFallbackCancelsTermination() async throws {
    let state = QuitState()
    state.noteMutation(generation: 2)
    let coordinator = QuitFlushCoordinator(
        flush: { throw SaveFailure.sourceChanged },
        fallback: { throw SaveFailure.sourceChanged },
        isReadOnly: { false },
        hasUnsavedChanges: { state.isDirty }
    )

    let mayTerminate = await coordinator.handleTermination()
    #expect(!mayTerminate)
    #expect(state.isDirty)
}

@Test func fallbackPublishesOneOutcomeWhenChangesRemain() async throws {
    let state = QuitState()
    state.noteMutation(generation: 2)
    let outcomes = OutcomeRecorder()
    let coordinator = QuitFlushCoordinator(
        flush: { throw SaveFailure.sourceChanged },
        fallback: {
            state.noteCommitted(generation: 1)
            return 1
        },
        isReadOnly: { false },
        hasUnsavedChanges: { state.isDirty },
        onOutcome: { outcomes.record($0) }
    )

    let mayTerminate = await coordinator.handleTermination()
    #expect(!mayTerminate)
    #expect(outcomes.values == [.failed(QuitFailure(description: "The newest changes could not be saved."))])
}

@Test func retriesShareOneTimeoutBudget() async throws {
    let state = QuitState()
    state.noteMutation(generation: 1)
    let clock = DurationClock()
    let outcomes = OutcomeRecorder()
    let coordinator = QuitFlushCoordinator(
        timeout: .seconds(3),
        now: { clock.elapsed },
        sleep: { duration in clock.advance(duration) },
        flush: {
            // Every attempt makes progress but leaves newer work behind.
            state.noteMutation(generation: state.newest + 1)
            state.noteCommitted(generation: state.newest - 1)
            return state.newest - 1
        },
        fallback: {
            state.noteCommitted(generation: state.newest)
            return state.newest
        },
        isReadOnly: { false },
        hasUnsavedChanges: { state.isDirty },
        onOutcome: { outcomes.record($0) }
    )

    let mayTerminate = await coordinator.handleTermination()
    #expect(mayTerminate)
    #expect(clock.elapsed <= .seconds(3))
}

/// The app awaits termination from its main actor, so the coordinator must cross actors.
@MainActor @Test func mainActorOwnerCanAwaitTermination() async {
    let recorder = Recorder()
    let coordinator = QuitFlushCoordinator(
        now: { .zero },
        sleep: hangingSleep,
        flush: {
            recorder.recordFlush()
            return 1
        },
        fallback: {
            recorder.recordFallback()
            return 1
        },
        isReadOnly: { false },
        hasUnsavedChanges: { false }
    )
    coordinator.noteMutation(generation: 1)

    let mayTerminate = await Task { @MainActor in await coordinator.handleTermination() }.value

    #expect(mayTerminate)
    #expect(recorder.flushCalls == 1)
    #expect(recorder.fallbackCalls == 0)
}
