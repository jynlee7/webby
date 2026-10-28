import Foundation
import Testing
@testable import WebbyCore

private func groupIdentities(_ groups: [LibraryOpenTabGroup]) -> [String] {
    groups.map {
        [
            $0.tab.browser,
            $0.tab.profile,
            $0.tab.session,
            String($0.windowOrder),
            String($0.tab.windowID),
            String($0.index),
            String($0.tab.tabID),
        ].joined(separator: "/")
    }
}

@Test func openTabsKeepsHiddenAndEphemeralNotesAndSkipsEmptyTabs() throws {
    let anchor = try #require(tabFixtureWebAnchor("https://example.com/a"))
    let note = tabFixtureNote(anchor: anchor, hidden: true, ephemeral: true)
    let inventory = tabFixtureInventory([
        tabFixtureWindow(tabs: [
            tabFixtureTab(tabID: 1, index: 0, url: "https://example.com/a"),
            tabFixtureTab(tabID: 2, index: 1, url: "https://example.com/b"),
        ]),
    ])

    let groups = LibraryTabGroups.openTabs(notes: [note], inventory: inventory, rules: [])

    #expect(groups.count == 1)
    #expect(groups.first?.tab.tabID == 1)
    #expect(groups.first?.notes.count == 1)
    #expect(groups.first?.notes.first?.isHidden == true)
    #expect(groups.first?.notes.first?.note.ephemeral == true)
}

@Test func openTabsExcludesAppAnchorsButKeepsTabBoundNotes() {
    let appNote = tabFixtureNote(
        id: tabFixtureID("010"),
        anchor: .app(bundleID: "com.google.Chrome")
    )
    let boundNote = tabFixtureNote(id: tabFixtureID("011"), tab: tabFixtureBinding(tabID: 1))
    let inventory = tabFixtureInventory([
        tabFixtureWindow(tabs: [
            tabFixtureTab(tabID: 1, index: 0, url: "https://example.com/a"),
        ]),
    ])

    let groups = LibraryTabGroups.openTabs(
        notes: [appNote, boundNote],
        inventory: inventory,
        rules: []
    )

    #expect(groups.count == 1)
    #expect(tabFixtureNoteIDs(groups.first?.notes ?? []) == ["011"])
}

@Test func openTabsDeduplicatesAnchoredAndBoundNotesAndPrefersTheBinding() throws {
    let anchor = try #require(tabFixtureWebAnchor("https://example.com/a"))
    let note = tabFixtureNote(
        id: tabFixtureID("020"),
        anchor: anchor,
        tab: tabFixtureBinding(tabID: 1)
    )
    let inventory = tabFixtureInventory([
        tabFixtureWindow(tabs: [
            tabFixtureTab(tabID: 1, index: 0, url: "https://example.com/a"),
            tabFixtureTab(tabID: 2, index: 1, url: "https://example.com/a"),
        ]),
    ])

    let groups = LibraryTabGroups.openTabs(notes: [note], inventory: inventory, rules: [])

    #expect(groups.count == 1)
    #expect(groups.first?.tab.tabID == 1)
    #expect(tabFixtureNoteIDs(groups.first?.notes ?? []) == ["020"])
}

@Test func openTabsShowsAnchoredNotesUnderEveryMatchingTab() throws {
    let anchor = try #require(tabFixtureWebAnchor("https://example.com/start", scope: .site))
    let note = tabFixtureNote(id: tabFixtureID("030"), anchor: anchor)
    let inventory = tabFixtureInventory([
        tabFixtureWindow(tabs: [
            tabFixtureTab(tabID: 1, index: 0, url: "https://example.com/a"),
            tabFixtureTab(tabID: 2, index: 1, url: "https://example.com/b"),
        ]),
    ])

    let groups = LibraryTabGroups.openTabs(notes: [note], inventory: inventory, rules: [])

    #expect(groups.count == 2)
    for group in groups {
        #expect(tabFixtureNoteIDs(group.notes) == ["030"])
    }
}

