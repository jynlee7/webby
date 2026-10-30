import Foundation
import Testing
@testable import WebbyCore

private let compiledRecordID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
private let compiledAppRecordID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
private let compiledFilesRecordID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!
private let compiledTabsRecordID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")!
private let compiledMergedRecordID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A5")!

private func compiledUUID(_ suffix: String) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-000000000" + suffix)!
}

private func compiledDate(_ value: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: value)
}

private func compiledRecord(
    _ id: UUID,
    keys: [WorkspaceKey]
) -> WorkspaceRecord {
    WorkspaceRecord(id: id, keys: keys, createdAt: compiledDate(0))
}

private func compiledNote(
    _ suffix: String,
    anchor: Anchor? = nil,
    tab: TabBinding? = nil,
    workspaceOverride: UUID? = nil,
    text: String = "note",
    source: NoteSource? = nil,
    hidden: Bool = false,
    collapsed: Bool = false,
    excludedFromAgent: Bool = false,
    pinnedAt: TimeInterval? = nil,
    trashedAt: TimeInterval? = nil,
    ephemeral: Bool = false,
    created: TimeInterval,
    updated: TimeInterval? = nil
) -> Note {
    Note(
        id: compiledUUID(suffix),
        anchor: anchor,
        tab: tab,
        workspaceOverride: workspaceOverride,
        text: text,
        source: source,
        frame: NoteFrame(),
        placement: .window,
        collapsed: collapsed,
        hidden: hidden,
        pinnedAt: pinnedAt.map(compiledDate),
        trashedAt: trashedAt.map(compiledDate),
        excludedFromAgent: excludedFromAgent,
        createdAt: compiledDate(created),
        updatedAt: compiledDate(updated ?? created),
        ephemeral: ephemeral
    )
}

private func compiledTab(lastURL: String = "https://example.com/tab") -> TabBinding {
    TabBinding(
        browser: "chrome",
        profile: "Default",
        session: "session-1",
        tabID: 7,
        windowID: 1,
        index: 0,
        lastURL: lastURL
    )
}

private func compiledWeb(
    _ path: String,
    query: String? = nil,
    host: String = "example.com",
    scope: WebScope = .page
) -> Anchor {
    .web(page: PageURL(host: host, path: path, query: query), scope: scope)
}

private func compiledIDs(_ notes: [CompiledNote]) -> [String] {
    notes.map { $0.id.uuidString.suffix(3).lowercased() }
}

@Test func workspaceOrdersNotAttachedThenSiteAndPaths() {
    let workspaces = [compiledRecord(compiledRecordID, keys: [.host(name: "example.com")])]
    let notes = [
        compiledNote("001", anchor: compiledWeb("/", scope: .site), created: 10),
        compiledNote("002", anchor: compiledWeb("/a", scope: .prefix(path: "/a")), created: 20),
        compiledNote("003", anchor: compiledWeb("/a/b"), created: 30),
        compiledNote("004", workspaceOverride: compiledRecordID, created: 40),
        compiledNote(
            "005",
            anchor: compiledWeb("/tab", scope: .site),
            tab: compiledTab(),
            created: 50
        ),
    ]

    let document = CompiledDocument.workspace(
        destination: .record(compiledRecordID),
        notes: notes,
        workspaces: workspaces
    )

    #expect(document.title == "example.com")
    #expect(document.sections.map(\.kind) == [
        .workspaceNotes,
        .tabNotes,
        .siteWide,
        .path,
        .exactPage,
    ])
    #expect(compiledIDs(document.sections[0].notes) == ["004"])
    #expect(compiledIDs(document.sections[1].notes) == ["005"])
    #expect(compiledIDs(document.sections[2].notes) == ["001"])
    #expect(compiledIDs(document.sections[3].notes) == ["002"])
    #expect(compiledIDs(document.sections[4].notes) == ["003"])
    #expect(document.sections[3].path == "/a")
    #expect(document.sections[4].page?.path == "/a/b")
}

@Test func workspaceKeepsPrefixBeforeExactPageAtTheSamePath() {
    let workspaces = [compiledRecord(compiledRecordID, keys: [.host(name: "example.com")])]
    let notes = [
        compiledNote("002", anchor: compiledWeb("/a", scope: .page), created: 20),
        compiledNote("001", anchor: compiledWeb("/a", scope: .prefix(path: "/a")), created: 10),
    ]

    let document = CompiledDocument.workspace(
        destination: .record(compiledRecordID),
        notes: notes,
        workspaces: workspaces
    )

    #expect(document.sections.map(\.kind) == [.path, .exactPage])
    #expect(compiledIDs(document.sections[0].notes) == ["001"])
    #expect(compiledIDs(document.sections[1].notes) == ["002"])
}

