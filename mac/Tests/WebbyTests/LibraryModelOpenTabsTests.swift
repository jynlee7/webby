import Foundation
import Testing
@testable import Webby
import WebbyCore

private let openTabsNow = Date(timeIntervalSince1970: 1_800_000_000)
private let openTabsSession = "100@2026-01-01"

private func openTabsNote(_ id: String, url: String) -> Note {
    Note(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000\(id)")!,
        anchor: PageURL(string: url, queryRules: []).map { .web(page: $0, scope: .page) },
        text: "note \(id)",
        frame: NoteFrame(),
        placement: .screen,
        createdAt: openTabsNow,
        updatedAt: openTabsNow
    )
}

@MainActor
private func openTabsController(_ store: NoteStore) -> NotesController {
    let permission = AccessibilityPermission()
    return NotesController(
        store: store,
        monitor: ContextMonitor(permission: permission),
        permission: permission,
        themes: .fallback,
        now: { openTabsNow }
    )
}

private func openTabsInventoryEvent(_ urls: [String]) -> BridgeEvent {
    let tabs = urls.enumerated().map { index, url in
        BridgeTab(id: index + 1, index: index, active: index == 0, url: url, title: "Tab \(index + 1)")
    }
    return .message(
        connection: 1,
        profile: "profile-a",
        .inventory(windows: [BridgeWindow(id: 1, focused: true, incognito: false, tabs: tabs)])
    )
}

@MainActor
@Suite struct LibraryModelOpenTabsTests {
    @Test func openTabsSectionListsOnlyTabsWithNotesAndFollowsLiveEvents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebbyOpenTabs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        let noted = openTabsNote("001", url: "https://example.com/a")
        let other = openTabsNote("002", url: "https://nowhere.example/")
        #expect(store.add(noted))
        #expect(store.add(other))

        let feed = OpenTabsFeed(sessionIdentity: { openTabsSession })
        let model = LibraryModel(controller: openTabsController(store), openTabs: feed)
        #expect(model.openTabGroups.isEmpty)

        feed.receive(openTabsInventoryEvent(["https://example.com/a", "https://example.com/b"]))
        #expect(model.openTabGroups.map(\.tab.tabID) == [1])
        #expect(model.openTabNotes.map(\.id) == [noted.id])

        model.selectOpenTabs()
        #expect(model.showsOpenTabs)
        #expect(model.visibleNotes.map(\.id) == [noted.id])
        model.setSelection([noted.id])
        #expect(model.selectedNoteID == noted.id)

        feed.receive(.message(connection: 1, profile: "profile-a", .tabClosed(tabId: 1, windowClosing: false)))
        #expect(model.openTabGroups.isEmpty)
        #expect(model.selectedNoteID == nil)

        model.select(section: .all)
        #expect(!model.showsOpenTabs)
        #expect(model.visibleNotes.count == 2)
    }

    @Test func eventsThatLeaveTheInventoryUnchangedDoNotNotify() {
        let feed = OpenTabsFeed(sessionIdentity: { openTabsSession })
        var notifications = 0
        feed.onChange = { notifications += 1 }

        feed.receive(openTabsInventoryEvent(["https://example.com/a"]))
        feed.receive(openTabsInventoryEvent(["https://example.com/a"]))
        feed.receive(.connected(connection: 2))

        #expect(notifications == 1)
    }
}
