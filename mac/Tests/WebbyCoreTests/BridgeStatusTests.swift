import Foundation
import Testing
@testable import WebbyCore

private func hello(_ profile: String, version: String = "1.0.0", incognito: Bool = false) -> BridgeHello {
    BridgeHello(profile: profile, extVersion: version, incognitoAllowed: incognito)
}

private func message(_ connection: Int, _ profile: String, _ hello: BridgeHello) -> BridgeEvent {
    .message(connection: connection, profile: profile, .hello(hello))
}

@Test func connectedThenHelloFillsInTheEntry() {
    var status = BridgeStatus()
    status.receive(.connected(connection: 1))

    #expect(status.connections.count == 1)
    let connected = status.connections[0]
    #expect(connected.connection == 1)
    #expect(connected.profile == "unknown")
    #expect(connected.extensionVersion == nil)
    #expect(connected.protocolVersion == nil)
    #expect(connected.incognitoAllowed == nil)
    #expect(connected.hasHello == false)
    #expect(connected.id == 1)

    status.receive(message(1, testProfile, hello(testProfile, version: "1.2.3", incognito: true)))

    #expect(status.connections.count == 1)
    let greeted = status.connections[0]
    #expect(greeted.connection == 1)
    #expect(greeted.profile == testProfile)
    #expect(greeted.extensionVersion == "1.2.3")
    #expect(greeted.protocolVersion == BridgeConstants.protocolVersion)
    #expect(greeted.incognitoAllowed == true)
    #expect(greeted.hasHello == true)
}

@Test func helloForAnUnknownConnectionIsIgnored() {
    var status = BridgeStatus()
    status.receive(message(7, testProfile, hello(testProfile)))

    #expect(status.connections.isEmpty)
}

@Test func nonHelloMessagesDoNotChangeStatus() {
    var status = BridgeStatus()
    status.receive(.connected(connection: 1))
    let before = status.connections

    status.receive(.message(connection: 1, profile: testProfile, .tabClosed(tabId: 3, windowClosing: false)))
    status.receive(.message(connection: 1, profile: testProfile, .inventory(windows: [])))

    #expect(status.connections == before)
}

@Test func disconnectRemovesOnlyItsOwnConnection() {
    var status = BridgeStatus()
    status.receive(.connected(connection: 1))
    status.receive(.connected(connection: 2))
    status.receive(message(2, testProfile, hello(testProfile)))

    status.receive(.disconnected(connection: 1, profile: nil))

    #expect(status.connections.map(\.connection) == [2])
    #expect(status.connections[0].hasHello)
}

@Test func aDroppedMessageKeepsTheOpenConnection() {
    var status = BridgeStatus()
    status.receive(.connected(connection: 1))
    status.receive(.connected(connection: 2))
    status.receive(message(2, testProfile, hello(testProfile, version: "1.0.0")))

    status.receive(.dropped(connection: 2, reason: "invalid message"))

    #expect(status.connections.map(\.connection) == [1, 2])
    #expect(status.connections[1].hasHello)

    // The socket is still open, so a later hello must update the same entry.
    status.receive(message(2, testProfile, hello(testProfile, version: "1.1.0")))
    #expect(status.connections[1].extensionVersion == "1.1.0")
}

@Test func aRefusedConnectionKeepsExistingStatus() {
    var status = BridgeStatus()
    status.receive(.connected(connection: 1))
    status.receive(message(1, testProfile, hello(testProfile)))

    status.receive(.dropped(connection: nil, reason: "refused a connection: too many bridges"))

    #expect(status.connections.map(\.connection) == [1])
    #expect(status.connections[0].hasHello)
}

@Test func connectionsAreSortedByIDAcrossProfiles() {
    var status = BridgeStatus()
    status.receive(.connected(connection: 3))
    status.receive(.connected(connection: 1))
    status.receive(.connected(connection: 2))
    status.receive(message(3, "profile-c", hello("profile-c")))
    status.receive(message(1, "profile-a", hello("profile-a")))

    #expect(status.connections.map(\.connection) == [1, 2, 3])
    #expect(status.connections.map(\.profile) == ["profile-a", "unknown", "profile-c"])
}

@Test func malformedReportedVersionYieldsUnknown() {
    var status = BridgeStatus()
    status.receive(.connected(connection: 1))
    status.receive(message(1, testProfile, hello(testProfile, version: "1.x")))

    #expect(status.reloadState(bundledVersion: ExtensionVersion("2.0.0")) == .unknown)
}

@Test func olderReportedVersionNeedsReload() {
    var status = BridgeStatus()
    status.receive(.connected(connection: 1))
    status.receive(message(1, testProfile, hello(testProfile, version: "1.0.0")))

    #expect(
        status.reloadState(bundledVersion: ExtensionVersion("1.1.0"))
            == .reloadNeeded(reported: "1.0.0", bundled: "1.1.0")
    )
}

@Test func equalAndNewerReportedVersionsAreCurrent() {
    var status = BridgeStatus()
    status.receive(.connected(connection: 1))
    status.receive(message(1, testProfile, hello(testProfile, version: "1.1.0")))

    #expect(status.reloadState(bundledVersion: ExtensionVersion("1.1.0")) == .current)

    status.receive(message(1, testProfile, hello(testProfile, version: "1.2.0")))
    #expect(status.reloadState(bundledVersion: ExtensionVersion("1.1.0")) == .current)
}

@Test func connectionWithoutHelloYieldsUnknown() {
    var status = BridgeStatus()
    status.receive(.connected(connection: 1))

    #expect(status.reloadState(bundledVersion: ExtensionVersion("1.0.0")) == .unknown)
}

@Test func noConnectionsYieldsUnknown() {
    let status = BridgeStatus()

    #expect(status.reloadState(bundledVersion: ExtensionVersion("1.0.0")) == .unknown)
}

@Test func nilBundledVersionYieldsUnknown() {
    var status = BridgeStatus()
    status.receive(.connected(connection: 1))
    status.receive(message(1, testProfile, hello(testProfile, version: "1.0.0")))

    #expect(status.reloadState(bundledVersion: nil) == .unknown)
}

@Test func anOlderVersionWinsOverCurrentAndUnknownProfiles() {
    var status = BridgeStatus()
    status.receive(.connected(connection: 1))
    status.receive(message(1, "profile-a", hello("profile-a", version: "1.0.0")))
    status.receive(.connected(connection: 2))
    status.receive(message(2, "profile-b", hello("profile-b", version: "1.2.0")))
    status.receive(.connected(connection: 3))
    status.receive(message(3, "profile-c", hello("profile-c", version: "not-a-version")))

    #expect(
        status.reloadState(bundledVersion: ExtensionVersion("1.1.0"))
            == .reloadNeeded(reported: "1.0.0", bundled: "1.1.0")
    )
}

@Test func theOldestVersionIsReportedDeterministically() {
    var status = BridgeStatus()
    status.receive(.connected(connection: 1))
    status.receive(message(1, "profile-a", hello("profile-a", version: "1.0.5")))
    status.receive(.connected(connection: 2))
    status.receive(message(2, "profile-b", hello("profile-b", version: "1.0.0")))
    status.receive(.connected(connection: 3))
    status.receive(message(3, "profile-c", hello("profile-c", version: "1.0.0")))

    #expect(
        status.reloadState(bundledVersion: ExtensionVersion("1.1.0"))
            == .reloadNeeded(reported: "1.0.0", bundled: "1.1.0")
    )
}
