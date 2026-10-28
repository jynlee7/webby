import Foundation

/// How the app should answer `applicationShouldTerminate(_:)`.
public struct TerminationPlan: Sendable, Equatable {
    /// The caller must return `.terminateLater` and reply after the flush.
    public let shouldWait: Bool
    /// The caller must call `reply(toApplicationShouldTerminate:)` itself.
    public let replyAfterFlush: Bool

    public init(shouldWait: Bool, replyAfterFlush: Bool) {
        self.shouldWait = shouldWait
        self.replyAfterFlush = replyAfterFlush
    }

    /// Nothing needs to be written, so macOS may terminate immediately.
    public static let terminateNow = TerminationPlan(shouldWait: false, replyAfterFlush: false)

    /// The caller must wait for `handleTermination()` and then reply.
    public static let waitForFlush = TerminationPlan(shouldWait: true, replyAfterFlush: true)
}

/// A comparable description of a save error.
///
/// `QuitOutcome` carries this instead of an unconstrained `any Error` so the
/// outcome stays `Sendable` and `Equatable` without an unsafe cast.
public struct QuitFailure: Sendable, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ error: any Error) {
        let localized = (error as? LocalizedError)?.errorDescription
        self.description = localized ?? String(describing: error)
    }

    public init(description: String) {
        self.description = description
    }
}

public enum QuitOutcome: Sendable, Equatable {
    /// There was nothing to write, or the file is read-only.
    case nothingToSave
    case flushed(generation: UInt64)
    case fallback(generation: UInt64)
    case failed(QuitFailure)
}

/// Answers macOS termination deterministically and independently of AppKit.
///
/// The coordinator races the ordered `DiskWriter` flush against a deadline, then
/// falls back to a synchronous save through the same `SaveGate` on the calling
/// thread. It also keeps sudden termination disabled only while there are
/// unsaved changes. All time is injected, so tests never sleep.
public final class QuitFlushCoordinator {
    public typealias Now = @Sendable () -> Duration
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    fileprivate enum FlushEvent: Sendable {
        case flushed(UInt64)
        case failed(QuitFailure)
        case cancelled
        case timedOut
    }

    private struct CachedResult {
        let outcome: QuitOutcome
        let terminate: Bool
    }

    private let timeout: Duration
    private let now: Now
    private let sleep: Sleep
    private let flush: @Sendable () async throws -> UInt64
    private let fallback: @Sendable () throws -> UInt64
    private let isReadOnly: @Sendable () -> Bool
    private let hasUnsavedChanges: @Sendable () -> Bool
    private let suddenTermination: @Sendable (Bool) -> Void
    private let onOutcome: (@Sendable (QuitOutcome) -> Void)?

    private let stateLock = NSLock()
    private var newestMutationGeneration: UInt64 = 0
    private var committedGeneration: UInt64 = 0
    private var trackedDirty = false
    private var lastResult: CachedResult?
    private var suddenTerminationDisabled = false

    /// Creates a coordinator. All inputs are closures so the caller can use the
    /// same `SaveGate` for both the flush and the synchronous fallback.
    ///
    /// - Parameters:
    ///   - timeout: How long to wait for `flush` before using `fallback`.
    ///   - now: Injected clock reading. Tests use a fixed value.
    ///   - sleep: Injected waiting primitive. Tests replace it with a gate.
    ///   - flush: Awaits the ordered writer and returns its committed generation.
    ///   - fallback: Saves synchronously through the same `SaveGate` and returns
    ///     the committed generation.
    ///   - isReadOnly: True when the backing file must not be written.
    ///   - hasUnsavedChanges: The store's own dirtiness, if it tracks it.
    ///   - suddenTermination: Receives `true` when sudden termination must be
    ///     disabled and `false` when it must be re-enabled.
    ///   - onOutcome: Called once for the outcome that resolves termination.
    public init(
        timeout: Duration = .seconds(3),
        now: @escaping Now = {
            .seconds(Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000)
        },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        flush: @escaping @Sendable () async throws -> UInt64,
        fallback: @escaping @Sendable () throws -> UInt64,
        isReadOnly: @escaping @Sendable () -> Bool,
        hasUnsavedChanges: @escaping @Sendable () -> Bool,
        suddenTermination: @escaping @Sendable (Bool) -> Void = { _ in },
        onOutcome: (@Sendable (QuitOutcome) -> Void)? = nil
    ) {
        self.timeout = timeout
        self.now = now
        self.sleep = sleep
        self.flush = flush
        self.fallback = fallback
        self.isReadOnly = isReadOnly
        self.hasUnsavedChanges = hasUnsavedChanges
        self.suddenTermination = suddenTermination
        self.onOutcome = onOutcome
        refreshSuddenTermination()
    }

    /// True while a mutation has not reached the committed generation.
    public var hasPendingChanges: Bool {
        currentIsDirty
    }

    /// Returns the termination plan without doing any I/O.
    public func plan() -> TerminationPlan {
        if isReadOnly() {
            return .terminateNow
        }
        return currentIsDirty ? .waitForFlush : .terminateNow
    }

