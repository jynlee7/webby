import Foundation
import Testing
@testable import Webby
import WebbyCore

private let chromeFrame = CGRect(x: 20, y: 40, width: 1000, height: 700)
private let profile = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

/// "Just this tab" notes through the shared controller: creation, navigation, close,
/// promote and demote, and the restore after a Chrome restart.
@MainActor
@Suite struct NotesControllerTabNotesTests {
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    @MainActor struct Harness {
        let store: NoteStore
        let browser: BrowserMonitor
        let feed: OpenTabsFeed
        let controller: NotesController
        let directory: URL
        let clock: Clock
        let session: SessionBox

        func send(_ message: ExtensionMessage, connection: Int = 1) {
            let event = BridgeEvent.message(connection: connection, profile: profile, message)
            feed.receive(event)
            browser.receive(event)
            controller.receiveBridgeEvent(event)
            controller.layout()
        }

        func close() {
            controller.windows.values.forEach { $0.close() }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    final class SessionBox {
        var value: String? = "100@1"
    }

    private func window(_ url: String, tabID: Int = 1, windowID: Int = 1, focused: Bool = true) -> BridgeWindow {
        BridgeWindow(id: windowID, focused: focused, incognito: false,
                     bounds: BridgeWindowBounds(left: 20, top: 40, width: 1000, height: 700),
                     tabs: [BridgeTab(id: tabID, index: 0, active: true, url: url, title: "Tab \(tabID)")])
    }

    private func harness(notes: [Note] = []) -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebbyTabNotes-\(UUID().uuidString)", isDirectory: true)
        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        for note in notes { _ = store.add(note) }
        let session = SessionBox()
        let clock = Clock()
        let permission = AccessibilityPermission()
        let browser = BrowserMonitor(sessionIdentity: { session.value })
        let feed = OpenTabsFeed(sessionIdentity: { session.value ?? OpenTabsInventory.unknownSession })
        let monitor = ContextMonitor(permission: permission, browser: browser)
        monitor.app = ContextMonitor.FrontApp(bundleID: BrowserSession.bundleID, pid: 1, name: "Google Chrome")
        monitor.windowFrame = chromeFrame
        let controller = NotesController(store: store, monitor: monitor, permission: permission, themes: .fallback,
                                         now: { clock.now })
        controller.tabs.chromeSession = { session.value }
        controller.tabs.openTabs = { feed.inventory }
        controller.tabs.liveTab = { browser.tab($0) }
        return Harness(store: store, browser: browser, feed: feed, controller: controller, directory: directory,
                       clock: clock, session: session)
    }

    private func hello(_ h: Harness, connection: Int = 1) {
        h.send(.hello(BridgeHello(profile: profile, extVersion: "1", incognitoAllowed: false)), connection: connection)
    }

    @Test func aTabWithoutAPageDefaultsToJustThisTabAndFollowsThreeSites() throws {
        let h = harness()
        defer { h.close() }
        hello(h)
        h.send(.inventory(windows: [window("chrome://newtab/")]))
        h.controller.newNote()

        let note = try #require(h.store.notes.first)
        #expect(note.anchor == nil)
        #expect(note.tab?.tabID == 1)
        #expect(note.tab?.session == "100@1")
        #expect(note.source?.url == "chrome://newtab/")
        #expect(WorkspaceResolver.resolve(note, workspaces: []) == .implicit(.tabsWithoutPage))
        let model = try #require(h.controller.windows[note.id]?.model)
        #expect(model.scopes.map(\.title) == ["Just this tab", "This app"])
        #expect(model.selectedScope == 0)

        for url in ["https://a.example/1", "https://b.example/2", "https://c.example/3"] {
            h.send(.tabUpdated(tabId: 1, url: url, title: nil))
            #expect(h.controller.windows[note.id] != nil)
        }
        let stored = try #require(h.store.note(id: note.id))
        #expect(stored.tab?.lastURL == "https://c.example/3")
        #expect(stored.revision == note.revision)
        #expect(stored.updatedAt == note.updatedAt)

        h.send(.tabClosed(tabId: 1, windowClosing: false))
        #expect(h.controller.windows[note.id] == nil)
        #expect(h.store.note(id: note.id)?.tab?.closedAt == h.clock.now)
        #expect(LibraryTabGroups.closedTabs(notes: h.store.notes).map(\.note.id) == [note.id])
    }

    @Test func aPageNoteIsDemotedAndPromotedWithOneRevisionEach() throws {
        let h = harness()
        defer { h.close() }
        hello(h)
        h.send(.inventory(windows: [window("https://a.example/docs")]))
        h.controller.newNote()
        let note = try #require(h.store.notes.first)
        let page = try #require(PageURL(string: "https://a.example/docs", queryRules: QueryRules.builtIns))
        #expect(note.anchor == .web(page: page, scope: .page))
        let model = try #require(h.controller.windows[note.id]?.model)
        let tabIndex = try #require(model.scopes.firstIndex { $0.choice == .thisTab })

        model.chooseScope(at: tabIndex)
        let demoted = try #require(h.store.note(id: note.id))
        #expect(demoted.tab?.tabID == 1)
        #expect(demoted.anchor == note.anchor) // the workspace stays put
        #expect(demoted.revision == note.revision + 1)
        #expect(h.controller.windows[note.id]?.model.selectedScope == tabIndex)

        // It now follows the tab off the page.
        h.send(.tabUpdated(tabId: 1, url: "https://b.example/elsewhere", title: nil))
        #expect(h.controller.windows[note.id] != nil)
        let siteIndex = try #require(h.controller.windows[note.id]?.model.scopes.firstIndex { $0.title == "Whole site" })
        h.controller.windows[note.id]?.model.chooseScope(at: siteIndex)
        let promoted = try #require(h.store.note(id: note.id))
        #expect(promoted.tab == nil)
        #expect(promoted.anchor == .web(page: try #require(PageURL(string: "https://b.example/elsewhere", queryRules: QueryRules.builtIns)), scope: .site))
        #expect(promoted.revision == demoted.revision + 1)
    }

    @Test func chromeRestartRestoresOneMatchWithABadgeTheUserCanKeep() throws {
        let h = harness()
        defer { h.close() }
        hello(h)
        h.send(.inventory(windows: [window("chrome://newtab/")]))
        h.controller.newNote()
        let note = try #require(h.store.notes.first)
        h.send(.tabUpdated(tabId: 1, url: "https://a.example/docs?id=4#top", title: "Docs"))
        #expect(h.store.note(id: note.id)?.tab?.lastURL == "https://a.example/docs?id=4")

        // Chrome quits: not an edit.
        h.controller.chromeTerminated(session: "100@1")
        h.session.value = "200@2"
        let closed = try #require(h.store.note(id: note.id))
        #expect(closed.tab?.closedAt != nil)
        #expect(closed.tab?.pendingRestore == true)
        #expect(closed.revision == note.revision)

        // The new run restores the tab under a new ID.
        hello(h, connection: 2)
        h.send(.inventory(windows: [window("https://a.example/docs?id=4", tabID: 70, windowID: 9)]), connection: 2)
        h.controller.runDueRestoreChecks(at: h.clock.now.addingTimeInterval(1))
        #expect(h.store.note(id: note.id)?.tab?.closedAt != nil) // not settled yet
        h.controller.runDueRestoreChecks(at: h.clock.now.addingTimeInterval(3))
        let restored = try #require(h.store.note(id: note.id))
        #expect(restored.tab?.tabID == 70)
        #expect(restored.tab?.session == "200@2")
        #expect(TabBindingReconciler.isRestored(restored.tab))
        #expect(h.controller.restoreOutcome(note.id) == .rebound)
        h.controller.layout()
        let model = try #require(h.controller.windows[note.id]?.model)
        #expect(model.restored)

        // Navigation leaves the badge; Keep clears it.
        h.send(.tabUpdated(tabId: 70, url: "https://a.example/next", title: nil))
        #expect(h.controller.windows[note.id]?.model.restored == true)
        model.onKeepRestored()
        #expect(h.store.note(id: note.id)?.tab?.pendingRestore == false)
        #expect(!model.restored)
        #expect(h.store.note(id: note.id)?.revision == note.revision)
    }

    @Test func twoMatchingTabsLeaveTheNoteInClosedTabs() throws {
        let h = harness()
        defer { h.close() }
        hello(h)
        h.send(.inventory(windows: [window("https://a.example/docs")]))
        h.controller.newNote()
        let note = try #require(h.store.notes.first)
        let tabIndex = try #require(h.controller.windows[note.id]?.model.scopes.firstIndex { $0.choice == .thisTab })
        h.controller.windows[note.id]?.model.chooseScope(at: tabIndex)

        h.controller.chromeTerminated(session: "100@1")
        h.session.value = "200@2"
        hello(h, connection: 2)
        h.send(.inventory(windows: [window("https://a.example/docs", tabID: 70, windowID: 9),
                                    window("https://a.example/docs", tabID: 80, windowID: 10, focused: false)]), connection: 2)
        h.controller.runDueRestoreChecks(at: h.clock.now.addingTimeInterval(3))
        let stored = try #require(h.store.note(id: note.id))
        #expect(stored.tab?.closedAt != nil)
        #expect(stored.tab?.pendingRestore == false)
        #expect(h.controller.restoreOutcome(note.id) == .ambiguous)
        #expect(h.controller.windows[note.id] == nil)
    }

    @Test func editingARestoredNoteAcceptsTheRestoreAndReattachIsBookkeeping() throws {
        let binding = TabBinding(browser: BrowserSession.bundleID, profile: profile, session: "100@1", tabID: 1,
                                 windowID: 1, index: 0, lastURL: "https://a.example/docs", pendingRestore: true)
        let note = Note(tab: binding, text: "Before", revision: 2, frame: NoteFrame(x: 0, y: 0, width: 240, height: 160), placement: .window)
        let h = harness(notes: [note])
        defer { h.close() }
        h.controller.startTabTracking()
        hello(h)
        h.send(.inventory(windows: [window("https://a.example/docs")]))
        #expect(h.controller.windows[note.id]?.model.restored == true)
        h.controller.updateLibraryText(id: note.id, text: "After")
        #expect(h.store.note(id: note.id)?.tab?.pendingRestore == false)
        #expect(h.store.note(id: note.id)?.revision == 3)

        // Closed, then reattached to the last verified tab without a new revision.
        h.send(.tabClosed(tabId: 1, windowClosing: false))
        h.send(.inventory(windows: [window("https://a.example/other", tabID: 5)]))
        #expect(h.controller.reattachTarget(for: note.id)?.ref.tabID == 5)
        h.controller.reattachToLastTab(note.id)
        let reattached = try #require(h.store.note(id: note.id))
        #expect(reattached.tab?.tabID == 5)
        #expect(reattached.tab?.closedAt == nil)
        #expect(reattached.revision == 3)
    }

    @Test func aStaleSessionAtLaunchWaitsForRestoreWithoutAnEdit() throws {
        let binding = TabBinding(browser: BrowserSession.bundleID, profile: profile, session: "50@0", tabID: 1,
                                 windowID: 1, index: 0, lastURL: "https://a.example/docs")
        let note = Note(tab: binding, frame: NoteFrame(), placement: .window)
        let h = harness(notes: [note])
        defer { h.close() }
        h.controller.startTabTracking()
        #expect(h.store.note(id: note.id)?.tab?.closedAt == h.clock.now)
        #expect(h.store.note(id: note.id)?.tab?.pendingRestore == true)
        #expect(h.store.note(id: note.id)?.revision == note.revision)
    }

    @Test func theLibraryShowsClosedTabsAndPutsThemBack() throws {
        let h = harness()
        defer { h.close() }
        hello(h)
        h.send(.inventory(windows: [window("chrome://newtab/")]))
        h.controller.newNote()
        let note = try #require(h.store.notes.first)
        h.send(.tabUpdated(tabId: 1, url: "https://a.example/docs/intro?token=secret", title: ""))
        let model = LibraryModel(controller: h.controller, openTabs: h.feed)

        var live = try #require(h.store.note(id: note.id))
        #expect(LibraryNotePresentation.scopeDescription(for: live) == "Just this tab: Tab 1")
        live.tab?.lastTitle = nil
        #expect(LibraryNotePresentation.scopeDescription(for: live) == "Just this tab: a.example")
        #expect(!LibraryNotePresentation.scopeDescription(for: live).contains("secret"))
        #expect(LibraryNotePresentation.closedTabStatus(live.tab, outcome: nil) == nil)

        h.send(.tabClosed(tabId: 1, windowClosing: false))
        let closed = try #require(h.store.note(id: note.id))
        #expect(LibraryNotePresentation.scopeDescription(for: closed) == "Closed tab: Tab 1")
        #expect(LibraryNotePresentation.closedTabStatus(closed.tab, outcome: nil) == "Tab closed")
        #expect(LibraryNotePresentation.closedTabStatus(closed.tab, outcome: .ambiguous) == "More than one tab matched")
        var waiting = closed.tab
        waiting?.pendingRestore = true
        #expect(LibraryNotePresentation.closedTabStatus(waiting, outcome: nil) == "Waiting for Chrome to restore tabs")

        // Reattach targets the last verified tab, named by its title.
        #expect(model.reattachTargetTitle(for: note.id) == nil)
        h.send(.inventory(windows: [window("https://b.example/", tabID: 4)]))
        #expect(model.reattachTargetTitle(for: note.id) == "Tab 4")

        // Stick to Page offers the tab's last page and promotes with one revision.
        let promotions = model.promotions(for: closed)
        #expect(promotions.map(\.title) == ["This page", "/docs/intro and below", "/docs and below", "Whole site"])
        model.attach(id: note.id, anchor: try #require(promotions.last?.anchor), workspace: nil)
        let promoted = try #require(h.store.note(id: note.id))
        #expect(promoted.tab == nil)
        #expect(promoted.anchor == promotions.last?.anchor)
        #expect(promoted.revision == closed.revision + 1)
        #expect(model.promotions(for: promoted).isEmpty)
        var newTab = closed
        newTab.tab?.lastURL = "chrome://newtab/"
        #expect(model.promotions(for: newTab).isEmpty)
    }
}
