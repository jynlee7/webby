import Foundation
import Testing
@testable import WebbyCore

/// A connected socket pair. The writer side gets its own descriptor; `peer` is the reader.
private func makeSocketPair() throws -> (writer: Int32, peer: Int32) {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
        throw UnixSocket.Failure(operation: "socketpair", code: errno)
    }
    var on: Int32 = 1
    for fd in fds {
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }
    return (fds[0], fds[1])
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

@Test func writesKeepTheirOrder() async throws {
    let (fd, peer) = try makeSocketPair()
    defer { close(peer) }
    let writer = SocketWriter(fd: fd, label: "test.order", limit: 1 << 20) {}
    defer { writer.cancel() }

    let payloads = (0..<200).map { Data("{\"n\":\($0)}".utf8) }
    for payload in payloads {
        #expect(writer.enqueue(try frame(payload)))
    }
    let reader = FrameReader(fd: peer)
    var received: [Data] = []
    for _ in payloads {
        received.append(try await reader.next())
    }
    #expect(received == payloads)
}

@Test func queuedOutputIsBoundedWhileThePeerIsntReading() throws {
    let (fd, peer) = try makeSocketPair()
    defer { close(peer) }
    let writer = SocketWriter(fd: fd, label: "test.bounded", limit: 64 * 1024) {}
    defer { writer.cancel() }

    // One frame larger than the limit is accepted when nothing is waiting; it stalls,
    // because nobody reads the peer.
    #expect(writer.enqueue(Data(count: 1024 * 1024)))
    #expect(!writer.enqueue(Data(count: 1)))
}

@Test func cancelUnblocksAStuckWriteAndClosesTheStream() async throws {
    let (fd, peer) = try makeSocketPair()
    defer { close(peer) }
    let failures = Counter()
    let writer = SocketWriter(fd: fd, label: "test.cancel", limit: 1 << 20) { failures.increment() }
    #expect(writer.enqueue(Data(count: 1024 * 1024)))
    try await Task.sleep(nanoseconds: 100_000_000)

    let cancelled = Date()
    writer.cancel()
    #expect(!writer.enqueue(Data(count: 1)))

    // The peer drains what made it into the buffer, then sees the stream end promptly.
    var ended = false
    while !ended, Date().timeIntervalSince(cancelled) < 2 {
        var descriptor = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
        if poll(&descriptor, 1, 100) > 0 {
            ended = try UnixSocket.receive(from: peer).isEmpty
        }
    }
    #expect(ended)
    #expect(Date().timeIntervalSince(cancelled) < 1)
    // Cancelling is not a failure.
    #expect(failures.value == 0)
}

@Test func aFailedWriteStopsLaterWritesAndIsReportedOnce() async throws {
    let (fd, peer) = try makeSocketPair()
    close(peer)
    let failures = Counter()
    let writer = SocketWriter(fd: fd, label: "test.failure", limit: 1 << 20) { failures.increment() }
    defer { writer.cancel() }

    #expect(writer.enqueue(Data("first".utf8)))
    #expect(await eventually { failures.value == 1 })
    #expect(!writer.enqueue(Data("second".utf8)))
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(failures.value == 1)
}