    /// Resolves the current state. Returns true when the app may terminate.
    ///
    /// Sequential calls after a resolved result reuse that result, so a second
    /// call cannot run the fallback twice unless a new mutation arrives.
    public func handleTermination() async -> Bool {
        if let cached = cachedResult() {
            return cached.terminate
        }

        guard plan().shouldWait else {
            finish(.nothingToSave, terminate: true)
            return true
        }

        // A mutation can arrive while the flush is suspended. Loop so the newest
        // generation is written before termination is allowed, bounded so a writer
        // that keeps falling behind cannot hang the quit path forever. The deadline is
        // shared across attempts so retries cannot multiply the wait.
        let started = now()
        for attempt in 0..<3 {
            let remaining = timeout - (now() - started)
            guard remaining > .zero else { return runFallbackChecked() }
            let event = await raceFlushAgainstTimeout(limit: remaining)
            switch event {
            case .flushed(let generation):
                noteCommitted(generation: generation)
                guard currentIsDirty else {
                    finish(.flushed(generation: generation), terminate: true)
                    return true
                }
                if attempt == 2 { break }
            case .failed, .cancelled, .timedOut:
                // A failed flush is not retried here; the fallback decides.
                return runFallbackChecked()
            }
        }

        return runFallbackChecked()
    }

    /// Applies the same post-write dirtiness check to the synchronous fallback.
    private func runFallbackChecked() -> Bool {
        let generation: UInt64
        do {
            generation = try fallback()
        } catch {
            finish(.failed(QuitFailure(error)), terminate: false)
            return false
        }

        noteCommitted(generation: generation)
        // Decide before publishing, so listeners never see success followed by failure.
        guard !currentIsDirty else {
            finish(.failed(QuitFailure(description: "The newest changes could not be saved.")), terminate: false)
            return false
        }
        finish(.fallback(generation: generation), terminate: true)
        return true
    }

    /// Records a new mutation. A stale or repeated generation is ignored.
    public func noteMutation(generation: UInt64) {
        stateLock.lock()
        if generation > newestMutationGeneration {
            newestMutationGeneration = generation
            lastResult = nil
        }
        if newestMutationGeneration > committedGeneration {
            trackedDirty = true
        }
        stateLock.unlock()
        refreshSuddenTermination()
    }

    /// Records a committed generation. Dirty clears only when the commit reaches
    /// the newest mutation; a stale commit leaves dirty state untouched.
    public func noteCommitted(generation: UInt64) {
        stateLock.lock()
        let advanced = generation > committedGeneration
        if advanced {
            committedGeneration = generation
        }
        let wasDirty = trackedDirty
        let dirtyNow = newestMutationGeneration > committedGeneration
        trackedDirty = dirtyNow
        if advanced || wasDirty != dirtyNow {
            lastResult = nil
        }
        stateLock.unlock()
        refreshSuddenTermination()
    }

    private var currentIsDirty: Bool {
        stateLock.lock()
        let tracked = trackedDirty
        stateLock.unlock()
        return tracked || hasUnsavedChanges()
    }

    private func cachedResult() -> CachedResult? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastResult
    }

    private func finish(_ outcome: QuitOutcome, terminate: Bool) {
        stateLock.lock()
        lastResult = CachedResult(outcome: outcome, terminate: terminate)
        stateLock.unlock()
        onOutcome?(outcome)
    }

    private func runFallback() -> Bool {
        do {
            let generation = try fallback()
            noteCommitted(generation: generation)
            finish(.fallback(generation: generation), terminate: true)
            return true
        } catch {
            finish(.failed(QuitFailure(error)), terminate: false)
            return false
        }
    }

    private func raceFlushAgainstTimeout(limit: Duration) async -> FlushEvent {
        let box = FirstResultBox()

        let flushTask = Task { [flush] in
            do {
                let generation = try await flush()
                box.resolve(.flushed(generation))
            } catch is CancellationError {
                box.resolve(.cancelled)
            } catch {
                box.resolve(.failed(QuitFailure(error)))
            }
        }

        let timeoutTask = Task { [sleep, limit] in
            do {
                try await sleep(limit)
                box.resolve(.timedOut)
            } catch is CancellationError {
                // The flush resolved first; its result is already recorded.
            } catch {
                box.resolve(.timedOut)
            }
        }

        let event = await withTaskCancellationHandler {
            await box.wait()
        } onCancel: {
            box.resolve(.cancelled)
        }

        timeoutTask.cancel()
        switch event {
        case .flushed, .failed:
            break
        case .cancelled, .timedOut:
            flushTask.cancel()
        }
        return event
    }

    private func refreshSuddenTermination() {
        let shouldDisable = currentIsDirty && !isReadOnly()
        stateLock.lock()
        let changed = suddenTerminationDisabled != shouldDisable
        if changed {
            suddenTerminationDisabled = shouldDisable
        }
        stateLock.unlock()
        if changed {
            suddenTermination(shouldDisable)
        }
    }
}

/// Lets exactly one of the flush and timeout tasks publish the first result.
private final class FirstResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: QuitFlushCoordinator.FlushEvent?
    private var continuation: CheckedContinuation<QuitFlushCoordinator.FlushEvent, Never>?

    func resolve(_ event: QuitFlushCoordinator.FlushEvent) {
        lock.lock()
        guard value == nil else {
            lock.unlock()
            return
        }
        value = event
        let waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume(returning: event)
    }

    func wait() async -> QuitFlushCoordinator.FlushEvent {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let value {
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
