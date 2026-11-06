import CoreGraphics
import Foundation
import Testing
@testable import WebbyCore

/// The re-attach cases of plan §5.1.4, within one Chrome run and across runs.
@Suite struct TabBindingReconcilerTests {
    private let chrome = OpenTabsInventory.bundleID
    private let profile = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
    private let otherProfile = "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d"
    private let oldSession = ChromeSessionIdentity.session(processIdentifier: 100, launchDate: Date(timeIntervalSince1970: 1_000))
    private let newSession = ChromeSessionIdentity.session(processIdentifier: 200, launchDate: Date(timeIntervalSince1970: 2_000))
    private let created = Date(timeIntervalSince1970: 1_800_000_000)
    private let later = Date(timeIntervalSince1970: 1_800_000_600)

    private func binding(tabID: Int = 7, windowID: Int = 1, index: Int = 0, url: String = "https://a.example/start",
                         session: String? = nil, profile: String? = nil,
                         closedAt: Date? = nil, pendingRestore: Bool = false) -> TabBinding {
        TabBinding(browser: chrome, profile: profile ?? self.profile, session: session ?? oldSession, tabID: tabID,
                   windowID: windowID, index: index, lastURL: url, lastTitle: "Start",
                   closedAt: closedAt, pendingRestore: pendingRestore)
    }

    private func note(_ tab: TabBinding, text: String = "Research") -> Note {
        Note(tab: tab, text: text, revision: 3, source: NoteSource(url: tab.lastURL, title: "Start"),
             frame: NoteFrame(x: 1, y: 2, width: 300, height: 200), placement: .window,
             createdAt: created, updatedAt: created)
    }

    private func message(_ message: ExtensionMessage, profile: String? = nil, connection: Int = 1) throws -> BridgeEvent {
        // Replay the wire encoding, not only the constructed enum.
        .message(connection: connection, profile: profile ?? self.profile, try ExtensionMessage.decode(message.encoded()))
    }

    private func tab(_ id: Int, _ url: String, index: Int = 0, title: String = "Tab", active: Bool = false) -> BridgeTab {
        BridgeTab(id: id, index: index, active: active, url: url, title: title)
    }

    private func window(_ id: Int, _ tabs: [BridgeTab], incognito: Bool = false, focused: Bool = false) -> BridgeWindow {
        BridgeWindow(id: id, focused: focused, incognito: incognito,
                     bounds: BridgeWindowBounds(left: 0, top: 0, width: 800, height: 600), tabs: tabs)
    }

    /// Applies updates the way the app does: bookkeeping only.
    private func apply(_ updates: [TabBindingUpdate], to store: NoteStore) {
        for update in updates { store.updateBinding(id: update.noteID) { $0 = update.binding } }
    }

    private func applied(_ updates: [TabBindingUpdate], to notes: [Note]) -> [Note] {
        notes.map { note in
            guard let update = updates.first(where: { $0.noteID == note.id }) else { return note }
            var changed = note
            changed.tab = update.binding
            return changed
        }
    }