@Test func openTabsRetainsAnchoredQueryKeysAfterTheirRuleIsRemoved() throws {
    let anchor = try #require(tabFixtureWebAnchor(
        "https://youtube.com/watch?v=a",
        rules: [QueryRule(host: "youtube.com", key: "v")]
    ))
    let note = tabFixtureNote(id: tabFixtureID("040"), anchor: anchor)
    let inventory = tabFixtureInventory([
        tabFixtureWindow(tabs: [
            tabFixtureTab(tabID: 1, index: 0, url: "https://youtube.com/watch?v=a"),
            tabFixtureTab(tabID: 2, index: 1, url: "https://youtube.com/watch?v=b"),
        ]),
    ])

    let groups = LibraryTabGroups.openTabs(notes: [note], inventory: inventory, rules: [])

    #expect(groups.count == 1)
    #expect(groups.first?.tab.tabID == 1)
    #expect(tabFixtureNoteIDs(groups.first?.notes ?? []) == ["040"])
}

@Test func openTabsIsolatesBrowserProfileSessionAndTabIdentity() {
    let matching = tabFixtureNote(id: tabFixtureID("051"), tab: tabFixtureBinding(tabID: 7))
    let otherBrowser = tabFixtureNote(
        id: tabFixtureID("052"),
        tab: tabFixtureBinding(browser: "com.microsoft.edgemac", tabID: 7)
    )
    let otherProfile = tabFixtureNote(
        id: tabFixtureID("053"),
        tab: tabFixtureBinding(profile: "profile-b", tabID: 7)
    )
    let otherSession = tabFixtureNote(
        id: tabFixtureID("054"),
        tab: tabFixtureBinding(session: "200@2026-02-02", tabID: 7)
    )
    let otherTab = tabFixtureNote(id: tabFixtureID("055"), tab: tabFixtureBinding(tabID: 8))
    let inventory = tabFixtureInventory([
        tabFixtureWindow(tabs: [
            tabFixtureTab(tabID: 7, index: 0, url: "https://example.com/a"),
        ]),
    ])

    let groups = LibraryTabGroups.openTabs(
        notes: [matching, otherBrowser, otherProfile, otherSession, otherTab],
        inventory: inventory,
        rules: []
    )

    #expect(groups.count == 1)
    #expect(tabFixtureNoteIDs(groups.first?.notes ?? []) == ["051"])
}

@Test func openTabsFollowsTabNavigationAndWindowMoves() throws {
    let bound = tabFixtureNote(
        id: tabFixtureID("060"),
        tab: tabFixtureBinding(tabID: 7, windowID: 1, lastURL: "https://example.com/a")
    )
    let anchored = tabFixtureNote(
        id: tabFixtureID("061"),
        anchor: try #require(tabFixtureWebAnchor("https://example.com/a"))
    )
    let inventory = tabFixtureInventory([
        tabFixtureWindow(windowID: 99, tabs: [
            tabFixtureTab(tabID: 7, index: 0, url: "https://example.com/b"),
        ]),
    ])

    let groups = LibraryTabGroups.openTabs(
        notes: [bound, anchored],
        inventory: inventory,
        rules: []
    )

    #expect(groups.count == 1)
    #expect(groups.first?.tab.windowID == 99)
    #expect(tabFixtureNoteIDs(groups.first?.notes ?? []) == ["060"])
}

@Test func openTabsKeepsBoundNotesWhenTheURLIsUnsupportedOrMissing() throws {
    let unsupported = tabFixtureNote(
        id: tabFixtureID("070"),
        tab: tabFixtureBinding(tabID: 1)
    )
    let missing = tabFixtureNote(id: tabFixtureID("071"), tab: tabFixtureBinding(tabID: 2))
    let anchored = tabFixtureNote(
        id: tabFixtureID("072"),
        anchor: try #require(tabFixtureWebAnchor("https://example.com/a"))
    )
    let inventory = tabFixtureInventory([
        tabFixtureWindow(tabs: [
            tabFixtureTab(tabID: 1, index: 0, url: "chrome://newtab"),
            tabFixtureTab(tabID: 2, index: 1, url: nil),
        ]),
    ])

    let groups = LibraryTabGroups.openTabs(
        notes: [unsupported, missing, anchored],
        inventory: inventory,
        rules: []
    )

    #expect(groups.count == 2)
    #expect(tabFixtureNoteIDs(groups[0].notes) == ["070"])
    #expect(tabFixtureNoteIDs(groups[1].notes) == ["071"])
}

