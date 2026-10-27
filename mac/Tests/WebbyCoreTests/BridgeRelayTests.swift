import Foundation
import Testing
@testable import WebbyCore

/// A relay wired to pipes that stand in for Chrome's stdin and stdout.
private final class RelayHarness {
    let chromeIn: Pipe
    let chromeOut: Pipe
    let toChrome: FrameReader
    private let ended = Flag()

    init(socketURL: URL) throws {
        chromeIn = try Pipe()
        chromeOut = try Pipe()
        toChrome = FrameReader(fd: chromeOut.read, limit: BridgeConstants.maxMessageToChrome)
        let relay = BridgeRelay(input: chromeIn.read, output: chromeOut.write, socketURL: socketURL) { _ in }
        relay.start()
        DispatchQueue.global().async { [ended] in
            relay.wait()
            ended.set()
        }
    }

    var hasEnded: Bool { ended.isSet }

    func fromChrome(_ payloads: Data...) throws {
        for payload in payloads {
            try UnixSocket.send(frame(payload), to: chromeIn.write)
        }
    }

    /// Closes stdin, as Chrome does, and waits for the relay to stop. Tests call this
    /// before the pipes are released, so the relay never reads a reused descriptor.
    func closeInput() async -> Bool {
        chromeIn.closeWrite()
        return await eventually { ended.isSet }
    }
}

@Test func relayReplaysTheLatestStateAndReconnectsAfterTheAppRestarts() async throws {
    let directory = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let socketURL = directory.appendingPathComponent("bridge.sock")
    let chrome = try RelayHarness(socketURL: socketURL)

    // Chrome talks while Webby isn't running: only the latest state is kept.
    try chrome.fromChrome(helloPayload(), inventoryPayload(), activePayload(tab: 11), activePayload(tab: 12))
    try await Task.sleep(nanoseconds: 300_000_000)

    var server = BridgeServer(socketURL: socketURL)
    var log = EventLog(server)
    try server.start()
    #expect(await eventually { log.messages.count == 3 })
    #expect(log.messages.map(\.message) == [
        try ExtensionMessage.decode(helloPayload()),
        try ExtensionMessage.decode(inventoryPayload()),
        try ExtensionMessage.decode(activePayload(tab: 12)),
    ])
    // Nothing the replay doesn't cover was missed, so the extension isn't asked to resend.
    #expect(try await chrome.toChrome.staysQuiet())

    // Commands reach Chrome in its framing.
    server.send(.focusTab(id: 12), toProfile: testProfile)
    #expect(try AppCommand.decode(await chrome.toChrome.next()) == .focusTab(id: 12))

    // Webby quits; Chrome keeps going.
    server.stop()
    try chrome.fromChrome(
        ExtensionMessage.tabCreated(BridgeCreatedTab(id: 13, windowId: 1, index: 1)).encoded(),
        activePayload(tab: 13)
    )
    try await Task.sleep(nanoseconds: 300_000_000)

    // Webby restarts: within 5 s the bridge reconnects and replays the latest state, and
    // because it missed `tabCreated` it asks the extension to resend everything.
    server = BridgeServer(socketURL: socketURL)
    log = EventLog(server)
    try server.start()
    defer { server.stop() }
    #expect(await eventually(timeout: 5) { log.messages.count == 3 })
    #expect(log.messages.map(\.message.type) == ["hello", "inventory", "active"])
    #expect(log.messages.last?.message == (try ExtensionMessage.decode(activePayload(tab: 13))))
    #expect(try AppCommand.decode(await chrome.toChrome.next()) == .resend)

    #expect(await chrome.closeInput())
}

/// An inventory over 8 MiB: five tabs with URLs close to Chrome's 2 MiB limit.
private func largeInventoryPayload() throws -> Data {
    let url = "https://example.com/" + String(repeating: "a", count: 2_000_000)
    let tabs = (0..<5).map { BridgeTab(id: 20 + $0, index: $0, active: $0 == 0, url: url, title: "Tab \(20 + $0)") }
    return try ExtensionMessage.inventory(windows: [
        BridgeWindow(id: 1, focused: true, incognito: false, tabs: tabs),
    ]).encoded()
}

@Test func relayDeliversALargeSnapshotToAReadingAppWithoutReconnecting() async throws {
    let directory = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let socketURL = directory.appendingPathComponent("bridge.sock")
    let chrome = try RelayHarness(socketURL: socketURL)
    let inventory = try largeInventoryPayload()
    #expect(inventory.count > 8 * 1024 * 1024)
    let snapshot = try [helloPayload(), inventory, activePayload(tab: 20)].map(ExtensionMessage.decode)

    // Chrome sends a snapshot while Webby isn't running, so the relay replays it on connecting.
    try chrome.fromChrome(helloPayload(), inventory, activePayload(tab: 20))
    try await Task.sleep(nanoseconds: 300_000_000)
    let server = BridgeServer(socketURL: socketURL)
    let log = EventLog(server)
    try server.start()
    defer { server.stop() }
    #expect(await eventually { log.messages.count == 3 })
    // Contents are compared as a Bool, so a failure doesn't print the inventory.
    let replayed = log.messages.map(\.message) == snapshot
    #expect(log.messages.map(\.message.type) == ["hello", "inventory", "active"])
    #expect(replayed)

    // The extension sends a fresh snapshot to the connected app, and an event right after it.
    let closed = ExtensionMessage.tabClosed(tabId: 21, windowClosing: false)
    try chrome.fromChrome(helloPayload(), inventory, activePayload(tab: 20), closed.encoded())
    #expect(await eventually { log.messages.count == 7 })
    let resent = Array(log.messages.dropFirst(3).map(\.message)) == snapshot + [closed]
    #expect(log.messages.dropFirst(3).map(\.message.type) == ["hello", "inventory", "active", "tabClosed"])
    #expect(resent)

    // Webby kept reading, so the relay never dropped the connection or asked for a resend.
    #expect(log.disconnections == 0)
    #expect(try await chrome.toChrome.staysQuiet())
    #expect(await chrome.closeInput())
}