@Test func workspaceSortsExactQueryVariantsDeterministically() {
    let workspaces = [compiledRecord(compiledRecordID, keys: [.host(name: "example.com")])]
    let notes = [
        compiledNote("001", anchor: compiledWeb("/p", query: "v=2"), created: 10),
        compiledNote("002", anchor: compiledWeb("/p", query: "v=1"), created: 20),
        compiledNote("003", anchor: compiledWeb("/p"), created: 30),
        compiledNote("004", anchor: compiledWeb("/p", query: "v=10"), created: 40),
    ]

    let document = CompiledDocument.workspace(
        destination: .record(compiledRecordID),
        notes: notes,
        workspaces: workspaces
    )

    let queries: [String?] = document.sections
        .filter { $0.kind == .exactPage }
        .map { $0.page?.query }
    #expect(queries == [nil, "v=1", "v=10", "v=2"])
}

@Test func pageOrdersExactThenDeepestPrefixesThenSiteWide() {
    let workspaces = [compiledRecord(compiledRecordID, keys: [.host(name: "example.com")])]
    let page = PageURL(host: "example.com", path: "/a/b/c")
    let notes = [
        compiledNote("001", anchor: compiledWeb("/", scope: .site), created: 10),
        compiledNote("002", anchor: compiledWeb("/a", scope: .prefix(path: "/a")), created: 20),
        compiledNote("003", anchor: compiledWeb("/a/b", scope: .prefix(path: "/a/b")), created: 30),
        compiledNote("004", anchor: compiledWeb("/a/b/c", scope: .prefix(path: "/a/b/c")), created: 40),
        compiledNote("005", anchor: compiledWeb("/a/b/c"), created: 50),
        compiledNote("006", workspaceOverride: compiledRecordID, created: 60),
        compiledNote("007", anchor: compiledWeb("/a/b/c"), tab: compiledTab(), created: 70),
    ]

    let document = CompiledDocument.page(
        page,
        destination: .record(compiledRecordID),
        notes: notes,
        workspaces: workspaces
    )

    #expect(document.sections.map(\.kind) == [
        .exactPage,
        .path,
        .path,
        .path,
        .siteWide,
    ])
    #expect(compiledIDs(document.sections[0].notes) == ["005"])
    #expect(document.sections[1].path == "/a/b/c")
    #expect(compiledIDs(document.sections[1].notes) == ["004"])
    #expect(document.sections[2].path == "/a/b")
    #expect(document.sections[3].path == "/a")
    #expect(compiledIDs(document.sections[4].notes) == ["001"])
}

@Test func pageExactMatchingUsesSignificantQueryIdentity() {
    let workspaces = [compiledRecord(compiledRecordID, keys: [.host(name: "example.com")])]
    let page = PageURL(host: "example.com", path: "/p", query: "v=2&t=10")
    let notes = [
        compiledNote("001", anchor: compiledWeb("/p", query: "v=1"), created: 10),
        compiledNote("002", anchor: compiledWeb("/p", query: "v=2"), created: 20),
    ]

    let document = CompiledDocument.page(
        page,
        destination: .record(compiledRecordID),
        notes: notes,
        workspaces: workspaces
    )

    #expect(document.sections.map(\.kind) == [.exactPage])
    #expect(compiledIDs(document.sections[0].notes) == ["002"])
}

@Test func mergedRecordKeepsEveryKeyButPageDocumentsStayOnOneHost() {
    let workspaces = [
        compiledRecord(
            compiledMergedRecordID,
            keys: [
                .host(name: "a.com"),
                .host(name: "b.com"),
                .app(bundleID: "com.example.app"),
            ]
        )
    ]
    let notes = [
        compiledNote("001", anchor: .app(bundleID: "com.example.app"), created: 10),
        compiledNote("002", anchor: compiledWeb("/b", host: "b.com", scope: .site), created: 20),
        compiledNote("003", anchor: compiledWeb("/a", host: "a.com", scope: .site), created: 30),
        compiledNote("004", anchor: compiledWeb("/a", host: "a.com"), created: 40),
    ]

    let workspace = CompiledDocument.workspace(
        destination: .record(compiledMergedRecordID),
        notes: notes,
        workspaces: workspaces
    )
    #expect(workspace.sections.map(\.kind) == [
        .appNotes,
        .siteWide,
        .exactPage,
        .siteWide,
    ])
    #expect(compiledIDs(workspace.sections[0].notes) == ["001"])
    #expect(compiledIDs(workspace.sections[1].notes) == ["003"])
    #expect(compiledIDs(workspace.sections[2].notes) == ["004"])
    #expect(compiledIDs(workspace.sections[3].notes) == ["002"])

    let page = CompiledDocument.page(
        PageURL(host: "a.com", path: "/a"),
        destination: .record(compiledMergedRecordID),
        notes: notes,
        workspaces: workspaces
    )
    #expect(page.sections.map(\.kind) == [.exactPage, .siteWide])
    #expect(compiledIDs(page.sections[0].notes) == ["004"])
    #expect(compiledIDs(page.sections[1].notes) == ["003"])
}