@Test func openTabsSkipsIncognitoWindows() throws {
    let ordinary = tabFixtureNote(id: tabFixtureID("080"), tab: tabFixtureBinding(tabID: 1))
    let incognitoBound = tabFixtureNote(id: tabFixtureID("081"), tab: tabFixtureBinding(tabID: 2))
    let incognitoAnchored = tabFixtureNote(
        id: tabFixtureID("082"),
        anchor: try #require(tabFixtureWebAnchor("https://private.example/start", scope: .site))
    )
    let inventory = tabFixtureInventory([
        tabFixtureWindow(tabs: [
            tabFixtureTab(tabID: 1, index: 0, url: "https://example.com/a"),
        ]),
        tabFixtureWindow(windowID: 2, incognito: true, tabs: [
            tabFixtureTab(tabID: 2, index: 0, url: "https://private.example/a"),
        ]),
    ])

    let groups = LibraryTabGroups.openTabs(
        notes: [ordinary, incognitoBound, incognitoAnchored],
        inventory: inventory,
        rules: []
    )

    #expect(groups.count == 1)
    #expect(groups.first?.tab.tabID == 1)
    #expect(tabFixtureNoteIDs(groups.first?.notes ?? []) == ["080"])
}

@Test func closedTabsIncludesHiddenAndEphemeralAndIgnoresOpenOrPendingRestoreAlone() {
    let hiddenClosed = tabFixtureNote(
        id: tabFixtureID("090"),
        tab: tabFixtureBinding(tabID: 1, closedAt: tabFixtureDate(100)),
        hidden: true
    )
    let ephemeralClosed = tabFixtureNote(
        id: tabFixtureID("091"),
        tab: tabFixtureBinding(tabID: 2, closedAt: tabFixtureDate(200), pendingRestore: true),
        ephemeral: true
    )
    let openPending = tabFixtureNote(
        id: tabFixtureID("092"),
        tab: tabFixtureBinding(tabID: 3, pendingRestore: true)
    )
    let openPlain = tabFixtureNote(id: tabFixtureID("093"), tab: tabFixtureBinding(tabID: 4))
    let trashedClosed = tabFixtureNote(
        id: tabFixtureID("094"),
        tab: tabFixtureBinding(tabID: 5, closedAt: tabFixtureDate(300)),
        trashedAt: tabFixtureDate(300)
    )

    let entries = LibraryTabGroups.closedTabs(notes: [
        hiddenClosed,
        ephemeralClosed,
        openPending,
        openPlain,
        trashedClosed,
    ])

    #expect(entries.map { $0.note.id } == [ephemeralClosed.id, hiddenClosed.id])
    #expect(entries[0].closedAt == tabFixtureDate(200))
    #expect(entries[0].note.note.ephemeral)
    #expect(entries[1].note.isHidden)
}

@Test func closedTabsSortsByClosedAtDescendingThenUUID() {
    let notes = [
        tabFixtureNote(id: tabFixtureID("003"), tab: tabFixtureBinding(
            tabID: 1,
            closedAt: tabFixtureDate(200)
        )),
        tabFixtureNote(id: tabFixtureID("001"), tab: tabFixtureBinding(
            tabID: 2,
            closedAt: tabFixtureDate(200)
        )),
        tabFixtureNote(id: tabFixtureID("002"), tab: tabFixtureBinding(
            tabID: 3,
            closedAt: tabFixtureDate(100)
        )),
        tabFixtureNote(id: tabFixtureID("004"), tab: tabFixtureBinding(
            tabID: 4,
            closedAt: tabFixtureDate(300)
        )),
    ]

    let entries = LibraryTabGroups.closedTabs(notes: notes)

    #expect(entries.map { $0.note.id.uuidString.suffix(3).lowercased() } == [
        "004", "001", "003", "002",
    ])
}