    private func withStore(_ body: (NoteStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(NoteStore(fileURL: directory.appendingPathComponent("notes.json"), now: created))
    }

    private func liveContext(tabID: Int, windowID: Int = 1, session: String? = nil) -> Context {
        Context(appBundleID: chrome, tab: TabRef(browser: chrome, profile: profile, session: session ?? oldSession,
                                                  tabID: tabID, windowID: windowID))
    }

    // MARK: Within one Chrome run

    @Test func threeSitesInOneTabKeepTheNoteWithoutEditingIt() throws {
        try withStore { store in
            let research = note(binding(url: "https://a.example/start"))
            #expect(store.add(research))
            var reconciler = TabBindingReconciler()
            for url in ["https://b.example/search?q=one", "https://c.example/docs#intro"] {
                apply(reconciler.receive(try message(.tabUpdated(tabId: 7, url: url, title: "Page")),
                                         notes: store.notes, session: oldSession, now: later), to: store)
            }
            let stored = try #require(store.note(id: research.id))
            #expect(stored.tab?.lastURL == "https://c.example/docs")
            #expect(stored.tab?.lastTitle == "Page")
            #expect(stored.revision == 3)
            #expect(stored.updatedAt == created)
            #expect(NoteVisibility.isAttached(stored, to: liveContext(tabID: 7)))
            #expect(!NoteVisibility.isAttached(stored, to: liveContext(tabID: 8)))
            // The workspace stays with the site where the note was created.
            #expect(WorkspaceResolver.resolve(stored, workspaces: []) == .implicit(.host(name: "a.example")))
        }
    }

    @Test func loadingTabsNeverEraseTheLastURLOrTitle() throws {
        var reconciler = TabBindingReconciler()
        let research = note(binding())
        let updates = reconciler.receive(try message(.tabUpdated(tabId: 7, url: "", title: "")),
                                         notes: [research], session: oldSession, now: later)
        #expect(updates.isEmpty)
        let inventory = reconciler.receive(try message(.inventory(windows: [window(1, [tab(7, "", index: 2, title: "")])])),
                                           notes: [research], session: oldSession, now: later)
        #expect(inventory.first?.binding.lastURL == "https://a.example/start")
        #expect(inventory.first?.binding.lastTitle == "Start")
        #expect(inventory.first?.binding.index == 2)
    }

    @Test func closingTheTabMovesItsNotesToClosedTabs() throws {
        var reconciler = TabBindingReconciler()
        let first = note(binding())
        let second = note(binding(tabID: 9))
        let updates = reconciler.receive(try message(.tabClosed(tabId: 7, windowClosing: false)),
                                         notes: [first, second], session: oldSession, now: later)
        #expect(updates.map(\.noteID) == [first.id])
        #expect(updates.first?.binding.closedAt == later)
        #expect(updates.first?.binding.pendingRestore == false)
        #expect(reconciler.recentWindowClosures.isEmpty)
        let notes = applied(updates, to: [first, second])
        #expect(LibraryTabGroups.closedTabs(notes: notes).map(\.note.id) == [first.id])
        #expect(!NoteVisibility.isAttached(notes[0], to: liveContext(tabID: 7)))
    }

    @Test func anInventoryWithoutTheTabClosesItAndRemembersTheClosure() throws {
        var reconciler = TabBindingReconciler()
        let research = note(binding())
        let updates = reconciler.receive(try message(.inventory(windows: [window(1, [tab(3, "https://x.example")])])),
                                         notes: [research], session: oldSession, now: later)
        #expect(updates.first?.binding.closedAt == later)
        #expect(reconciler.recentWindowClosures[research.id] == later)
        // A closure with its window is remembered the same way.
        var other = TabBindingReconciler()
        _ = other.receive(try message(.tabClosed(tabId: 7, windowClosing: true)), notes: [research], session: oldSession, now: later)
        #expect(other.recentWindowClosures[research.id] == later)
    }

    @Test func replacedTabsKeepTheirNotesThroughTheFollowingInventory() throws {
        var reconciler = TabBindingReconciler()
        var notes = [note(binding(tabID: 7)), note(binding(tabID: 7), text: "Second note")]
        for (added, removed) in [(8, 7), (9, 8)] {
            notes = applied(reconciler.receive(try message(.tabReplaced(added: added, removed: removed)),
                                               notes: notes, session: oldSession, now: later), to: notes)
        }
        #expect(notes.allSatisfy { $0.tab?.tabID == 9 })
        let inventory = reconciler.receive(try message(.inventory(windows: [window(1, [tab(9, "https://a.example/next")])])),
                                           notes: notes, session: oldSession, now: later)
        notes = applied(inventory, to: notes)
        #expect(notes.allSatisfy { $0.tab?.closedAt == nil && $0.tab?.lastURL == "https://a.example/next" })
    }

    @Test func movedTabsKeepTheirNotesAndFollowTheWindow() throws {
        var reconciler = TabBindingReconciler()
        var notes = [note(binding(tabID: 7, windowID: 1))]
        notes = applied(reconciler.receive(try message(.tabMoved(tabId: 7, windowId: 4, index: 2)),
                                           notes: notes, session: oldSession, now: later), to: notes)
        #expect(notes[0].tab?.windowID == 4)
        #expect(notes[0].tab?.index == 2)
        #expect(NoteVisibility.isAttached(notes[0], to: liveContext(tabID: 7, windowID: 4)))
        // onMoved within a window arrives as an inventory.
        notes = applied(reconciler.receive(try message(.inventory(windows: [window(4, [tab(1, "https://z.example"), tab(7, "https://a.example/start", index: 1)])])),
                                           notes: notes, session: oldSession, now: later), to: notes)
        #expect(notes[0].tab?.index == 1)
        #expect(notes[0].tab?.closedAt == nil)
    }

    @Test func otherProfilesSessionsAndUnknownSessionsChangeNothing() throws {
        var reconciler = TabBindingReconciler()
        let research = note(binding())
        let closed = try message(.tabClosed(tabId: 7, windowClosing: false))
        #expect(reconciler.receive(try message(.tabClosed(tabId: 7, windowClosing: false), profile: otherProfile),
                                   notes: [research], session: oldSession, now: later).isEmpty)
        #expect(reconciler.receive(closed, notes: [research], session: newSession, now: later).isEmpty)
        #expect(reconciler.receive(closed, notes: [research], session: nil, now: later).isEmpty)
        #expect(reconciler.receive(closed, notes: [research], session: OpenTabsInventory.unknownSession, now: later).isEmpty)
        #expect(reconciler.receive(.disconnected(connection: 1, profile: profile), notes: [research], session: oldSession, now: later).isEmpty)
        #expect(reconciler.receive(.dropped(connection: 1, reason: "reload"), notes: [research], session: oldSession, now: later).isEmpty)
        let ref = TabRef(browser: chrome, profile: profile, session: OpenTabsInventory.unknownSession, tabID: 7, windowID: 1)
        #expect(TabBindingReconciler.binding(for: ref, tab: tab(7, "https://a.example")) == nil)
    }

    // MARK: Webby quits and relaunches while Chrome keeps running

    @Test func relaunchingWebbyRebindsByTabIDAndRefreshesTheURL() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.json")
        let research = note(binding())
        let first = NoteStore(fileURL: url, now: created)
        #expect(first.add(research))
        try first.save()

        let relaunched = NoteStore(fileURL: url, now: later)
        #expect(relaunched.note(id: research.id) == research)
        // Chrome is still the same run, so the launch pass changes nothing.
        #expect(TabBindingReconciler.closeStaleSessions(notes: relaunched.notes, current: oldSession, now: later).isEmpty)
        var reconciler = TabBindingReconciler()
        #expect(reconciler.receive(try message(.hello(BridgeHello(profile: profile, extVersion: "1", incognitoAllowed: false))),
                                   notes: relaunched.notes, session: oldSession, now: later).isEmpty)
        // The tab navigated while Webby was down.
        apply(reconciler.receive(try message(.inventory(windows: [window(2, [tab(7, "https://d.example/moved", index: 3)])])),
                                 notes: relaunched.notes, session: oldSession, now: later), to: relaunched)
        let stored = try #require(relaunched.note(id: research.id))
        #expect(stored.tab?.closedAt == nil)
        #expect(stored.tab?.lastURL == "https://d.example/moved")
        #expect(stored.tab?.windowID == 2)
        #expect(stored.revision == research.revision)
        #expect(stored.updatedAt == research.updatedAt)
        try relaunched.save()
        #expect(NoteStore(fileURL: url).note(id: research.id) == stored)
    }

    // MARK: Chrome quits

    @Test func quittingChromeIsNotAnEditAndUpgradesClosuresFromTheQuit() throws {
        try withStore { store in
            let open = note(binding(tabID: 7))
            let closedWithWindow = note(binding(tabID: 8))
            let closedEarlier = note(binding(tabID: 9))
            let closedByUser = note(binding(tabID: 10))
            let otherRun = note(binding(tabID: 11, session: newSession))
            for item in [open, closedWithWindow, closedEarlier, closedByUser, otherRun] { #expect(store.add(item)) }
            var reconciler = TabBindingReconciler()
            apply(reconciler.receive(try message(.tabClosed(tabId: 9, windowClosing: true)), notes: store.notes, session: oldSession, now: later), to: store)
            apply(reconciler.receive(try message(.tabClosed(tabId: 10, windowClosing: false)), notes: store.notes, session: oldSession, now: later.addingTimeInterval(9)), to: store)
            apply(reconciler.receive(try message(.tabClosed(tabId: 8, windowClosing: true)), notes: store.notes, session: oldSession, now: later.addingTimeInterval(9)), to: store)

            let quit = later.addingTimeInterval(10)
            apply(reconciler.chromeTerminated(session: oldSession, notes: store.notes, now: quit), to: store)
            #expect(store.note(id: open.id)?.tab?.closedAt == quit)
            #expect(store.note(id: open.id)?.tab?.pendingRestore == true)
            #expect(store.note(id: closedWithWindow.id)?.tab?.pendingRestore == true)
            #expect(store.note(id: closedEarlier.id)?.tab?.pendingRestore == false)
            #expect(store.note(id: closedByUser.id)?.tab?.pendingRestore == false)
            #expect(store.note(id: otherRun.id)?.tab == otherRun.tab)
            #expect(reconciler.recentWindowClosures.isEmpty)
            #expect(store.notes.allSatisfy { $0.revision == 3 && $0.updatedAt == created })
        }
    }

    @Test func aSessionThatEndedWhileWebbyWasDownWaitsForRestore() throws {
        let stale = note(binding(session: oldSession))
        let current = note(binding(tabID: 8, session: newSession))
        let closed = note(binding(tabID: 9, closedAt: created))
        let updates = TabBindingReconciler.closeStaleSessions(notes: [stale, current, closed], current: newSession, now: later)
        #expect(updates.map(\.noteID) == [stale.id])
        #expect(updates.first?.binding.closedAt == later)
        #expect(updates.first?.binding.pendingRestore == true)
        // Chrome not running counts as a different run.
        #expect(TabBindingReconciler.closeStaleSessions(notes: [stale, current], current: nil, now: later).count == 2)
    }

    @Test func aReadOnlyStoreTakesNoBindingWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.json")
        try Data(#"{"version":99,"notes":[]}"#.utf8).write(to: url)
        let store = NoteStore(fileURL: url)
        guard case .readOnly = store.mode else { Issue.record("expected a read-only store"); return }
        #expect(!store.updateBinding(id: UUID()) { $0.closedAt = later })
    }

    // MARK: Chrome restarts with session restore

    private func inventory(_ tabs: [(Int, String)], window: Int = 10, profile: String? = nil, incognito: Bool = false,
                           session: String? = nil) -> LibraryInventoryWindow {
        LibraryInventoryWindow(browser: chrome, profile: profile ?? self.profile, session: session ?? newSession,
                               appBundleID: chrome, windowID: window, order: 0, focused: false, incognito: incognito,
                               tabs: tabs.enumerated().map { LibraryInventoryTab(tabID: $1.0, index: $0, url: $1.1, title: "Restored \($1.0)") })
    }

    private func pending(tabID: Int = 7, url: String = "https://a.example/docs?id=4") -> Note {
        note(binding(tabID: tabID, url: url, closedAt: created, pendingRestore: true))
    }

    @Test func exactlyOneMatchReattachesWithTheRestoredState() throws {
        let research = pending()
        let result = TabRestore.evaluate(notes: [research], profile: profile, session: newSession,
                                         inventory: LibraryInventory(windows: [inventory([(50, "https://a.example/other"), (51, "https://a.example/docs?id=4#part")])]))
        #expect(result.outcomes[research.id] == .rebound)
        let restored = try #require(result.updates.first?.binding)
        #expect(restored.session == newSession)
        #expect(restored.tabID == 51)
        #expect(restored.windowID == 10)
        #expect(restored.index == 1)
        #expect(restored.closedAt == nil)
        #expect(restored.pendingRestore)
        #expect(restored.lastTitle == "Restored 51")
        #expect(TabBindingReconciler.isRestored(restored))
        let notes = applied(result.updates, to: [research])
        #expect(NoteVisibility.isAttached(notes[0], to: liveContext(tabID: 51, windowID: 10, session: newSession)))
        #expect(LibraryTabGroups.closedTabs(notes: notes).isEmpty)
    }

    @Test func twoMatchesOrNoneStayInClosedTabs() throws {
        let research = pending()
        let twice = TabRestore.evaluate(notes: [research], profile: profile, session: newSession,
                                        inventory: LibraryInventory(windows: [inventory([(50, "https://a.example/docs?id=4")]),
                                                                              inventory([(60, "https://a.example/docs?id=4")], window: 11)]))
        #expect(twice.outcomes[research.id] == .ambiguous)
        #expect(twice.updates.first?.binding.closedAt == created)
        #expect(twice.updates.first?.binding.pendingRestore == false)
        #expect(LibraryTabGroups.closedTabs(notes: applied(twice.updates, to: [research])).count == 1)

        // A different query is a different page; the comparison is exact.
        let none = TabRestore.evaluate(notes: [research], profile: profile, session: newSession,
                                       inventory: LibraryInventory(windows: [inventory([(50, "https://a.example/docs?id=5")])]))
        #expect(none.outcomes[research.id] == .unmatched)
        #expect(none.updates.first?.binding.pendingRestore == false)
    }

    @Test func incognitoOtherProfilesAndOtherSessionsAreNeverCandidates() throws {
        let research = pending()
        let url = "https://a.example/docs?id=4"
        let result = TabRestore.evaluate(notes: [research], profile: profile, session: newSession, inventory: LibraryInventory(windows: [
            inventory([(50, url)], incognito: true),
            inventory([(51, url)], window: 11, profile: otherProfile),
            inventory([(52, url)], window: 12, session: oldSession),
        ]))
        #expect(result.outcomes[research.id] == .unmatched)
        // Notes of another profile are not evaluated for this one.
        #expect(TabRestore.evaluate(notes: [research], profile: otherProfile, session: newSession,
                                    inventory: LibraryInventory(windows: [inventory([(51, url)], profile: otherProfile)])).updates.isEmpty)
        // The unknown session never evaluates.
        #expect(TabRestore.evaluate(notes: [research], profile: profile, session: OpenTabsInventory.unknownSession,
                                    inventory: LibraryInventory(windows: [inventory([(50, url)], session: OpenTabsInventory.unknownSession)])).updates.isEmpty)
    }

    @Test func notesOfOneOldTabMoveTogetherAndAContestedTabTakesNeither() throws {
        let first = pending(tabID: 7)
        let second = pending(tabID: 7)
        let together = TabRestore.evaluate(notes: [first, second], profile: profile, session: newSession,
                                           inventory: LibraryInventory(windows: [inventory([(50, "https://a.example/docs?id=4")])]))
        #expect(together.outcomes.values.allSatisfy { $0 == .rebound })
        #expect(together.updates.map(\.binding.tabID) == [50, 50])

        // Two old tabs on the same URL and one restored tab: no guess.
        let rival = pending(tabID: 8)
        let contested = TabRestore.evaluate(notes: [first, rival], profile: profile, session: newSession,
                                            inventory: LibraryInventory(windows: [inventory([(50, "https://a.example/docs?id=4")])]))
        #expect(contested.outcomes[first.id] == .ambiguous)
        #expect(contested.outcomes[rival.id] == .ambiguous)
        #expect(contested.updates.allSatisfy { $0.binding.closedAt != nil && !$0.binding.pendingRestore })
    }

    @Test func onlyPendingBindingsFromEarlierRunsAreEvaluated() throws {
        let closedByUser = note(binding(closedAt: created, pendingRestore: false))
        let open = note(binding(session: newSession))
        let result = TabRestore.evaluate(notes: [closedByUser, open], profile: profile, session: newSession,
                                         inventory: LibraryInventory(windows: [inventory([(7, "https://a.example/start")])]))
        #expect(result.updates.isEmpty)
    }

    @Test func keepingOrEditingClearsTheBadgeButNavigationDoesNot() throws {
        var restored = binding(session: newSession)
        restored.pendingRestore = true
        #expect(TabBindingReconciler.acknowledgingRestore(restored)?.pendingRestore == false)
        #expect(TabBindingReconciler.acknowledgingRestore(binding()) == nil)
        #expect(TabBindingReconciler.acknowledgingRestore(binding(closedAt: created, pendingRestore: true)) == nil)

        var reconciler = TabBindingReconciler()
        let updates = reconciler.receive(try message(.tabUpdated(tabId: 7, url: "https://b.example", title: nil)),
                                         notes: [note(restored)], session: newSession, now: later)
        #expect(updates.first?.binding.pendingRestore == true)
        // Closing the tab again ends the restored state.
        let closed = reconciler.receive(try message(.tabClosed(tabId: 7, windowClosing: false)),
                                        notes: [note(restored)], session: newSession, now: later)
        #expect(closed.first?.binding.pendingRestore == false)
    }

    @Test func fullRestartRoundTripThroughBothReducers() throws {
        // Chrome quits, a new run restores one tab on the URL, and the shared session
        // string ties the inventory to the new bindings.
        var reconciler = TabBindingReconciler()
        var notes = [note(binding())]
        notes = applied(reconciler.chromeTerminated(session: oldSession, notes: notes, now: later), to: notes)
        var feed = OpenTabsInventory(session: newSession)
        let hello = try message(.hello(BridgeHello(profile: profile, extVersion: "1", incognitoAllowed: false)), connection: 2)
        feed.receive(hello)
        feed.receive(try message(.inventory(windows: [window(30, [tab(70, "https://a.example/start", title: "Start again")])]), connection: 2))
        let result = TabRestore.evaluate(notes: notes, profile: profile, session: newSession, inventory: feed.inventory)
        notes = applied(result.updates, to: notes)
        #expect(notes[0].tab?.tabID == 70)
        #expect(TabBindingReconciler.isRestored(notes[0].tab))

        var session = BrowserSession()
        session.setIdentity(newSession)
        session.receive(hello)
        session.receive(try message(.inventory(windows: [window(30, [tab(70, "https://a.example/start", active: true)], focused: true)]), connection: 2))
        let context = session.context(focusedFrame: CGRect(x: 0, y: 0, width: 800, height: 600), queryRules: QueryRules.builtIns)
        #expect(context.tab?.session == feed.inventory.windows.first?.session)
        #expect(NoteVisibility.isAttached(notes[0], to: context))
    }

    @Test func replayedRestoreReattachesTabsOfBackgroundWindows() throws {
        // The extension's own output for a restore that opens a second window in the
        // background (background.test.js produces the same file).
        let messages = try JSONDecoder().decode([ExtensionMessage].self, from: fixture("browser-session-restore-synthetic"))
        let docs = pending(tabID: 7, url: "https://a.example/docs?id=4")
        let pricing = pending(tabID: 8, url: "https://b.example/pricing")
        var feed = OpenTabsInventory(session: newSession)
        for (offset, message) in messages.enumerated() {
            feed.receive(.message(connection: 3, profile: profile, message))
            if offset == 2 {
                // Before the window's inventory its tabs are unknown, so they can't match.
                let early = TabRestore.evaluate(notes: [docs, pricing], profile: profile, session: newSession, inventory: feed.inventory)
                #expect(early.outcomes[docs.id] == .rebound)
                #expect(early.outcomes[pricing.id] == .unmatched)
            }
        }
        let result = TabRestore.evaluate(notes: [docs, pricing], profile: profile, session: newSession, inventory: feed.inventory)
        #expect(result.outcomes[docs.id] == .rebound)
        #expect(result.outcomes[pricing.id] == .rebound)
        #expect(result.updates.first { $0.noteID == pricing.id }?.binding.tabID == 20)
        #expect(result.updates.first { $0.noteID == pricing.id }?.binding.windowID == 2)
    }

    // MARK: Restore timing

    @Test func restoreWaitsForQuietThenRunsOncePerProfileAndRun() {
        var schedule = RestoreSchedule()
        let start = later
        schedule.hello(profile: profile, connection: 1, now: start)
        #expect(schedule.takeDue(now: start).isEmpty) // no session yet
        schedule.setSession(newSession)
        schedule.hello(profile: profile, connection: 1, now: start)
        // Nothing is due until the profile's tabs are known.
        #expect(schedule.nextDeadline == nil)
        #expect(schedule.takeDue(now: start.addingTimeInterval(60)).isEmpty)
        schedule.activity(profile: profile, now: start, inventory: true)
        #expect(schedule.nextDeadline == start.addingTimeInterval(3))
        #expect(schedule.takeDue(now: start.addingTimeInterval(2)).isEmpty)
        schedule.activity(profile: profile, now: start.addingTimeInterval(2))
        #expect(schedule.takeDue(now: start.addingTimeInterval(4)).isEmpty)
        #expect(schedule.takeDue(now: start.addingTimeInterval(5)) == [profile])
        schedule.hello(profile: profile, connection: 2, now: start.addingTimeInterval(6))
        schedule.activity(profile: profile, now: start.addingTimeInterval(6), inventory: true)
        #expect(schedule.takeDue(now: start.addingTimeInterval(60)).isEmpty)
        #expect(schedule.nextDeadline == nil)
        // A new Chrome run checks again.
        schedule.setSession(oldSession)
        schedule.hello(profile: profile, connection: 3, now: start)
        schedule.activity(profile: profile, now: start, inventory: true)
        #expect(schedule.takeDue(now: start.addingTimeInterval(3)) == [profile])
    }

    @Test func restoreRunsAtTheCapWhileTabsKeepArriving() {
        var schedule = RestoreSchedule()
        schedule.setSession(newSession)
        schedule.hello(profile: profile, connection: 1, now: later)
        schedule.activity(profile: profile, now: later, inventory: true)
        for second in stride(from: 1, through: 29, by: 2) {
            schedule.activity(profile: profile, now: later.addingTimeInterval(TimeInterval(second)))
            #expect(schedule.takeDue(now: later.addingTimeInterval(TimeInterval(second))).isEmpty)
        }
        #expect(schedule.nextDeadline == later.addingTimeInterval(30))
        #expect(schedule.takeDue(now: later.addingTimeInterval(30)) == [profile])
    }

    /// Greptile 4488242865: a disconnect before the check used to consume it against an
    /// empty inventory.
    @Test func aDisconnectBeforeTheCheckKeepsItForTheNextConnection() {
        var schedule = RestoreSchedule()
        schedule.setSession(newSession)
        schedule.hello(profile: profile, connection: 1, now: later)
        schedule.activity(profile: profile, now: later, inventory: true)
        // A late disconnect from another connection, or for another profile, changes nothing.
        schedule.disconnected(connection: 9, profile: profile)
        schedule.disconnected(connection: 1, profile: otherProfile)
        #expect(schedule.nextDeadline == later.addingTimeInterval(3))
        schedule.disconnected(connection: 1, profile: profile)
        #expect(schedule.takeDue(now: later.addingTimeInterval(10)).isEmpty)
        #expect(schedule.nextDeadline == nil)
        // The reconnected profile still gets its one check.
        schedule.hello(profile: profile, connection: 2, now: later.addingTimeInterval(10))
        schedule.activity(profile: profile, now: later.addingTimeInterval(10), inventory: true)
        #expect(schedule.takeDue(now: later.addingTimeInterval(13)) == [profile])
        // A dropped connection cancels every profile it spoke for.
        var dropped = RestoreSchedule()
        dropped.setSession(newSession)
        dropped.hello(profile: profile, connection: 4, now: later)
        dropped.activity(profile: profile, now: later, inventory: true)
        dropped.disconnected(connection: 4, profile: nil)
        #expect(dropped.takeDue(now: later.addingTimeInterval(30)).isEmpty)
    }

    // MARK: Scope choices

    @Test func justThisTabIsTheDefaultWithoutAPageIdentity() throws {
        let ref = TabRef(browser: chrome, profile: profile, session: oldSession, tabID: 7, windowID: 1)
        let newTab = NoteScope.choices(for: Context(appBundleID: chrome, tab: ref))
        #expect(newTab.map(\.title) == ["Just this tab", "This app"])
        #expect(newTab.first?.choice == .thisTab)
        let page = try #require(PageURL(string: "https://a.example/docs/intro", queryRules: QueryRules.builtIns))
        #expect(NoteScope.choices(for: Context(appBundleID: chrome, page: page, tab: ref)).map(\.title)
            == ["This page", "/docs/intro and below", "/docs and below", "Whole site", "Just this tab", "This app"])
        // No live tab (incognito, unverified, disconnected): no tab choice.
        #expect(NoteScope.choices(for: Context(appBundleID: chrome, page: page)).map(\.title).contains("Just this tab") == false)
        #expect(NoteScope.choices(for: Context(appBundleID: chrome)).map(\.title) == ["This app"])

        let tabNote = note(binding())
        #expect(NoteScope.index(of: tabNote, in: newTab) == 0)
        let appNote = Note(anchor: .app(bundleID: chrome), frame: NoteFrame(), placement: .window)
        #expect(NoteScope.index(of: appNote, in: newTab) == 1)
    }

    @Test func promotionsComeFromTheLastURL() {
        #expect(NoteScope.promotions(forURL: "https://a.example/docs/intro?x=1", queryRules: QueryRules.builtIns).map(\.title)
            == ["This page", "/docs/intro and below", "/docs and below", "Whole site"])
        #expect(NoteScope.promotions(forURL: "chrome://newtab/", queryRules: QueryRules.builtIns).isEmpty)
    }

    @Test func aVerifiedTabWithoutAPageStillReportsTheTab() throws {
        var session = BrowserSession()
        session.setIdentity(oldSession)
        session.receive(try message(.hello(BridgeHello(profile: profile, extVersion: "1", incognitoAllowed: true))))
        session.receive(try message(.inventory(windows: [window(1, [tab(7, "chrome://newtab/", index: 4, active: true)], focused: true)])))
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let context = session.context(focusedFrame: frame, queryRules: QueryRules.builtIns)
        #expect(context.page == nil)
        let ref = try #require(context.tab)
        let created = try #require(session.tab(ref).flatMap { TabBindingReconciler.binding(for: ref, tab: $0) })
        #expect(created.index == 4)
        #expect(created.lastURL == "chrome://newtab/")
        // Incognito still reports nothing.
        session.receive(try message(.inventory(windows: [window(1, [tab(7, "chrome://newtab/", active: true)], incognito: true, focused: true)])))
        #expect(session.context(focusedFrame: frame, queryRules: QueryRules.builtIns) == Context(appBundleID: chrome))
        #expect(session.tab(ref) == nil)
    }

    @Test func reattachingIsBookkeepingAndStaysInTheProfile() {
        let closed = binding(closedAt: created)
        let ref = TabRef(browser: chrome, profile: profile, session: newSession, tabID: 70, windowID: 3)
        let updated = TabBindingReconciler.reattaching(closed, to: ref, tab: tab(70, "", index: 2, title: ""))
        #expect(updated?.tabID == 70)
        #expect(updated?.session == newSession)
        #expect(updated?.closedAt == nil)
        #expect(updated?.pendingRestore == false)
        #expect(updated?.lastURL == closed.lastURL)
        #expect(updated?.lastTitle == closed.lastTitle)
        let other = TabRef(browser: chrome, profile: otherProfile, session: newSession, tabID: 70, windowID: 3)
        #expect(TabBindingReconciler.reattaching(closed, to: other, tab: tab(70, "https://a.example")) == nil)
    }
}