@Test func appWorkspaceKeepsWorkspaceTabAndAppSections() {
    let workspaces = [compiledRecord(compiledAppRecordID, keys: [.app(bundleID: "com.missing.app")])]
    let notes = [
        compiledNote("001", anchor: .app(bundleID: "com.missing.app"), created: 10),
        compiledNote(
            "002",
            anchor: .app(bundleID: "com.missing.app"),
            tab: compiledTab(),
            created: 20
        ),
        compiledNote("003", workspaceOverride: compiledAppRecordID, created: 30),
        compiledNote("004", anchor: .app(bundleID: "com.other.app"), created: 40),
    ]

    let document = CompiledDocument.workspace(
        destination: .record(compiledAppRecordID),
        notes: notes,
        workspaces: workspaces
    )

    #expect(document.sections.map(\.kind) == [.workspaceNotes, .tabNotes, .appNotes])
    #expect(compiledIDs(document.sections[0].notes) == ["003"])
    #expect(compiledIDs(document.sections[1].notes) == ["002"])
    #expect(compiledIDs(document.sections[2].notes) == ["001"])
}

@Test func localFilesWorkspaceUsesFilePathsWithoutPageLinks() {
    let workspaces = [compiledRecord(compiledFilesRecordID, keys: [.localFiles])]
    let notes = [
        compiledNote(
            "001",
            anchor: compiledWeb("/Users/me", host: "file", scope: .prefix(path: "/Users/me")),
            created: 10
        ),
        compiledNote(
            "002",
            anchor: compiledWeb("/Users/me/note.md", host: "file"),
            created: 20
        ),
        compiledNote(
            "003",
            anchor: compiledWeb("/", host: "file", scope: .site),
            created: 30
        ),
    ]

    let document = CompiledDocument.workspace(
        destination: .record(compiledFilesRecordID),
        notes: notes,
        workspaces: workspaces
    )

    #expect(document.sections.map(\.kind) == [.siteWide, .path, .exactPage])
    #expect(compiledIDs(document.sections[1].notes) == ["001"])
    #expect(compiledIDs(document.sections[2].notes) == ["002"])
    #expect(document.sections[2].notes.first?.pageLink == nil)
}

@Test func tabsWithoutPageWorkspaceKeepsTabNotes() {
    let workspaces = [
        compiledRecord(compiledTabsRecordID, keys: [.tabsWithoutPage])
    ]
    let notes = [
        compiledNote(
            "001",
            tab: compiledTab(),
            source: nil,
            created: 10
        )
    ]

    let document = CompiledDocument.workspace(
        destination: .record(compiledTabsRecordID),
        notes: notes,
        workspaces: workspaces
    )

    #expect(document.sections.map(\.kind) == [.tabNotes])
    #expect(compiledIDs(document.sections[0].notes) == ["001"])
    #expect(document.sections[0].notes.first?.pageLink == nil)
}

@Test func hiddenCollapsedAndAgentExcludedNotesAreIncludedWithFlags() {
    let workspaces = [compiledRecord(compiledRecordID, keys: [.host(name: "example.com")])]
    let note = compiledNote(
        "001",
        anchor: compiledWeb("/a", scope: .site),
        hidden: true,
        collapsed: true,
        excludedFromAgent: true,
        created: 10
    )

    let document = CompiledDocument.workspace(
        destination: .record(compiledRecordID),
        notes: [note],
        workspaces: workspaces
    )

    let compiled = document.sections.first?.notes.first
    #expect(compiled?.isHidden == true)
    #expect(compiled?.isCollapsed == true)
    #expect(compiled?.isExcludedFromAgent == true)
}