@Test func relayForwardsOnlyValidMessagesAfterHello() async throws {
    let directory = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = BridgeServer(socketURL: directory.appendingPathComponent("bridge.sock"))
    let log = EventLog(server)
    try server.start()
    defer { server.stop() }

    let chrome = try RelayHarness(socketURL: server.socketURL)
    #expect(await eventually { log.events.contains(.connected(connection: 1)) })
    try chrome.fromChrome(
        activePayload(tab: 1),
        helloPayload(),
        Data(#"{"type":"tabClosed","tabId":"seven"}"#.utf8),
        ExtensionMessage.tabClosed(tabId: 7, windowClosing: true).encoded()
    )

    #expect(await eventually { log.messages.count == 2 })
    #expect(log.messages.map(\.message.type) == ["hello", "tabClosed"])
    #expect(log.dropped.isEmpty)
    #expect(await chrome.closeInput())
}

@Test func relayPassesOnlyValidCommandsToChrome() async throws {
    let directory = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("bridge.sock").path
    // A raw listener, so the test can send commands the real server would refuse to encode.
    let listener = try UnixSocket.makeListener(path: path)
    defer { close(listener) }

    let chrome = try RelayHarness(socketURL: URL(fileURLWithPath: path))
    var app: Int32 = -1
    #expect(await eventually {
        app = UnixSocket.acceptConnection(listener) ?? -1
        return app >= 0
    })
    defer { close(app) }

    for json in [#"{"type":"openTabs","urls":["javascript:alert(1)"]}"#, #"{"type":"selfDestruct"}"#, #"{"type":"resend"}"#] {
        try UnixSocket.send(frame(Data(json.utf8)), to: app)
    }
    #expect(try AppCommand.decode(await chrome.toChrome.next()) == .resend)
    #expect(try await chrome.toChrome.staysQuiet())
    #expect(await chrome.closeInput())
}

@Test func relayStopsOnAnOversizedFrameFromChrome() async throws {
    let directory = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let chrome = try RelayHarness(socketURL: directory.appendingPathComponent("bridge.sock"))

    var length = UInt32(BridgeConstants.maxMessageFromChrome + 1)
    try UnixSocket.send(withUnsafeBytes(of: &length) { Data($0) }, to: chrome.chromeIn.write)
    #expect(await eventually { chrome.hasEnded })
}

@Test func relayStopsWhenChromeStopsReadingCommands() async throws {
    let directory = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("bridge.sock").path
    let listener = try UnixSocket.makeListener(path: path)
    defer { close(listener) }
    let chrome = try RelayHarness(socketURL: URL(fileURLWithPath: path))
    var app: Int32 = -1
    #expect(await eventually {
        app = UnixSocket.acceptConnection(listener) ?? -1
        return app >= 0
    })
    defer { close(app) }
    let command = AppCommand.openTabs(urls: ["https://example.com/" + String(repeating: "a", count: 900_000)])
    try UnixSocket.send(frame(command.encoded()), to: app)
    // Nothing consumes Chrome stdout. The relay must time out, not block forever.
    #expect(await eventually { chrome.hasEnded })
}

@Test func relayStopsWhenChromeQuitsWhileWebbyIsNotReading() async throws {
    let directory = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("bridge.sock").path
    // Webby accepts the connection but never reads from it.
    let listener = try UnixSocket.makeListener(path: path)
    defer { close(listener) }
    let chrome = try RelayHarness(socketURL: URL(fileURLWithPath: path))
    var app: Int32 = -1
    #expect(await eventually {
        app = UnixSocket.acceptConnection(listener) ?? -1
        return app >= 0
    })
    defer { close(app) }

    // Chrome sends far more than the socket buffer holds, then closes stdin. Written from
    // another thread, because a relay stuck on a write would stop reading stdin too.
    let big = try ExtensionMessage.tabUpdated(tabId: 1, url: "https://example.com/" + String(repeating: "a", count: 1_000_000), title: nil).encoded()
    let stream = try frame(helloPayload()) + (0..<8).map { _ in try frame(big) }.reduce(Data(), +)
    let input = chrome.chromeIn
    DispatchQueue.global().async {
        try? UnixSocket.send(stream, to: input.write)
        input.closeWrite()
    }
    // Writes to Webby happen off the relay's queue, so the EOF is seen right away rather
    // than after each stalled write times out.
    #expect(await eventually(timeout: 5) { chrome.hasEnded }, "relay did not exit after Chrome closed stdin")
}
