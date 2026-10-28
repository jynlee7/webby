import Foundation

/// Serializes background saves for one file without blocking the caller.
///
/// Every snapshot travels through one long-lived `AsyncStream` consumed by a single
/// task, so writes reach `SaveGate` in order. The stream keeps only the newest
/// buffered snapshot, so a burst of edits produces one write of the final state
/// instead of one write per edit. `SaveGate.commit` remains the only write path and
/// rejects a generation that is not newer than the committed one.
///
/// The consumer task is not actor-isolated: it performs the synchronous commit off
/// the actor's executor, so `enqueue` stays available while a write is in flight.
public actor DiskWriter<Content: Codable & Sendable> {
    public typealias Snapshot = SaveGate<Content>.Snapshot
    public typealias Acknowledgement = SaveGate<Content>.Acknowledgement

    private struct Waiter {
        let target: UInt64
        let watermark: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let gate: SaveGate<Content>
    private let streamContinuation: AsyncStream<Snapshot>.Continuation

    /// Newest generation submitted through `enqueue` or `flush(_:)`.
    private var newestSubmittedGeneration: UInt64 = 0
    /// Newest generation the consumer has finished with, successfully or not.
    private var newestHandledGeneration: UInt64 = 0
    /// Newest submitted snapshot that has not been acknowledged yet.
    private var pendingSnapshot: Snapshot?
    /// Snapshot whose commit failed and has not been retried yet.
    private var failedSnapshot: Snapshot?
    /// Generation currently being committed; used to avoid queueing a duplicate.
    private var inFlightGeneration: UInt64?
    private var acknowledgement: Acknowledgement?
    /// False until a commit has actually completed, so generation 0 is not mistaken
    /// for an already-finished write.
    private var hasAcknowledged = false
    private var waiters: [Waiter] = []

    public init(
        gate: SaveGate<Content>,
        onFailure: @escaping @Sendable (any Error) -> Void = { _ in }
    ) {
        self.init(gate: gate, onFailure: onFailure, commit: { try await gate.commitAsync($0) })
    }

    /// Test seam: same signature as `SaveGate.commit`, so tests can observe and
    /// gate individual writes without changing the gate's behavior.
    init(
        gate: SaveGate<Content>,
        onFailure: @escaping @Sendable (any Error) -> Void = { _ in },
        commit: @escaping @Sendable (Snapshot) async throws -> Acknowledgement
    ) {
        self.gate = gate

        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.streamContinuation = continuation

        // The initializer is nonisolated, so this task runs off the actor's executor
        // and a synchronous commit cannot block `enqueue`. It holds the actor only
        // weakly between writes, so `deinit` can finish the stream.
        _ = Task { [weak self] in
            for await snapshot in stream {
                guard let self else { return }
                await self.beginCommit(snapshot.generation)
                do {
                    let ack = try await commit(snapshot)
                    await self.recordSuccess(ack, handled: snapshot.generation)
                } catch {
                    let surfaced = Self.surface(error)
                    onFailure(surfaced)
                    await self.recordFailure(surfaced, snapshot: snapshot)
                }
            }
        }
    }

    deinit {
        streamContinuation.finish()
    }

    /// Queues `snapshot` without waiting for the write. Older snapshots that are
    /// still pending are superseded, so only the newest state is written.
    public func enqueue(_ snapshot: Snapshot) {
        submit(snapshot)
    }

    /// Waits until everything submitted or already committed when this call runs is
    /// on disk. A newer enqueue that arrives during the wait does not extend it.
    public func flush() async throws {
        let target = max(newestSubmittedGeneration, gate.generation)
        try await waitUntilCommitted(target: target, watermark: newestSubmittedGeneration)
    }

    /// Submits `snapshot` and waits for its generation to reach the disk. Quit uses
    /// this to make the final in-memory state durable.
    public func flush(_ snapshot: Snapshot) async throws {
        submit(snapshot)
        try await waitUntilCommitted(target: snapshot.generation, watermark: snapshot.generation)
    }

    public var lastAcknowledgement: Acknowledgement? {
        acknowledgement
    }

    // Internal test accessor: lets a test wait until a flush has registered its
    // barrier before it changes the newest submitted generation.
    var pendingWaiterCount: Int {
        waiters.count
    }

    private func submit(_ snapshot: Snapshot) {
        // A genuinely older snapshot can never win, so do not queue it over a newer
        // pending one. Equal generations are allowed so a failed write can be retried.
        if let pending = pendingSnapshot, snapshot.generation < pending.generation {
            return
        }
        if let failed = failedSnapshot, snapshot.generation >= failed.generation {
            failedSnapshot = nil
        }
        pendingSnapshot = snapshot
        newestSubmittedGeneration = max(newestSubmittedGeneration, snapshot.generation)
        streamContinuation.yield(snapshot)
    }

    private func waitUntilCommitted(target: UInt64, watermark: UInt64) async throws {
        if isSatisfied(target: target, watermark: watermark) {
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            waiters.append(Waiter(target: target, watermark: watermark, continuation: continuation))

            // A failed write stays pending but is no longer in the stream, so a later
            // flush retries it once. The in-flight check avoids queueing a duplicate.
            if let failed = failedSnapshot,
               failed.generation > committedGeneration,
               failed.generation == pendingSnapshot?.generation,
               failed.generation != inFlightGeneration {
                failedSnapshot = nil
                streamContinuation.yield(failed)
            }
        }
    }

    private func isSatisfied(target: UInt64, watermark: UInt64) -> Bool {
        hasAcknowledged && committedGeneration >= target && newestHandledGeneration >= watermark
    }

    private var committedGeneration: UInt64 {
        max(acknowledgement?.generation ?? 0, gate.generation)
    }

    private func beginCommit(_ generation: UInt64) {
        inFlightGeneration = generation
    }

    private func recordSuccess(_ ack: Acknowledgement, handled generation: UInt64) {
        inFlightGeneration = nil
        hasAcknowledged = true
        if acknowledgement.map({ ack.generation > $0.generation }) ?? true {
            acknowledgement = ack
        }
        if let pending = pendingSnapshot, pending.generation <= ack.generation {
            pendingSnapshot = nil
        }
        if let failed = failedSnapshot, failed.generation <= ack.generation {
            failedSnapshot = nil
        }
        newestHandledGeneration = max(newestHandledGeneration, generation, ack.generation)
        resolveWaiters()
    }

    private func recordFailure(_ error: any Error, snapshot: Snapshot) {
        inFlightGeneration = nil
        failedSnapshot = snapshot
        newestHandledGeneration = max(newestHandledGeneration, snapshot.generation)
        // A dogged caller can retry the retained snapshot; this pass only reports.
        resolveWaiters()
        guard !waiters.isEmpty else { return }

        let generation = snapshot.generation
        var remaining: [Waiter] = []
        for waiter in waiters {
            if waiter.target <= generation {
                waiter.continuation.resume(throwing: error)
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    private func resolveWaiters() {
        guard !waiters.isEmpty else { return }
        let committed = committedGeneration
        let handled = newestHandledGeneration

        var remaining: [Waiter] = []
        for waiter in waiters {
            if committed >= waiter.target && handled >= waiter.watermark {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    /// `SaveGate` forwards the file layer's `SaveError`; callers of this writer use
    /// the equivalent `SaveFailure` so a read-only file has one public error shape.
    private static func surface(_ error: any Error) -> any Error {
        guard let saveError = error as? VersionedJSONFile<Content>.SaveError else {
            return error
        }
        switch saveError {
        case .readOnly(let problem):
            return SaveFailure.readOnly(problem)
        case .sourceChanged:
            return SaveFailure.sourceChanged
        case .backupChanged:
            return SaveFailure.backupChanged
        case .backupNameUnavailable:
            return SaveFailure.backupNameUnavailable
        }
    }
}