@Test func trashAndEphemeralNotesAreExcluded() {
    let workspaces = [compiledRecord(compiledRecordID, keys: [.host(name: "example.com")])]
    let notes = [
        compiledNote("001", anchor: compiledWeb("/a", scope: .site), created: 10),
        compiledNote(
            "002",
            anchor: compiledWeb("/a", scope: .site),
            trashedAt: 100,
            created: 20
        ),
        compiledNote(
            "003",
            anchor: compiledWeb("/a", scope: .site),
            ephemeral: true,
            created: 30
        ),
    ]

    let document = CompiledDocument.workspace(
        destination: .record(compiledRecordID),
        notes: notes,
        workspaces: workspaces
    )

    #expect(document.sections.count == 1)
    #expect(compiledIDs(document.sections[0].notes) == ["001"])
}

@Test func pinnedStatusComesBeforeCreatedAndIgnoresPinnedTimestamps() {
    let workspaces = [compiledRecord(compiledRecordID, keys: [.host(name: "example.com")])]
    let notes = [
        compiledNote("001", anchor: compiledWeb("/a", scope: .site), created: 1),
        compiledNote(
            "002",
            anchor: compiledWeb("/a", scope: .site),
            pinnedAt: 900,
            created: 2
        ),
        compiledNote(
            "003",
            anchor: compiledWeb("/a", scope: .site),
            pinnedAt: 100,
            created: 3
        ),
        compiledNote("004", anchor: compiledWeb("/a", scope: .site), created: 4),
    ]

    let document = CompiledDocument.workspace(
        destination: .record(compiledRecordID),
        notes: notes,
        workspaces: workspaces
    )

    #expect(compiledIDs(document.sections[0].notes) == ["002", "003", "001", "004"])
}

@Test func mergedHostWorkspaceQualifiesHeadingsAndTitle() {
    let workspaces = [compiledRecord(
        compiledMergedRecordID,
        keys: [.host(name: "b.com"), .host(name: "a.com")]
    )]
    let notes = [
        compiledNote("071", anchor: compiledWeb("/", host: "a.com", scope: .site), created: 1),
        compiledNote("072", anchor: compiledWeb("/", host: "b.com", scope: .site), created: 2),
        compiledNote("073", anchor: compiledWeb("/docs", host: "b.com", scope: .prefix(path: "/docs")), created: 3),
    ]

    let document = CompiledDocument.workspace(
        destination: .record(compiledMergedRecordID),
        notes: notes,
        workspaces: workspaces
    )

    #expect(document.title == "a.com · b.com")
    #expect(document.sections.map(\.heading) == [
        "a.com · Whole site",
        "b.com · Whole site",
        "b.com/docs (and below)",
    ])
}

@Test func shuffledInputProducesTheSameDocument() {
    let workspaces = [compiledRecord(compiledRecordID, keys: [.host(name: "example.com")])]
    let notes = [
        compiledNote("001", anchor: compiledWeb("/", scope: .site), created: 10),
        compiledNote("002", anchor: compiledWeb("/a", scope: .prefix(path: "/a")), created: 20),
        compiledNote("003", anchor: compiledWeb("/a/b"), created: 30),
        compiledNote("004", workspaceOverride: compiledRecordID, created: 40),
        compiledNote("005", anchor: compiledWeb("/a/b"), tab: compiledTab(), created: 50),
        compiledNote("006", anchor: compiledWeb("/a/b", query: "v=1"), created: 60),
    ]

    let forward = CompiledDocument.workspace(
        destination: .record(compiledRecordID),
        notes: notes,
        workspaces: workspaces
    )
    let reversed = CompiledDocument.workspace(
        destination: .record(compiledRecordID),
        notes: Array(notes.reversed()),
        workspaces: workspaces
    )
    let shuffled = CompiledDocument.workspace(
        destination: .record(compiledRecordID),
        notes: [notes[3], notes[0], notes[5], notes[2], notes[4], notes[1]],
        workspaces: workspaces
    )

    #expect(forward == reversed)
    #expect(forward == shuffled)

    let page = PageURL(host: "example.com", path: "/a/b")
    let forwardPage = CompiledDocument.page(
        page,
        destination: .record(compiledRecordID),
        notes: notes,
        workspaces: workspaces
    )
    let reversedPage = CompiledDocument.page(
        page,
        destination: .record(compiledRecordID),
        notes: Array(notes.reversed()),
        workspaces: workspaces
    )
    #expect(forwardPage == reversedPage)
}
