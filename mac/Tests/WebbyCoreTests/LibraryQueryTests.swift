import Foundation
import Testing
@testable import WebbyCore

private let lqNow = Date(timeIntervalSinceReferenceDate: 1_000_000_000)
private let lqDay: TimeInterval = 86_400

private func lqUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
}

private func lqDate(_ offset: TimeInterval) -> Date {
    lqNow.addingTimeInterval(offset)
}

private func lqWebAnchor(_ host: String) -> Anchor {
    .web(page: PageURL(host: host, path: "/"), scope: .page)
}

private func lqTab(closedAt: TimeInterval? = nil, pendingRestore: Bool = false) -> TabBinding {
    TabBinding(
        browser: "chrome",
        profile: "Default",
        session: "session",
        tabID: 1,
        windowID: 1,
        index: 0,
        lastURL: "https://example.com/",
        closedAt: closedAt.map(lqDate),
        pendingRestore: pendingRestore
    )
}

private func lqNote(
    _ value: Int,
    text: String = "note",
    updated: TimeInterval = 0,
    created: TimeInterval? = nil,
    pinned: TimeInterval? = nil,
    trashed: TimeInterval? = nil,
    closed: TimeInterval? = nil,
    tab: TabBinding? = nil,
    anchor: Anchor? = nil,
    override: UUID? = nil,
    source: NoteSource? = nil,
    hidden: Bool = false,
    collapsed: Bool = false,
    excluded: Bool = false,
    ephemeral: Bool = false
) -> Note {
    let binding = tab ?? (closed.map { _ in lqTab(closedAt: closed) })
    return Note(
        id: lqUUID(value),
        anchor: anchor,
        tab: binding,
        workspaceOverride: override,
        text: text,
        source: source,
        frame: NoteFrame(),
        placement: .window,
        collapsed: collapsed,
        hidden: hidden,
        pinnedAt: pinned.map(lqDate),
        trashedAt: trashed.map(lqDate),
        excludedFromAgent: excluded,
        createdAt: lqDate(created ?? updated),
        updatedAt: lqDate(updated),
        ephemeral: ephemeral
    )
}

private func lqRecord(
    _ value: Int,
    title: String? = nil,
    keys: [WorkspaceKey] = [],
    pinned: Bool = false
) -> WorkspaceRecord {
    WorkspaceRecord(
        id: lqUUID(value),
        title: title,
        keys: keys,
        pinned: pinned,
        createdAt: Date(timeIntervalSinceReferenceDate: 0)
    )
}

private func lqIDs(_ notes: [LibraryNote]) -> [UUID] {
    notes.map(\.id)
}

private func lqDestinations(_ groups: [LibraryWorkspaceGroup]) -> [WorkspaceDestination] {
    groups.map(\.destination)
}

@Test func emptyLibraryHasStableSectionsAndCounts() {
    let result = LibraryQuery.evaluate(notes: [], workspaces: [], now: lqNow)

    #expect(LibrarySection.allCases == [
        .inbox,
        .closedTabs,
        .pinned,
        .recent,
        .all,
        .workspaces,
        .tags,
        .trash,
    ])
    #expect(result.sectionOrder == LibrarySection.allCases)
    #expect(LibraryResult.sectionOrder == LibrarySection.allCases)
    #expect(result.inbox.isEmpty)
    #expect(result.closedTabs.isEmpty)
    #expect(result.pinned.isEmpty)
    #expect(result.recent.isEmpty)
    #expect(result.all.isEmpty)
    #expect(result.workspaces.isEmpty)
    #expect(result.tags.isEmpty)
    #expect(result.trash.isEmpty)
    #expect(result.counts.values.allSatisfy { $0 == 0 })
}

