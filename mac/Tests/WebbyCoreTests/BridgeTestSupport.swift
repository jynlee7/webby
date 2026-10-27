import Foundation
@testable import WebbyCore

struct TimedOut: Error {}
struct EndOfStream: Error {}

let testProfile = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
let otherProfile = "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d"

/// Protocol examples shared with the extension's Node tests.
func fixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // WebbyCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // mac
        .deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("extension/tests/fixtures/\(name).json"))
}

struct NotAnObject: Error {}

func jsonObject(_ data: Data) throws -> NSDictionary {
    guard let object = try JSONSerialization.jsonObject(with: data) as? NSDictionary else { throw NotAnObject() }
    return object
}

/// A short temporary folder: a socket path must fit in 104 bytes.
func makeSocketDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("wb-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Polls `condition` without blocking the cooperative thread pool.
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

func frame(_ payload: Data) throws -> Data {
    try NativeMessageFramer.frame(payload, limit: BridgeConstants.maxMessageFromChrome)
}

func helloPayload(profile: String = testProfile) throws -> Data {
    try ExtensionMessage.hello(BridgeHello(profile: profile, extVersion: "0.0.1", incognitoAllowed: false)).encoded()
}

func activePayload(tab: Int, windowId: Int = 1) throws -> Data {
    try ExtensionMessage.active(
        windowId: windowId,
        incognito: false,
        tab: BridgeTab(id: tab, index: 0, active: true, url: "https://example.com/\(tab)", title: "Tab \(tab)")
    ).encoded()
}

func inventoryPayload() throws -> Data {
    try ExtensionMessage.inventory(windows: [
        BridgeWindow(id: 1, focused: true, incognito: false, tabs: [
            BridgeTab(id: 11, index: 0, active: true, url: "https://example.com/11", title: "Tab 11"),
        ]),
    ]).encoded()
}

/// Collects a server's events as they arrive.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BridgeEvent] = []

    init(_ server: BridgeServer) {
        let events = server.events
        Task { [weak self] in
            for await event in events {
                self?.append(event)
            }
        }
    }

    var events: [BridgeEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var messages: [(profile: String, message: ExtensionMessage)] {
        events.compactMap {
            if case .message(_, let profile, let message) = $0 { return (profile, message) }
            return nil
        }
    }

    var dropped: [String] {
        events.compactMap {
            if case .dropped(_, let reason) = $0 { return reason }
            return nil
        }
    }

    var disconnections: Int {
        events.filter { if case .disconnected = $0 { return true } else { return false } }.count
    }

    private func append(_ event: BridgeEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

/// Reads framed messages from a socket or pipe without blocking the test's thread.
final class FrameReader {
    let fd: Int32
    private var framer: NativeMessageFramer
    private var pending: [Data] = []

    init(fd: Int32, limit: Int = BridgeConstants.maxMessageFromChrome) {
        self.fd = fd
        self.framer = NativeMessageFramer(limit: limit)
    }

    func next(timeout: TimeInterval = 5) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while pending.isEmpty {
            guard Date() < deadline else { throw TimedOut() }
            if try !readIfAvailable() {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        return pending.removeFirst()
    }

    /// True if nothing arrives for `duration`.
    func staysQuiet(for duration: TimeInterval = 0.3) async throws -> Bool {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            if !pending.isEmpty { return false }
            if try !readIfAvailable() {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        return pending.isEmpty
    }

    /// True once the other end has closed or reset the connection.
    func reachesEnd(timeout: TimeInterval = 5) async -> Bool {
        do {
            while true { _ = try await next(timeout: timeout) }
        } catch {
            return !(error is TimedOut)
        }
    }

    private func readIfAvailable() throws -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 0) > 0 else { return false }
        let bytes = try UnixSocket.receive(from: fd)
        guard !bytes.isEmpty else { throw EndOfStream() }
        pending += try framer.append(bytes)
        return true
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// A pipe whose write end never raises SIGPIPE. Each end is closed at most once, so a
/// test never closes a descriptor number another test has since reused.
final class Pipe: @unchecked Sendable {
    let read: Int32
    let write: Int32
    private let lock = NSLock()
    private var writeClosed = false

    init() throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw UnixSocket.Failure(operation: "pipe", code: errno) }
        read = fds[0]
        write = fds[1]
        _ = fcntl(write, F_SETNOSIGPIPE, 1)
    }

    func closeWrite() {
        lock.lock()
        defer { lock.unlock() }
        guard !writeClosed else { return }
        writeClosed = true
        close(write)
    }

    deinit {
        closeWrite()
        close(read)
    }
}
