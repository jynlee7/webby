import Foundation
import Testing
@testable import WebbyCore

private let introURL = "https://example.com/docs/intro"
private let setupURL = "https://example.com/docs/setup"

/// The value each file in `extension/tests/fixtures/` must decode to.
private let expectedMessages: [String: ExtensionMessage] = [
    "hello": .hello(BridgeHello(profile: testProfile, extVersion: "0.0.1", incognitoAllowed: false)),
    "inventory": .inventory(windows: [
        BridgeWindow(
            id: 1,
            focused: true,
            incognito: false,
            bounds: BridgeWindowBounds(left: 0, top: 25, width: 1440, height: 875),
            tabs: [
                BridgeTab(id: 11, index: 0, active: false, url: "https://example.com/docs", title: "Docs", groupId: 3, lastAccessed: 1_761_580_800_000.5),
                BridgeTab(id: 12, index: 1, active: true, url: introURL, title: "Intro", openerTabId: 11, lastAccessed: 1_761_580_900_000),
            ]
        ),
        BridgeWindow(id: 2, focused: false, incognito: true, tabs: [
            BridgeTab(id: 21, index: 0, active: true, url: "chrome://newtab/", title: "New Tab"),
        ]),
    ]),
    "active": .active(
        windowId: 1,
        incognito: false,
        tab: BridgeTab(id: 12, index: 1, active: true, url: introURL, title: "Intro", openerTabId: 11)
    ),
    "tabCreated": .tabCreated(BridgeCreatedTab(id: 13, windowId: 1, index: 2, url: setupURL, openerTabId: 12)),
    "tabUpdated": .tabUpdated(tabId: 12, url: setupURL, title: "Setup"),
    "tabClosed": .tabClosed(tabId: 13, windowClosing: false),
    "tabMoved": .tabMoved(tabId: 12, windowId: 2, index: 1),
    "tabReplaced": .tabReplaced(added: 14, removed: 12),
]

private let expectedCommands: [String: AppCommand] = [
    "resend": .resend,
    "openTabs": .openTabs(urls: ["https://example.com/docs", "http://localhost:3000/"]),
    "focusTab": .focusTab(id: 12),
]

@Test(arguments: ["hello", "inventory", "active", "tabCreated", "tabUpdated", "tabClosed", "tabMoved", "tabReplaced"])
func extensionMessageFixtureDecodesAndRoundTrips(_ name: String) throws {
    let data = try fixture(name)
    let message = try ExtensionMessage.decode(data)

    #expect(message == expectedMessages[name])
    #expect(message.type == name)
    #expect(try jsonObject(message.encoded()) == jsonObject(data))
}

@Test(arguments: ["resend", "openTabs", "focusTab"])
func appCommandFixtureDecodesAndRoundTrips(_ name: String) throws {
    let data = try fixture(name)
    let command = try AppCommand.decode(data)

    #expect(command == expectedCommands[name])
    #expect(command.type == name)
    #expect(try jsonObject(command.encoded()) == jsonObject(data))
}

@Test func everyMessageTypeHasAFixture() {
    #expect(expectedMessages.count == 8)
    #expect(expectedCommands.count == 3)
}

@Test func absentOptionalFieldsAreOmitted() throws {
    let json = try jsonObject(ExtensionMessage.tabUpdated(tabId: 4, url: nil, title: "Only a title").encoded())
    #expect(json == ["type": "tabUpdated", "tabId": 4, "title": "Only a title"] as NSDictionary)
}

@Test(arguments: [
    #"{"type":"hello","v":2,"profile":"3f2504e0-4f89-41d3-9a0c-0305e82c3301","extVersion":"0.0.1","incognitoAllowed":false}"#,
    #"{"type":"hello","v":1,"profile":"not-a-uuid","extVersion":"0.0.1","incognitoAllowed":false}"#,
    #"{"type":"hello","v":1,"profile":"3f2504e0-4f89-41d3-9a0c-0305e82c3301","extVersion":"0.0.1"}"#,
    #"{"type":"active","windowId":1,"incognito":false,"tab":{"id":-1,"index":0,"active":true,"url":"","title":""}}"#,
    #"{"type":"active","windowId":1,"tab":{"id":1,"index":0,"active":true,"url":"","title":""}}"#,
    #"{"type":"tabClosed","tabId":"5","windowClosing":false}"#,
    #"{"type":"tabMoved","tabId":5,"windowId":1,"index":-2}"#,
    #"{"type":"inventory","windows":[{"id":1,"focused":true,"incognito":false,"tabs":[{"id":1,"index":0,"active":true}]}]}"#,
    #"{"type":"tabReplaced","added":1}"#,
    #"{"type":"closeEverything"}"#,
    #"{"windowId":1}"#,
    #"[]"#,
    #"not json"#,
])
func invalidExtensionMessagesAreRejected(_ json: String) {
    #expect(throws: (any Error).self) { try ExtensionMessage.decode(Data(json.utf8)) }
}

@Test func unknownTypesAreNamedInTheError() {
    #expect(throws: BridgeMessageError.unknownType("closeEverything")) {
        try ExtensionMessage.decode(Data(#"{"type":"closeEverything"}"#.utf8))
    }
}

@Test func overlongURLsAreRejected() throws {
    let url = "https://example.com/" + String(repeating: "a", count: 2 * 1024 * 1024)
    let json = try JSONSerialization.data(withJSONObject: ["type": "tabUpdated", "tabId": 1, "url": url])
    #expect(throws: BridgeMessageError.self) { try ExtensionMessage.decode(json) }
}

@Test(arguments: [
    #"{"type":"openTabs","urls":[]}"#,
    #"{"type":"openTabs","urls":["javascript:alert(1)"]}"#,
    #"{"type":"openTabs","urls":["file:///etc/passwd"]}"#,
    #"{"type":"openTabs","urls":["https://example.com/","chrome://settings"]}"#,
    #"{"type":"openTabs"}"#,
    #"{"type":"focusTab","id":-1}"#,
    #"{"type":"closeTab","id":3}"#,
])
func invalidAppCommandsAreRejected(_ json: String) {
    #expect(throws: (any Error).self) { try AppCommand.decode(Data(json.utf8)) }
}

@Test func invalidCommandsAreNeverEncoded() {
    #expect(throws: BridgeMessageError.self) { try AppCommand.openTabs(urls: ["file:///etc/passwd"]).encoded() }
    #expect(throws: BridgeMessageError.self) { try AppCommand.focusTab(id: -1).encoded() }
}

@Test func onlyTheWebbyExtensionMayLaunchTheBridge() {
    let origin = "chrome-extension://ccehhpjcbcabmlalclppmdomonfdcbcl/"
    #expect(BridgeConstants.extensionOrigin == origin)
    #expect(BridgeConstants.isAllowedCaller(["/Applications/Webby.app/Contents/MacOS/webby-bridge", origin]))
    #expect(BridgeConstants.isAllowedCaller(["webby-bridge", origin, "--parent-window=0"]))
    #expect(!BridgeConstants.isAllowedCaller(["webby-bridge", "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"]))
    #expect(!BridgeConstants.isAllowedCaller(["webby-bridge", "chrome-extension://ccehhpjcbcabmlalclppmdomonfdcbcl"]))
    #expect(!BridgeConstants.isAllowedCaller(["webby-bridge"]))
}