@Test func shuffledNotesProduceTheSameResultForBothWorkspaceOrders() {
    let workspaces = [
        lqRecord(901, title: "Example", keys: [.host(name: "example.com")]),
        lqRecord(902, title: "Empty", keys: [.host(name: "empty.example.com")]),
    ]
    let notes = [
        lqNote(1, text: "#inbox", updated: -10),
        lqNote(2, text: "#tag", updated: -20, pinned: -1),
        lqNote(3, text: "#tag", updated: -30, closed: -5),
        lqNote(4, text: "#trash #tag", updated: -40, pinned: -2, trashed: -1, closed: -4),
        lqNote(5, text: "#tag", updated: -50, anchor: lqWebAnchor("example.com")),
        lqNote(
            6,
            text: "#tag",
            updated: -60,
            anchor: lqWebAnchor("other.example.com"),
            override: lqUUID(901)
        ),
        lqNote(7, text: "#tag", updated: -70, tab: lqTab(), source: NoteSource(url: "chrome://newtab")),
    ]
    let shuffles = [
        notes,
        Array(notes.reversed()),
        [notes[3], notes[1], notes[6], notes[0], notes[5], notes[2], notes[4]],
        [notes[6], notes[5], notes[4], notes[3], notes[2], notes[1], notes[0]],
    ]

    for order in WorkspaceOrder.allCases {
        let expected = LibraryQuery.evaluate(
            notes: notes,
            workspaces: workspaces,
            now: lqNow,
            workspaceOrder: order
        )
        for shuffled in shuffles {
            let actual = LibraryQuery.evaluate(
                notes: shuffled,
                workspaces: workspaces,
                now: lqNow,
                workspaceOrder: order
            )
            #expect(actual == expected)
        }
    }
}

@Test func equalDatesBreakTiesByLowercaseUUID() {
    let result = LibraryQuery.evaluate(
        notes: [
            lqNote(3, updated: -1),
            lqNote(1, updated: -1),
            lqNote(2, updated: -1),
            lqNote(6, updated: -20, pinned: -2),
            lqNote(4, updated: -20, pinned: -2),
            lqNote(5, updated: -20, pinned: -2),
            lqNote(9, updated: -30, closed: -3),
            lqNote(7, updated: -30, closed: -3),
            lqNote(8, updated: -30, closed: -3),
        ],
        workspaces: [],
        now: lqNow
    )

    #expect(lqIDs(result.all) == [1, 2, 3, 4, 5, 6, 7, 8, 9].map(lqUUID))
    #expect(lqIDs(result.pinned) == [4, 5, 6].map(lqUUID))
    #expect(lqIDs(result.closedTabs) == [7, 8, 9].map(lqUUID))
}

@Test func recentUsesInclusiveFourteenDayWindowAndCapsAtOneHundred() {
    let boundary = LibraryQuery.evaluate(
        notes: [
            lqNote(1, updated: 0),
            lqNote(2, updated: -14 * lqDay),
            lqNote(3, updated: -14 * lqDay - 1),
            lqNote(4, updated: 1),
        ],
        workspaces: [],
        now: lqNow
    )

    #expect(lqIDs(boundary.recent) == [lqUUID(1), lqUUID(2)])
    #expect(lqIDs(boundary.all) == [lqUUID(4), lqUUID(1), lqUUID(2), lqUUID(3)])

    let many = (0..<101).map { lqNote(1_000 + $0, updated: -Double($0)) }
    let capped = LibraryQuery.evaluate(notes: many, workspaces: [], now: lqNow)

    #expect(capped.recent.count == 100)
    #expect(lqIDs(capped.recent) == (0..<100).map { lqUUID(1_000 + $0) })
    #expect(capped.recent.last?.note.updatedAt == lqDate(-99))
    #expect(!capped.recent.contains { $0.id == lqUUID(1_100) })
    #expect(capped.all.count == 101)
}

@Test func hiddenCollapsedEphemeralAndExcludedNotesStayInOrdinarySections() {
    let notes = [
        lqNote(1, text: "#keep", updated: -5, hidden: true),
        lqNote(2, text: "#keep", updated: -4, collapsed: true),
        lqNote(3, text: "#keep", updated: -3, ephemeral: true),
        lqNote(4, text: "#keep", updated: -2, excluded: true),
        lqNote(5, text: "#keep", updated: -1, pinned: -1, hidden: true, ephemeral: true),
    ]
    let result = LibraryQuery.evaluate(notes: notes, workspaces: [], now: lqNow)

    #expect(lqIDs(result.all) == [5, 4, 3, 2, 1].map(lqUUID))
    #expect(lqIDs(result.inbox) == [5, 4, 3, 2, 1].map(lqUUID))
    #expect(lqIDs(result.pinned) == [lqUUID(5)])
    #expect(result.tags.count == 1)
    #expect(result.tags.first?.searchKey == "keep")
    #expect(result.tags.first?.count == 5)
    #expect(result.trash.isEmpty)
}

