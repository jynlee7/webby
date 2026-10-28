import Foundation
import Testing
@testable import WebbyCore

private struct TestContent: Codable, Equatable, Sendable {
    var value: String
}

private let defaultContent = TestContent(value: "default")

private struct InjectedWriteError: Error {}

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbyDiskWriterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func removeTempDirectory(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
}

private func makeGate(at url: URL) -> SaveGate<TestContent> {
    let file = VersionedJSONFile(fileURL: url, defaultContent: defaultContent)
    return SaveGate(file: file, committedGeneration: 0)
}

private func snapshot(_ generation: UInt64, _ value: String) -> SaveGate<TestContent>.Snapshot {
    SaveGate<TestContent>.Snapshot(generation: generation, content: TestContent(value: value))
}

private func readContent(at url: URL) -> TestContent {
    VersionedJSONFile(fileURL: url, defaultContent: defaultContent).content
}

/// Counts commit attempts without assuming which thread the consumer runs on.
private final class CommitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [UInt64] = []

    @discardableResult
    func record(_ generation: UInt64) -> Int {
        lock.lock()
        defer { lock.unlock() }
        generations.append(generation)
        return generations.count
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return generations.count
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Suspends a commit inside the writer's consumer without parking a thread.
private final class CommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var released = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            started = true
            if let waiter = startWaiter {
                startWaiter = nil
                lock.unlock()
                waiter.resume()
            } else {
                lock.unlock()
            }
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                releaseWaiter = continuation
                lock.unlock()
            }
        }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if started {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiter = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let waiter = releaseWaiter
        releaseWaiter = nil
        lock.unlock()
        waiter?.resume()
    }
}

private final class ConditionFlag: @unchecked Sendable {
    private let condition = NSCondition()
    private var value = false

    func set() {
        condition.lock()
        value = true
        condition.broadcast()
        condition.unlock()
    }

    func wait(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while !value {
            if !condition.wait(until: deadline) {
                return false
            }
        }
        return true
    }
}

@Test func staleGenerationAfterNewerCommitNeverOverwrites() async throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let gate = makeGate(at: url)
    let writer = DiskWriter(gate: gate)

    try await writer.flush(snapshot(7, "seven"))
    _ = try gate.commit(snapshot(10, "ten"))

    await writer.enqueue(snapshot(8, "stale"))
    try await writer.flush()

    #expect(readContent(at: url) == TestContent(value: "ten"))
    #expect(gate.generation == 10)
    let acknowledgement = await writer.lastAcknowledgement
    #expect(acknowledgement?.generation == 10)
}

@Test func rapidBurstsCoalesceToNewestState() async throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let gate = makeGate(at: url)
    let recorder = CommitRecorder()
    let firstCommit = CommitGate()
    let writer = DiskWriter(
        gate: gate,
        commit: { snapshot in
            let attempt = recorder.record(snapshot.generation)
            if attempt == 1 {
                await firstCommit.suspend()
            }
            return try gate.commit(snapshot)
        }
    )

    await writer.enqueue(snapshot(1, "v1"))
    await firstCommit.waitUntilStarted()

    for generation in UInt64(2)...100 {
        await writer.enqueue(snapshot(generation, "v\(generation)"))
    }

    firstCommit.release()
    try await writer.flush()

    #expect(recorder.count < 10)
    #expect(readContent(at: url) == TestContent(value: "v100"))
    let acknowledgement = await writer.lastAcknowledgement
    #expect(acknowledgement?.generation == 100)
}

@Test func flushWaitsForNewestSubmittedState() async throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let gate = makeGate(at: url)
    let writer = DiskWriter(gate: gate)

    await writer.enqueue(snapshot(1, "v1"))
    await writer.enqueue(snapshot(2, "v2"))
    await writer.enqueue(snapshot(3, "v3"))

    try await writer.flush()

    #expect(readContent(at: url) == TestContent(value: "v3"))
    let acknowledgement = await writer.lastAcknowledgement
    #expect(acknowledgement?.generation == 3)
}

@Test func enqueueDuringFlushDoesNotExtendThatFlush() async throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let gate = makeGate(at: url)
    let recorder = CommitRecorder()
    let blockFive = CommitGate()
    let blockSix = CommitGate()
    let flushFinished = ConditionFlag()

    let writer = DiskWriter(
        gate: gate,
        commit: { snapshot in
            recorder.record(snapshot.generation)
            if snapshot.generation == 5 {
                await blockFive.suspend()
            }
            if snapshot.generation == 6 {
                await blockSix.suspend()
            }
            return try gate.commit(snapshot)
        }
    )

    await writer.enqueue(snapshot(5, "v5"))
    await blockFive.waitUntilStarted()

    let flushTask = Task {
        try await writer.flush()
        flushFinished.set()
    }

    // Wait until flush has captured its target, so the generation 6 enqueue cannot
    // legitimately be part of that same flush.
    var spins = 0
    while await writer.pendingWaiterCount == 0 && spins < 10_000 {
        await Task.yield()
        spins += 1
    }
    let waitedAtStart = await writer.pendingWaiterCount > 0
    #expect(waitedAtStart)

    await writer.enqueue(snapshot(6, "v6"))
    blockFive.release()

    await blockSix.waitUntilStarted()

    // The consumer is now blocked writing generation 6. A flush that is still
    // waiting for it cannot have finished.
    #expect(flushFinished.wait(timeout: 2))

    blockSix.release()
    try await writer.flush()
    try await flushTask.value

    #expect(readContent(at: url) == TestContent(value: "v6"))
    let acknowledgement = await writer.lastAcknowledgement
    #expect(acknowledgement?.generation == 6)
}