@Test func closedTabsDoesNotInferClosureFromInventoryAbsenceOrUseAnchors() throws {
    let open = tabFixtureNote(
        id: tabFixtureID("100"),
        anchor: try #require(tabFixtureWebAnchor("https://example.com/a")),
        tab: tabFixtureBinding(tabID: 1)
    )
    let closedWithAnchor = tabFixtureNote(
        id: tabFixtureID("101"),
        anchor: try #require(tabFixtureWebAnchor("https://example.com/a")),
        tab: tabFixtureBinding(tabID: 2, closedAt: tabFixtureDate(100))
    )
    let inventoryWithoutEitherTab = tabFixtureInventory([])

    let openGroups = LibraryTabGroups.openTabs(
        notes: [open, closedWithAnchor],
        inventory: inventoryWithoutEitherTab,
        rules: []
    )
    let closed = LibraryTabGroups.closedTabs(notes: [open, closedWithAnchor])

    #expect(openGroups.isEmpty)
    #expect(closed.map { $0.note.id } == [closedWithAnchor.id])
}

@Test func openTabsOrdersGroupsByIdentityWithoutMovingFocusedOrActiveTabsFirst() throws {
    let anchor = try #require(tabFixtureWebAnchor("https://example.com/x", scope: .site))
    let note = tabFixtureNote(anchor: anchor)
    let inventory = tabFixtureInventory([
        tabFixtureWindow(browser: "b", profile: "a", session: "a", windowID: 1, order: 0, focused: true, tabs: [
            tabFixtureTab(tabID: 30, index: 0, active: true, url: "https://example.com/x"),
        ]),
        tabFixtureWindow(browser: "a", profile: "b", session: "z", windowID: 1, order: 2, tabs: [
            tabFixtureTab(tabID: 1, index: 0, url: "https://example.com/x"),
        ]),
        tabFixtureWindow(browser: "a", profile: "a", session: "z", windowID: 1, order: 9, tabs: [
            tabFixtureTab(tabID: 1, index: 0, url: "https://example.com/x"),
        ]),
        tabFixtureWindow(browser: "a", profile: "b", session: "z", windowID: 9, order: 1, tabs: [
            tabFixtureTab(tabID: 1, index: 0, url: "https://example.com/x"),
        ]),
        tabFixtureWindow(browser: "a", profile: "b", session: "z", windowID: 10, order: 1, focused: true, tabs: [
            tabFixtureTab(tabID: 20, index: 1, active: true, url: "https://example.com/x"),
            tabFixtureTab(tabID: 21, index: 0, url: "https://example.com/x"),
            tabFixtureTab(tabID: 19, index: 0, url: "https://example.com/x"),
        ]),
    ])

    let groups = LibraryTabGroups.openTabs(notes: [note], inventory: inventory, rules: [])

    #expect(groupIdentities(groups) == [
        "a/a/z/9/1/0/1",
        "a/b/z/1/9/0/1",
        "a/b/z/1/10/0/19",
        "a/b/z/1/10/0/21",
        "a/b/z/1/10/1/20",
        "a/b/z/2/1/0/1",
        "b/a/a/0/1/0/30",
    ])
}

@Test func openTabsOrdersNotesByUpdatedDescendingThenUUID() throws {
    let anchor = try #require(tabFixtureWebAnchor("https://example.com/x", scope: .site))
    let notes = [
        tabFixtureNote(id: tabFixtureID("004"), anchor: anchor, updatedAt: tabFixtureDate(100)),
        tabFixtureNote(id: tabFixtureID("003"), anchor: anchor, updatedAt: tabFixtureDate(200)),
        tabFixtureNote(id: tabFixtureID("001"), anchor: anchor, updatedAt: tabFixtureDate(200)),
        tabFixtureNote(id: tabFixtureID("002"), anchor: anchor, updatedAt: tabFixtureDate(300)),
    ]
    let inventory = tabFixtureInventory([
        tabFixtureWindow(tabs: [
            tabFixtureTab(tabID: 1, index: 0, url: "https://example.com/x"),
        ]),
    ])

    let groups = LibraryTabGroups.openTabs(notes: notes, inventory: inventory, rules: [])

    #expect(tabFixtureNoteIDs(groups.first?.notes ?? []) == ["002", "001", "003", "004"])
}