@Test func trashIsSeparatedFromEveryOrdinarySection() {
    let workspaces = [lqRecord(901, title: "Example", keys: [.host(name: "example.com")])]
    let notes = [
        lqNote(
            1,
            text: "#tag",
            updated: -30,
            pinned: -2,
            trashed: -2,
            closed: -3,
            anchor: lqWebAnchor("example.com")
        ),
        lqNote(2, text: "#tag", updated: -20, trashed: -1, ephemeral: true),
        lqNote(3, text: "#tag", updated: -10),
    ]
    let result = LibraryQuery.evaluate(notes: notes, workspaces: workspaces, now: lqNow)

    #expect(lqIDs(result.trash) == [lqUUID(2), lqUUID(1)])
    #expect(lqIDs(result.all) == [lqUUID(3)])
    #expect(lqIDs(result.inbox) == [lqUUID(3)])
    #expect(result.closedTabs.isEmpty)
    #expect(result.pinned.isEmpty)
    #expect(lqIDs(result.recent) == [lqUUID(3)])
    #expect(result.tags.count == 1)
    #expect(lqIDs(result.tags[0].notes) == [lqUUID(3)])
    #expect(result.workspaces.count == 1)
    #expect(result.workspaces[0].record?.id == lqUUID(901))
    #expect(result.workspaces[0].notes.isEmpty)
}

@Test func inboxUsesWorkspaceResolverAndKeepsDanglingOverrides() {
    let workspaces = [lqRecord(901, title: "Example", keys: [.host(name: "example.com")])]
    let notes = [
        lqNote(1, updated: -7),
        lqNote(2, updated: -6, override: lqUUID(999)),
        lqNote(3, updated: -5, anchor: lqWebAnchor("example.com")),
        lqNote(4, updated: -4, anchor: lqWebAnchor("example.com"), override: lqUUID(999)),
        lqNote(5, updated: -10, tab: lqTab(), source: NoteSource(url: "chrome://newtab")),
        lqNote(6, updated: -2, source: NoteSource(url: "https://example.com/")),
    ]
    let result = LibraryQuery.evaluate(notes: notes, workspaces: workspaces, now: lqNow)

    #expect(lqIDs(result.inbox) == [lqUUID(6), lqUUID(2), lqUUID(1)])
    #expect(result.workspaces.contains { $0.destination == .inbox } == false)
    #expect(
        lqDestinations(result.workspaces)
            == [.record(lqUUID(901)), .implicit(.tabsWithoutPage)]
    )
    #expect(lqIDs(result.workspaces[0].notes) == [lqUUID(4), lqUUID(3)])
    #expect(lqIDs(result.workspaces[1].notes) == [lqUUID(5)])
}

@Test func pinnedSectionOrdersPinnedNotesAndExcludesUnpinnedAndTrashed() {
    let result = LibraryQuery.evaluate(
        notes: [
            lqNote(1, updated: -10, pinned: -5),
            lqNote(2, updated: -20, pinned: -1),
            lqNote(3, updated: -1),
            lqNote(4, updated: -30, pinned: -2, trashed: -1),
        ],
        workspaces: [],
        now: lqNow
    )

    #expect(lqIDs(result.pinned) == [lqUUID(2), lqUUID(1)])
    #expect(lqIDs(result.trash) == [lqUUID(4)])
    #expect(!result.all.contains { $0.id == lqUUID(4) })
}

@Test func closedTabsIncludeClosedAndPendingRestoreButNotOpenTabs() {
    let result = LibraryQuery.evaluate(
        notes: [
            lqNote(1, updated: -10, closed: -2, tab: lqTab(closedAt: -2, pendingRestore: true)),
            lqNote(2, updated: -20, closed: -1),
            lqNote(3, updated: -30, tab: lqTab(pendingRestore: true)),
            lqNote(4, updated: -40),
            lqNote(5, updated: -10, closed: -2),
        ],
        workspaces: [],
        now: lqNow
    )

    #expect(lqIDs(result.closedTabs) == [lqUUID(2), lqUUID(1), lqUUID(5)])
    #expect(!result.closedTabs.contains { $0.id == lqUUID(3) })
    #expect(!result.closedTabs.contains { $0.id == lqUUID(4) })
}

@Test func explicitEmptyWorkspacesAreIncludedAndPinnedFirst() {
    let workspaces = [
        lqRecord(201, title: "Unpinned Empty", keys: [.host(name: "unpinned.example.com")]),
        lqRecord(202, title: "Pinned Empty", keys: [.host(name: "pinned.example.com")], pinned: true),
    ]
    let result = LibraryQuery.evaluate(
        notes: [],
        workspaces: workspaces,
        now: lqNow,
        workspaceOrder: .activity
    )

    #expect(lqDestinations(result.workspaces) == [.record(lqUUID(202)), .record(lqUUID(201))])
    #expect(result.workspaces.allSatisfy { $0.notes.isEmpty })
    #expect(result.workspaces.allSatisfy { $0.lastActivity == nil })
    #expect(result.workspaces[0].pinned)
    #expect(!result.workspaces[1].pinned)
}