@Test func failedCommitSurfacesErrorAndRetrySucceeds() async throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let gate = makeGate(at: url)
    let attempts = CommitRecorder()
    let failures = Counter()
    let writer = DiskWriter(
        gate: gate,
        onFailure: { _ in failures.increment() },
        commit: { snapshot in
            if attempts.record(snapshot.generation) == 1 {
                throw InjectedWriteError()
            }
            return try gate.commit(snapshot)
        }
    )

    await writer.enqueue(snapshot(3, "v3"))

    do {
        try await writer.flush()
        Issue.record("The failing flush unexpectedly succeeded")
    } catch {
        #expect(error is InjectedWriteError)
    }

    #expect(failures.count == 1)
    #expect(readContent(at: url) == defaultContent)
    #expect(gate.generation == 0)
    let failedAcknowledgement = await writer.lastAcknowledgement
    #expect(failedAcknowledgement == nil)

    try await writer.flush(snapshot(3, "v3"))

    #expect(attempts.count == 2)
    #expect(readContent(at: url) == TestContent(value: "v3"))
    let acknowledgement = await writer.lastAcknowledgement
    #expect(acknowledgement?.generation == 3)
}

@Test func readOnlyGateRejectsWithSaveFailure() async throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let original = Data(#"{"version":99,"content":{"value":"future"}}"#.utf8)
    try original.write(to: url)

    let gate = makeGate(at: url)
    #expect(gate.isReadOnly)
    let writer = DiskWriter(gate: gate)

    await writer.enqueue(snapshot(1, "v1"))

    do {
        try await writer.flush()
        Issue.record("A read-only gate unexpectedly accepted a write")
    } catch {
        #expect(
            error as? SaveFailure == .readOnly(
                .newerVersion(found: 99, supported: VersionedJSONFile<TestContent>.currentVersion)
            )
        )
    }

    #expect(try Data(contentsOf: url) == original)
    let acknowledgement = await writer.lastAcknowledgement
    #expect(acknowledgement == nil)
}

@Test func staleEnqueueDuringFlushDoesNotStrandIt() async throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let gate = makeGate(at: url)
    let recorder = CommitRecorder()
    let blockTwo = CommitGate()
    let writer = DiskWriter(
        gate: gate,
        commit: { snapshot in
            recorder.record(snapshot.generation)
            if snapshot.generation == 2 { await blockTwo.suspend() }
            return try gate.commit(snapshot)
        }
    )

    await writer.enqueue(snapshot(2, "v2"))
    await blockTwo.waitUntilStarted()

    let flushTask = Task { try await writer.flush() }
    var spins = 0
    while await writer.pendingWaiterCount == 0 && spins < 10_000 {
        await Task.yield()
        spins += 1
    }

    // A late, older snapshot must not move the handled watermark behind the flush's
    // watermark and leave its continuation suspended forever.
    await writer.enqueue(snapshot(1, "v1"))
    blockTwo.release()

    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await flushTask.value }
        group.addTask {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            throw InjectedWriteError()
        }
        try await group.next()
        group.cancelAll()
    }

    #expect(readContent(at: url) == TestContent(value: "v2"))
    let acknowledgement = await writer.lastAcknowledgement
    #expect(acknowledgement?.generation == 2)
}

@Test func generationZeroFlushWaitsForTheFirstCommit() async throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let gate = makeGate(at: url)
    let gateBlock = CommitGate()
    let writer = DiskWriter(
        gate: gate,
        commit: { snapshot in
            await gateBlock.suspend()
            return try gate.commit(snapshot)
        }
    )

    let flush = Task { try await writer.flush(SaveGate<TestContent>.Snapshot(generation: 0, content: defaultContent)) }
    await gateBlock.waitUntilStarted()
    #expect(!FileManager.default.fileExists(atPath: url.path))
    gateBlock.release()
    try await flush.value
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func parameterlessFlushReturnsWhenNothingIsQueued() async throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let gate = makeGate(at: url)
    let recorder = CommitRecorder()
    let writer = DiskWriter(
        gate: gate,
        commit: { snapshot in
            recorder.record(snapshot.generation)
            return try gate.commit(snapshot)
        }
    )

    // Nothing was ever submitted, so there is no work that could resolve a waiter.
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await writer.flush() }
        group.addTask {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            throw InjectedWriteError()
        }
        try await group.next()
        group.cancelAll()
    }
    #expect(recorder.count == 0)

    // A synchronous gate commit is already on disk, so this must also return.
    _ = try gate.commit(snapshot(1, "direct"))
    try await writer.flush()
    #expect(readContent(at: url) == TestContent(value: "direct"))
}
