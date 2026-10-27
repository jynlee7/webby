import Foundation
import Testing
@testable import WebbyCore

/// A bridge stand-in connected straight to the server's socket.
private final class TestClient {
    let fd: Int32
    let reader: FrameReader

    init(path: String) throws {
        fd = try UnixSocket.makeConnection(path: path)
        reader = FrameReader(fd: fd, limit: BridgeConstants.maxMessageToChrome)
    }

    func send(_ payloads: Data...) throws {
        for payload in payloads {
            try UnixSocket.send(frame(payload), to: fd)
        }
    }

    deinit {
        close(fd)
    }
}

private func startServer(in directory: URL, allowedUID: uid_t = getuid()) throws -> (BridgeServer, EventLog) {
    let server = BridgeServer(socketURL: directory.appendingPathComponent("bridge.sock"), allowedUID: allowedUID)
    let log = EventLog(server)
    try server.start()
    return (server, log)
}

@Test func messagesArriveValidatedInOrderWithTheirProfile() async throws {
    let directory = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (server, log) = try startServer(in: directory)
    defer { server.stop() }

    let client = try TestClient(path: server.socketURL.path)
    try client.send(helloPayload(), inventoryPayload(), activePayload(tab: 11))

    #expect(await eventually { log.messages.count == 3 })
    #expect(log.messages.map(\.profile) == [testProfile, testProfile, testProfile])
    #expect(log.messages.map(\.message.type) == ["hello", "inventory", "active"])
    #expect(log.messages.last?.message == (try ExtensionMessage.decode(activePayload(tab: 11))))
    #expect(log.events.first == .connected(connection: 1))
}

@Test func messagesBeforeHelloAndInvalidMessagesAreDropped() async throws {
    let directory = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (server, log) = try startServer(in: directory)
    defer { server.stop() }

    let client = try TestClient(path: server.socketURL.path)
    try client.send(activePayload(tab: 1), helloPayload(), Data(#"{"type":"bogus"}"#.utf8), activePayload(tab: 2))

    #expect(await eventually { log.messages.count == 2 })
    #expect(log.messages.map(\.message.type) == ["hello", "active"])
    #expect(log.dropped.count == 2)
    #expect(log.disconnections == 0)
}

@Test func twoChromeProfilesAreRoutedSeparately() async throws {
    let directory = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (server, log) = try startServer(in: directory)
    defer { server.stop() }

    let first = try TestClient(path: server.socketURL.path)
    let second = try TestClient(path: server.socketURL.path)
    try first.send(helloPayload(profile: testProfile), activePayload(tab: 1))
    try second.send(helloPayload(profile: otherProfile), activePayload(tab: 2))

    #expect(await eventually { log.messages.count == 4 })
    let activeTabs = log.messages.compactMap { entry -> (String, Int)? in
        if case .active(_, _, let tab) = entry.message { return (entry.profile, tab.id) }
        return nil
    }
    #expect(Dictionary(uniqueKeysWithValues: activeTabs) == [testProfile: 1, otherProfile: 2])

    server.send(.focusTab(id: 1), toProfile: testProfile)
    #expect(try AppCommand.decode(await first.reader.next()) == .focusTab(id: 1))
    #expect(try await second.reader.staysQuiet())

    server.send(.resend, toProfile: otherProfile)
    #expect(try AppCommand.decode(await second.reader.next()) == .resend)
    #expect(try await first.reader.staysQuiet())
}

@Test func commandsForAnUnknownProfileAreReported() async throws {
    let directory = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (server, log) = try startServer(in: directory)
    defer { server.stop() }

    server.send(.resend, toProfile: otherProfile)
    #expect(await eventually { log.dropped.count == 1 })
}

@Test func oversizedFramesCloseTheConnection() async throws {
    let directory = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (server, log) = try startServer(in: directory)
    defer { server.stop() }

    let client = try TestClient(path: server.socketURL.path)
    try client.send(helloPayload())
    #expect(await eventually { log.messages.count == 1 })
    var length = UInt32(BridgeConstants.maxMessageFromChrome + 1)
    try UnixSocket.send(withUnsafeBytes(of: &length) { Data($0) }, to: client.fd)

    #expect(await eventually { log.disconnections == 1 })
    #expect(log.events.last == .disconnected(connection: 1, profile: testProfile))
    #expect(log.dropped.count == 1)
    #expect(await client.reader.reachesEnd())
}

@Test func connectionsFromAnotherUserAreRefused() async throws {
    let directory = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (server, log) = try startServer(in: directory, allowedUID: getuid() &+ 1)
    defer { server.stop() }

    let client = try TestClient(path: server.socketURL.path)
    try? client.send(helloPayload())

    #expect(await eventually { log.dropped.count == 1 })
    #expect(log.messages.isEmpty)
    #expect(!log.events.contains(.connected(connection: 1)))
    #expect(await client.reader.reachesEnd())
}

@Test func theSocketIsPrivateAndAStaleOneIsReplaced() async throws {
    let directory = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("bridge.sock").path
    // A crashed run leaves its socket file behind with nobody listening.
    close(try UnixSocket.makeListener(path: path))
    #expect(UnixSocket.isSocket(atPath: path) == true)

    let (server, log) = try startServer(in: directory)
    let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)

    let client = try TestClient(path: path)
    try client.send(helloPayload())
    #expect(await eventually { log.messages.count == 1 })

    server.stop()
    #expect(UnixSocket.isSocket(atPath: path) == nil)
}

@Test func aRunningServerIsNeverReplaced() async throws {
    let directory = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (server, log) = try startServer(in: directory)
    defer { server.stop() }

    let second = BridgeServer(socketURL: server.socketURL)
    #expect(throws: BridgeServer.ServerError.alreadyRunning) { try second.start() }

    let client = try TestClient(path: server.socketURL.path)
    try client.send(helloPayload())
    #expect(await eventually { log.messages.count == 1 })
}

@Test func somethingOtherThanASocketIsLeftAlone() throws {
    let directory = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("bridge.sock")
    try Data("keep me".utf8).write(to: url)

    #expect(throws: BridgeServer.ServerError.pathInUse) { try BridgeServer(socketURL: url).start() }
    #expect(try Data(contentsOf: url) == Data("keep me".utf8))
}

@Test func stalledCommandReaderIsDisconnected() async throws {
    let directory = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (server, log) = try startServer(in: directory)
    defer { server.stop() }
    let client = try TestClient(path: server.socketURL.path)
    try client.send(helloPayload())
    #expect(await eventually { log.messages.count == 1 })
    // Larger than the socket buffer, but within the native messaging command limit.
    let url = "https://example.com/" + String(repeating: "a", count: 900_000)
    server.send(.openTabs(urls: [url]), toProfile: testProfile)
    #expect(await eventually { log.disconnections == 1 })
}

@Test func invalidPayloadContentsAreNotIncludedInDiagnostics() async throws {
    let directory = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (server, log) = try startServer(in: directory)
    defer { server.stop() }
    let client = try TestClient(path: server.socketURL.path)
    try client.send(Data(#"{"type":"https://example.com/private"}"#.utf8))
    #expect(await eventually { log.dropped.count == 1 })
    #expect(log.dropped == ["invalid message"])
}