@Test func workspaceActivityAndAlphabeticalOrdersHandleImplicitMergedAndOverrides() {
    let workspaces = [
        lqRecord(901, title: "Zulu", keys: [.host(name: "override.example.com")], pinned: true),
        lqRecord(902, title: "Zebra", keys: [.app(bundleID: "com.zebra")]),
        lqRecord(903, title: "Alpha", keys: [.localFiles]),
        lqRecord(904, title: "Beta", keys: [.host(name: "merged-a.com"), .host(name: "merged-b.com")]),
        lqRecord(905, title: "   ", keys: [.tabsWithoutPage]),
    ]
    let notes = [
        lqNote(
            1,
            updated: -20,
            anchor: lqWebAnchor("ignored.example.com"),
            override: lqUUID(902)
        ),
        lqNote(
            2,
            updated: -70,
            anchor: lqWebAnchor("also-ignored.example.com"),
            override: lqUUID(903)
        ),
        lqNote(3, updated: -30, anchor: lqWebAnchor("merged-a.com")),
        lqNote(4, updated: -40, anchor: lqWebAnchor("merged-b.com")),
        lqNote(5, updated: -10, anchor: lqWebAnchor("zeta.com")),
        lqNote(6, updated: -60, anchor: lqWebAnchor("beta.com")),
        lqNote(
            7,
            updated: -5,
            tab: lqTab(),
            source: NoteSource(url: "chrome://newtab")
        ),
    ]

    let activity = LibraryQuery.evaluate(
        notes: notes,
        workspaces: workspaces,
        now: lqNow,
        workspaceOrder: .activity
    )
    #expect(lqDestinations(activity.workspaces) == [
        .record(lqUUID(901)),
        .record(lqUUID(905)),
        .implicit(.host(name: "zeta.com")),
        .record(lqUUID(902)),
        .record(lqUUID(904)),
        .implicit(.host(name: "beta.com")),
        .record(lqUUID(903)),
    ])
    let merged = activity.workspaces.first { $0.destination == .record(lqUUID(904)) }
    #expect(merged?.lastActivity == lqDate(-30))
    #expect(merged.map { lqIDs($0.notes) } == [lqUUID(3), lqUUID(4)])

    let alphabetical = LibraryQuery.evaluate(
        notes: notes,
        workspaces: workspaces,
        now: lqNow,
        workspaceOrder: .alphabetical
    )
    #expect(lqDestinations(alphabetical.workspaces) == [
        .record(lqUUID(901)),
        .record(lqUUID(903)),
        .record(lqUUID(904)),
        .record(lqUUID(902)),
        .implicit(.host(name: "beta.com")),
        .implicit(.host(name: "zeta.com")),
        .record(lqUUID(905)),
    ])
}

@Test func tagVariantsMergeBySearchKeyWithSmallestNameAndDistinctNoteCounts() {
    let notes = [
        lqNote(1, text: "#Éclair #eclair #Tag #tag #TAG #alpha", updated: -5),
        lqNote(2, text: "#eclair #ÉCLAIR #tag", updated: -1),
        lqNote(3, text: "#alpha #alpha", updated: -10),
        lqNote(4, text: "#trash #tag", updated: -20, trashed: -1),
    ]
    let result = LibraryQuery.evaluate(notes: notes, workspaces: [], now: lqNow)

    #expect(result.tags.map(\.searchKey) == ["alpha", "eclair", "tag"])
    #expect(result.tags.map(\.name) == ["alpha", "eclair", "Tag"])
    #expect(result.tags.map(\.count) == [2, 2, 2])
    #expect(lqIDs(result.tags[0].notes) == [lqUUID(1), lqUUID(3)])
    #expect(lqIDs(result.tags[1].notes) == [lqUUID(2), lqUUID(1)])
    #expect(lqIDs(result.tags[2].notes) == [lqUUID(2), lqUUID(1)])
    #expect(result.tags[1].tag == LibraryTag(name: "eclair", searchKey: "eclair"))
    #expect(!result.tags.contains { group in
        group.notes.contains { $0.id == lqUUID(4) }
    })
}
