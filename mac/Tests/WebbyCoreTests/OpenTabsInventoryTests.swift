import Foundation
import Testing
@testable import WebbyCore

private let otSession = "100@2026-01-01"

private func otTab(_ id: Int, _ index: Int, active: Bool = false, url: String = "https://example.com/") -> BridgeTab {
    BridgeTab(id: id, index: index, active: active, url: url, title: "T\(id)")
}

private func otWindow(_ id: Int, focused: Bool = false, incognito: Bool = false, tabs: [BridgeTab]) -> BridgeWindow {
    BridgeWindow(id: id, focused: focused, incognito: incognito, tabs: tabs)
}

private func otMessage(_ message: ExtensionMessage, connection: Int = 1, profile: String = "profile-a") -> BridgeEvent {
    .message(connection: connection, profile: profile, message)
}

private func otReducer(_ events: [BridgeEvent]) -> OpenTabsInventory {
    var reducer = OpenTabsInventory(session: otSession)
    for event in events { reducer.receive(event) }
    return reducer
}

private func otTabIDs(_ reducer: OpenTabsInventory) -> [[Int]] {
    reducer.inventory.windows.map { $0.tabs.map(\.tabID) }
}

private let otBase: [BridgeEvent] = [
    otMessage(.inventory(windows: [
        otWindow(1, focused: true, tabs: [otTab(1, 0, active: true), otTab(2, 1), otTab(3, 2)]),
        otWindow(2, tabs: [otTab(4, 0, active: true)]),
    ])),
]

@Test func inventoryFillsBrowserProfileAndSession() {
    let windows = otReducer(otBase).inventory.windows

    #expect(windows.map(\.windowID) == [1, 2])
    #expect(windows.map(\.order) == [0, 1])
    #expect(windows.map(\.focused) == [true, false])
    #expect(windows.allSatisfy {
        $0.browser == "com.google.Chrome" && $0.appBundleID == "com.google.Chrome"
            && $0.profile == "profile-a" && $0.session == otSession && !$0.incognito
    })
    #expect(windows[0].tabs.map(\.title) == ["T1", "T2", "T3"])
    #expect(windows[0].tabs.map(\.active) == [true, false, false])
}

@Test func emptyURLAndTitleBecomeNil() {
    let reducer = otReducer([
        otMessage(.inventory(windows: [otWindow(1, tabs: [otTab(1, 0)])])),
        otMessage(.tabCreated(BridgeCreatedTab(id: 2, windowId: 1, index: 1))),
    ])

    let tab = reducer.inventory.windows[0].tabs[1]
    #expect(tab.url == nil)
    #expect(tab.title == nil)
}

@Test func newInventoryReplacesTheProfilesWindows() {
    let reducer = otReducer(otBase + [
        otMessage(.inventory(windows: [otWindow(9, tabs: [otTab(7, 0)])])),
    ])

    #expect(otTabIDs(reducer) == [[7]])
}

@Test func tabCreatedInsertsAtIndexAndUpdateFillsURLAndTitle() {
    let reducer = otReducer(otBase + [
        otMessage(.tabCreated(BridgeCreatedTab(id: 5, windowId: 1, index: 1))),
        otMessage(.tabUpdated(tabId: 5, url: "https://new.example/", title: "New")),
    ])

    #expect(otTabIDs(reducer) == [[1, 5, 2, 3], [4]])
    let tab = reducer.inventory.windows[0].tabs[1]
    #expect(tab.url == "https://new.example/")
    #expect(tab.title == "New")
    #expect(reducer.inventory.windows[0].tabs.map(\.index) == [0, 1, 2, 3])
}

@Test func tabCreatedInUnknownWindowStaysHiddenUntilResolved() {
    var reducer = otReducer(otBase)

    reducer.receive(otMessage(.tabCreated(BridgeCreatedTab(id: 5, windowId: 99, index: 0))))

    #expect(otTabIDs(reducer) == [[1, 2, 3], [4]])
}

@Test func tabUpdatedKeepsFieldsItDoesNotCarry() {
    let reducer = otReducer(otBase + [
        otMessage(.tabUpdated(tabId: 2, url: nil, title: "Renamed")),
    ])

    let tab = reducer.inventory.windows[0].tabs[1]
    #expect(tab.title == "Renamed")
    #expect(tab.url == "https://example.com/")
}

@Test func tabClosedRemovesTabAndDropsEmptyWindow() {
    let reducer = otReducer(otBase + [
        otMessage(.tabClosed(tabId: 2, windowClosing: false)),
        otMessage(.tabClosed(tabId: 4, windowClosing: true)),
    ])

    #expect(otTabIDs(reducer) == [[1, 3]])
}