@Test func tabGroupingIsDeterministicForShuffledInventoryAndNotes() throws {
    let anchor = try #require(tabFixtureWebAnchor("https://example.com/start", scope: .site))
    let notes = [
        tabFixtureNote(id: tabFixtureID("001"), anchor: anchor, updatedAt: tabFixtureDate(100)),
        tabFixtureNote(id: tabFixtureID("002"), tab: tabFixtureBinding(tabID: 1), updatedAt: tabFixtureDate(200)),
        tabFixtureNote(id: tabFixtureID("003"), tab: tabFixtureBinding(tabID: 3), updatedAt: tabFixtureDate(300)),
        tabFixtureNote(id: tabFixtureID("004"), tab: tabFixtureBinding(tabID: 2), updatedAt: tabFixtureDate(50)),
    ]
    let windows = [
        tabFixtureWindow(windowID: 10, order: 0, tabs: [
            tabFixtureTab(tabID: 1, index: 0, url: "https://example.com/a"),
            tabFixtureTab(tabID: 2, index: 1, url: "https://example.com/b"),
        ]),
        tabFixtureWindow(windowID: 20, order: 1, tabs: [
            tabFixtureTab(tabID: 3, index: 0, url: "https://example.com/a"),
        ]),
    ]
    let inventories = [
        tabFixtureInventory(windows),
        tabFixtureInventory(windows.reversed()),
        tabFixtureInventory(windows.map { window in
            tabFixtureWindow(
                browser: window.browser,
                profile: window.profile,
                session: window.session,
                appBundleID: window.appBundleID,
                windowID: window.windowID,
                order: window.order,
                focused: window.focused,
                incognito: window.incognito,
                tabs: Array(window.tabs.reversed())
            )
        }),
    ]
    let noteOrders = [
        notes,
        notes.reversed(),
        [notes[2], notes[0], notes[3], notes[1]],
        [notes[3], notes[1], notes[0], notes[2]],
    ]

    let expectedGroups = LibraryTabGroups.openTabs(
        notes: notes,
        inventory: inventories[0],
        rules: []
    )
    let expectedClosed = LibraryTabGroups.closedTabs(notes: notes)

    #expect(!expectedGroups.isEmpty)
    #expect(expectedClosed.isEmpty)

    for inventory in inventories {
        for orderedNotes in noteOrders {
            #expect(LibraryTabGroups.openTabs(
                notes: Array(orderedNotes),
                inventory: inventory,
                rules: []
            ) == expectedGroups)
            #expect(LibraryTabGroups.closedTabs(notes: Array(orderedNotes)) == expectedClosed)
        }
    }
}

@Test func tabGroupingDoesNotMutateNotesInventoryOrWorkspaceFields() throws {
    let anchor = try #require(tabFixtureWebAnchor("https://example.com/a"))
    let notes = [
        tabFixtureNote(
            id: tabFixtureID("110"),
            anchor: anchor,
            workspaceOverride: tabFixtureID("999"),
            source: NoteSource(url: "https://example.com/a", title: "Example")
        ),
        tabFixtureNote(
            id: tabFixtureID("111"),
            tab: tabFixtureBinding(tabID: 1, closedAt: tabFixtureDate(100))
        ),
    ]
    let inventory = tabFixtureInventory([
        tabFixtureWindow(tabs: [
            tabFixtureTab(tabID: 1, index: 0, url: "https://example.com/a"),
        ]),
    ])
    let originalNotes = notes
    let originalInventory = inventory

    _ = LibraryTabGroups.openTabs(notes: notes, inventory: inventory, rules: [])
    _ = LibraryTabGroups.closedTabs(notes: notes)

    #expect(notes == originalNotes)
    #expect(inventory == originalInventory)
}