@Test func tabMovedChangesPositionAndWindow() {
    let reorder = otReducer(otBase + [otMessage(.tabMoved(tabId: 3, windowId: 1, index: 0))])
    #expect(otTabIDs(reorder) == [[3, 1, 2], [4]])

    let across = otReducer(otBase + [otMessage(.tabMoved(tabId: 2, windowId: 2, index: 1))])
    #expect(otTabIDs(across) == [[1, 3], [4, 2]])
    #expect(across.inventory.windows[1].tabs.last?.title == "T2")
}

@Test func tabMovedOutOfASingleTabWindowRemovesThatWindow() {
    let reducer = otReducer(otBase + [
        otMessage(.tabMoved(tabId: 4, windowId: 1, index: 3)),
    ])

    #expect(otTabIDs(reducer) == [[1, 2, 3, 4]])
}

@Test func tabReplacedKeepsPositionAndContent() {
    let reducer = otReducer(otBase + [otMessage(.tabReplaced(added: 20, removed: 2))])

    #expect(otTabIDs(reducer) == [[1, 20, 3], [4]])
    #expect(reducer.inventory.windows[0].tabs[1].title == "T2")
}

@Test func activeMovesTheActiveFlagWithinItsWindow() {
    let reducer = otReducer(otBase + [
        otMessage(.active(windowId: 1, incognito: false, tab: otTab(3, 2, url: "https://a.example/"))),
    ])

    let first = reducer.inventory.windows[0]
    #expect(first.tabs.map(\.active) == [false, false, true])
    #expect(first.tabs[2].url == "https://a.example/")
    #expect(reducer.inventory.windows[1].tabs.map(\.active) == [true])
}

@Test func activeInAnUnknownIncognitoWindowIsKeptAsIncognito() {
    let reducer = otReducer(otBase + [
        otMessage(.active(windowId: 7, incognito: true, tab: otTab(30, 0))),
    ])

    let window = reducer.inventory.windows.first { $0.windowID == 7 }
    #expect(window?.incognito == true)
    #expect(window?.tabs.map(\.tabID) == [30])
}

@Test func incognitoWindowsStayInTheInventoryMarkedIncognito() {
    let reducer = otReducer([
        otMessage(.inventory(windows: [
            otWindow(1, tabs: [otTab(1, 0)]),
            otWindow(2, incognito: true, tabs: [otTab(2, 0)]),
        ])),
    ])

    #expect(reducer.inventory.windows.map(\.incognito) == [false, true])
}

@Test func disconnectRemovesOnlyThatConnectionsWindows() {
    let other = otMessage(.inventory(windows: [otWindow(5, tabs: [otTab(50, 0)])]), connection: 2, profile: "profile-b")
    let reducer = otReducer(otBase + [other, .disconnected(connection: 1, profile: "profile-a")])

    #expect(reducer.inventory.windows.map(\.profile) == ["profile-b"])
}

@Test func lateDisconnectFromAReplacedBridgeKeepsTheNewConnectionsTabs() {
    let replacement = otMessage(.inventory(windows: [otWindow(1, tabs: [otTab(9, 0)])]), connection: 2)
    let reducer = otReducer(otBase + [replacement, .disconnected(connection: 1, profile: "profile-a")])

    #expect(otTabIDs(reducer) == [[9]])
}

@Test func droppedConnectionRemovesItsWindowsAndUnnamedDropsAreIgnored() {
    var reducer = otReducer(otBase)
    let ignored = reducer.receive(.dropped(connection: nil, reason: "bad"))
    let dropped = reducer.receive(.dropped(connection: 1, reason: "bad"))
    #expect(!ignored)
    #expect(dropped)
    #expect(reducer.inventory.windows.isEmpty)
}

@Test func twoProfilesKeepSeparateWindowsEvenWithSameIDs() {
    let b = otMessage(.inventory(windows: [otWindow(1, tabs: [otTab(1, 0)])]), connection: 2, profile: "profile-b")
    let reducer = otReducer(otBase + [b, otMessage(.tabClosed(tabId: 1, windowClosing: false), connection: 2, profile: "profile-b")])

    #expect(reducer.inventory.windows.map(\.profile) == ["profile-a", "profile-a"])
    #expect(otTabIDs(reducer) == [[1, 2, 3], [4]])
}

@Test func receiveReportsWhetherTheInventoryChanged() {
    var reducer = otReducer(otBase)

    let connected = reducer.receive(.connected(connection: 3))
    let same = reducer.receive(otBase[0])
    let unknown = reducer.receive(otMessage(.tabClosed(tabId: 99, windowClosing: false)))
    let closed = reducer.receive(otMessage(.tabClosed(tabId: 3, windowClosing: false)))
    #expect(!connected)
    #expect(!same)
    #expect(!unknown)
    #expect(closed)
}

@Test func changingSessionDropsTabsFromThePreviousRun() {
    var reducer = otReducer(otBase)

    reducer.setSession("200@2026-01-02")

    #expect(reducer.inventory.windows.isEmpty)
    reducer.receive(otBase[0])
    #expect(reducer.inventory.windows.allSatisfy { $0.session == "200@2026-01-02" })
}

@Test func openTabsListsExactlyTheTabsWithAttachedNotes() throws {
    let reducer = otReducer([
        otMessage(.inventory(windows: [
            otWindow(1, focused: true, tabs: [
                otTab(1, 0, active: true, url: "https://example.com/a"),
                otTab(2, 1, url: "https://example.com/b"),
                otTab(3, 2, url: "https://other.example/"),
            ]),
            otWindow(2, incognito: true, tabs: [otTab(4, 0, url: "https://example.com/a")]),
        ])),
    ])
    let page = tabFixtureNote(
        id: tabFixtureID("001"),
        anchor: tabFixtureWebAnchor("https://example.com/b")
    )
    let bound = tabFixtureNote(
        id: tabFixtureID("002"),
        tab: tabFixtureBinding(session: otSession, tabID: 3, windowID: 1)
    )
    let elsewhere = tabFixtureNote(
        id: tabFixtureID("003"),
        anchor: tabFixtureWebAnchor("https://nowhere.example/")
    )

    let groups = LibraryTabGroups.openTabs(
        notes: [page, bound, elsewhere],
        inventory: reducer.inventory,
        rules: []
    )

    #expect(groups.map(\.tab.tabID) == [2, 3])
    #expect(groups.map { tabFixtureNoteIDs($0.notes) } == [["001"], ["002"]])
    #expect(groups.map(\.title) == ["T2", "T3"])

    var closed = reducer
    closed.receive(otMessage(.tabClosed(tabId: 2, windowClosing: false)))
    let after = LibraryTabGroups.openTabs(notes: [page, bound, elsewhere], inventory: closed.inventory, rules: [])
    #expect(after.map(\.tab.tabID) == [3])
}

private func otCreated(_ id: Int, window: Int, index: Int) -> BridgeEvent {
    otMessage(.tabCreated(BridgeCreatedTab(id: id, windowId: window, index: index, url: "https://example.com/\(id)")))
}

@Test func newWindowAppearsOnceActiveResolvesItAndKeepsItsTabs() {
    var reducer = otReducer([otCreated(11, window: 5, index: 1), otCreated(10, window: 5, index: 0)])
    #expect(reducer.inventory.windows.isEmpty)

    reducer.receive(otMessage(.active(windowId: 5, incognito: false, tab: otTab(10, 0))))

    #expect(otTabIDs(reducer) == [[10, 11]])
    #expect(reducer.inventory.windows[0].incognito == false)
}

@Test func newIncognitoWindowTabsAreNeverListed() {
    var reducer = otReducer([otCreated(10, window: 5, index: 0), otCreated(11, window: 5, index: 1)])
    reducer.receive(otMessage(.active(windowId: 5, incognito: true, tab: otTab(10, 0))))
    let note = tabFixtureNote(id: tabFixtureID("001"), anchor: tabFixtureWebAnchor("https://example.com/11"))

    #expect(reducer.inventory.windows.first?.incognito == true)
    #expect(LibraryTabGroups.openTabs(notes: [note], inventory: reducer.inventory, rules: []).isEmpty)
}

@Test func tabMovedIntoNewWindowKeepsTheTabAndSourceIncognito() {
    var reducer = otReducer([
        otMessage(.inventory(windows: [otWindow(1, incognito: true, tabs: [otTab(1, 0), otTab(2, 1)])])),
        otMessage(.tabMoved(tabId: 2, windowId: 9, index: 0)),
    ])

    #expect(otTabIDs(reducer) == [[1], [2]])
    #expect(reducer.inventory.windows.map(\.incognito) == [true, true])

    reducer.receive(otCreated(3, window: 9, index: 1))
    #expect(otTabIDs(reducer) == [[1], [2, 3]])
}
