import Foundation
import Testing
@testable import WebbyCore

private let exampleRecordID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
private let appRecordID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
private let filesRecordID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
private let tabsRecordID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
private let mergedRecordID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
private let otherRecordID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
private let missingRecordID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!

private func record(_ id: UUID, keys: [WorkspaceKey]) -> WorkspaceRecord {
    WorkspaceRecord(id: id, keys: keys, createdAt: Date(timeIntervalSinceReferenceDate: 0))
}

private func note(
    anchor: Anchor? = nil,
    tab: TabBinding? = nil,
    workspaceOverride: UUID? = nil,
    source: NoteSource? = nil,
    trashedAt: Date? = nil,
    ephemeral: Bool = false
) -> Note {
    Note(
        anchor: anchor,
        tab: tab,
        workspaceOverride: workspaceOverride,
        source: source,
        frame: NoteFrame(x: 0, y: 0, width: 320, height: 240),
        placement: .window,
        trashedAt: trashedAt,
        ephemeral: ephemeral
    )
}

private func tab(
    lastURL: String = "https://navigated.example.com/elsewhere",
    closedAt: Date? = nil,
    pendingRestore: Bool = false
) -> TabBinding {
    TabBinding(
        browser: "chrome",
        profile: "Default",
        session: "session-1",
        tabID: 7,
        windowID: 2,
        index: 1,
        lastURL: lastURL,
        closedAt: closedAt,
        pendingRestore: pendingRestore
    )
}

private func webAnchor(_ host: String, scope: WebScope = .page) -> Anchor {
    .web(page: PageURL(host: host, path: "/a"), scope: scope)
}

@Test func emptyWorkspacesLeaveUnboundNoteInInbox() {
    #expect(WorkspaceResolver.resolve(note(), workspaces: []) == .inbox)
}

@Test func resolverOwnsTheInboxPredicateIncludingDanglingOverrides() {
    let workspaces = [record(exampleRecordID, keys: [.host(name: "example.com")])]
    #expect(WorkspaceResolver.isInbox(note(), workspaces: workspaces))
    #expect(WorkspaceResolver.isInbox(note(workspaceOverride: missingRecordID), workspaces: workspaces))
    #expect(!WorkspaceResolver.isInbox(note(workspaceOverride: exampleRecordID), workspaces: workspaces))
    #expect(!WorkspaceResolver.isInbox(note(anchor: webAnchor("example.com")), workspaces: workspaces))
    #expect(!WorkspaceResolver.isInbox(note(tab: tab()), workspaces: workspaces))
}

@Test func sourceURLAloneDoesNotConferMembership() {
    let workspaces = [record(exampleRecordID, keys: [.host(name: "example.com")])]
    let sourceOnly = note(source: NoteSource(url: "https://example.com/a"))

    #expect(WorkspaceResolver.resolve(sourceOnly, workspaces: workspaces) == .inbox)
}

@Test func danglingOverrideAloneIsInbox() {
    let workspaces = [record(exampleRecordID, keys: [.host(name: "example.com")])]
    let dangling = note(workspaceOverride: missingRecordID)

    #expect(WorkspaceResolver.resolve(dangling, workspaces: workspaces) == .inbox)
    #expect(dangling.workspaceOverride == missingRecordID)
}

@Test func validOverrideWinsEvenWithConflictingAnchorAndTab() {
    let workspaces = [
        record(filesRecordID, keys: [.localFiles]),
        record(exampleRecordID, keys: [.host(name: "example.com")]),
        record(otherRecordID, keys: [.host(name: "other.example.com")]),
    ]
    let overrideNote = note(
        anchor: webAnchor("example.com"),
        tab: tab(),
        workspaceOverride: filesRecordID,
        source: NoteSource(url: "https://other.example.com/a")
    )

    #expect(WorkspaceResolver.resolve(overrideNote, workspaces: workspaces) == .record(filesRecordID))
}

@Test func danglingOverrideFallsBackToAnchor() {
    let workspaces = [record(exampleRecordID, keys: [.host(name: "example.com")])]
    let dangling = note(anchor: webAnchor("example.com"), workspaceOverride: missingRecordID)

    #expect(WorkspaceResolver.resolve(dangling, workspaces: workspaces) == .record(exampleRecordID))
    #expect(WorkspaceResolver.resolve(dangling, workspaces: []) == .implicit(.host(name: "example.com")))
}

@Test func danglingOverrideFallsBackToTabSource() {
    let workspaces = [record(filesRecordID, keys: [.localFiles])]
    let dangling = note(
        tab: tab(),
        workspaceOverride: missingRecordID,
        source: NoteSource(url: "file:///Users/me/note.md")
    )

    #expect(WorkspaceResolver.resolve(dangling, workspaces: workspaces) == .record(filesRecordID))
}

@Test func everyAnchorScopeUsesOnlyTheAnchorHost() {
    let scopes: [WebScope] = [.page, .prefix(path: "/a"), .site]

    for scope in scopes {
        let anchored = note(anchor: webAnchor("example.com", scope: scope))
        #expect(
            WorkspaceResolver.resolve(anchored, workspaces: [])
                == .implicit(.host(name: "example.com"))
        )
    }
}

@Test func appAndFileAnchorsUseTheirDedicatedKeys() throws {
    let filePage = try #require(PageURL(string: "file:///Users/me/note.md"))
    let appNote = note(anchor: .app(bundleID: "com.example.Notes"))
    let fileNote = note(anchor: .web(page: filePage, scope: .page))

    #expect(
        WorkspaceResolver.resolve(appNote, workspaces: [])
            == .implicit(.app(bundleID: "com.example.Notes"))
    )
    #expect(WorkspaceResolver.resolve(fileNote, workspaces: []) == .implicit(.localFiles))

    let workspaces = [
        record(appRecordID, keys: [.app(bundleID: "com.example.Notes")]),
        record(filesRecordID, keys: [.localFiles]),
    ]
    #expect(WorkspaceResolver.resolve(appNote, workspaces: workspaces) == .record(appRecordID))
    #expect(WorkspaceResolver.resolve(fileNote, workspaces: workspaces) == .record(filesRecordID))
}

@Test func anchorWinsOverTabAndSourceConflict() {
    let workspaces = [record(otherRecordID, keys: [.host(name: "other.example.com")])]
    let anchored = note(
        anchor: webAnchor("example.com"),
        tab: tab(),
        source: NoteSource(url: "https://other.example.com/a")
    )

    #expect(
        WorkspaceResolver.resolve(anchored, workspaces: workspaces)
            == .implicit(.host(name: "example.com"))
    )
}

@Test func httpAndHTTPSTabSourcesUseTheCreationHost() {
    let sources = [
        "http://example.com/a",
        "https://example.com/a",
        "HTTPS://WWW.Example.COM/a?x=1#top",
    ]

    for source in sources {
        let tabNote = note(tab: tab(), source: NoteSource(url: source))
        #expect(
            WorkspaceResolver.resolve(tabNote, workspaces: [])
                == .implicit(.host(name: "example.com"))
        )
    }
}

@Test func fileTabSourceUsesLocalFiles() {
    let tabNote = note(tab: tab(), source: NoteSource(url: "file:///Users/me/note.md"))

    #expect(WorkspaceResolver.resolve(tabNote, workspaces: []) == .implicit(.localFiles))
}

@Test func missingInvalidUnsupportedAndChromeTabSourcesUseTabsWithoutPage() {
    let sources: [String?] = [
        nil,
        "",
        "not a url",
        "chrome://newtab",
        "ftp://example.com/a",
        "mailto:me@example.com",
    ]

    for source in sources {
        let tabNote = note(tab: tab(), source: source.map { NoteSource(url: $0) })
        #expect(
            WorkspaceResolver.resolve(tabNote, workspaces: [])
                == .implicit(.tabsWithoutPage)
        )
    }
}

@Test func tabNavigationClosureAndPendingRestoreDoNotMoveTheWorkspace() {
    let source = NoteSource(url: "https://created.example.com/start")
    let workspaces = [
        record(exampleRecordID, keys: [.host(name: "created.example.com")]),
        record(otherRecordID, keys: [.host(name: "elsewhere.example.com")]),
    ]
    let notes = [
        note(tab: tab(lastURL: "https://created.example.com/start"), source: source),
        note(tab: tab(lastURL: "https://elsewhere.example.com/other"), source: source),
        note(
            tab: tab(
                lastURL: "https://elsewhere.example.com/other",
                closedAt: Date(timeIntervalSinceReferenceDate: 100)
            ),
            source: source
        ),
        note(
            tab: tab(lastURL: "chrome://newtab", pendingRestore: true),
            source: source
        ),
    ]

    for tabNote in notes {
        #expect(WorkspaceResolver.resolve(tabNote, workspaces: workspaces) == .record(exampleRecordID))
    }
}

@Test func mergedRecordResolvesEveryContainedKeyToItsID() throws {
    let filePage = try #require(PageURL(string: "file:///Users/me/note.md"))
    let workspaces = [
        record(
            mergedRecordID,
            keys: [
                .host(name: "a.example.com"),
                .host(name: "b.example.com"),
                .app(bundleID: "com.example.App"),
                .localFiles,
                .tabsWithoutPage,
            ]
        )
    ]
    let notes = [
        note(anchor: webAnchor("a.example.com")),
        note(anchor: webAnchor("b.example.com", scope: .site)),
        note(anchor: .app(bundleID: "com.example.App")),
        note(anchor: .web(page: filePage, scope: .page)),
        note(tab: tab(), source: NoteSource(url: "chrome://newtab")),
    ]

    for mergedNote in notes {
        #expect(WorkspaceResolver.resolve(mergedNote, workspaces: workspaces) == .record(mergedRecordID))
    }
}

@Test func tabWithoutPageResolvesToItsRecord() {
    let workspaces = [record(tabsRecordID, keys: [.tabsWithoutPage])]
    let tabNote = note(tab: tab(), source: NoteSource(url: "chrome://newtab"))

    #expect(WorkspaceResolver.resolve(tabNote, workspaces: workspaces) == .record(tabsRecordID))
}

@Test func reversedRecordsStillResolveMatchingRecord() {
    let workspaces = [
        record(filesRecordID, keys: [.localFiles]),
        record(exampleRecordID, keys: [.host(name: "example.com")]),
        record(appRecordID, keys: [.app(bundleID: "com.example.Notes")]),
    ].reversed()

    #expect(
        WorkspaceResolver.resolve(note(anchor: webAnchor("example.com")), workspaces: Array(workspaces))
            == .record(exampleRecordID)
    )
    #expect(
        WorkspaceResolver.resolve(note(anchor: .app(bundleID: "com.example.Notes")), workspaces: Array(workspaces))
            == .record(appRecordID)
    )
}

@Test func unrelatedRecordsLeaveTheDerivedKeyImplicit() {
    let workspaces = [record(otherRecordID, keys: [.host(name: "other.example.com")])]

    #expect(
        WorkspaceResolver.resolve(note(anchor: webAnchor("example.com")), workspaces: workspaces)
            == .implicit(.host(name: "example.com"))
    )
}

@Test func localhostPortsIPsAndSubdomainsRemainDistinct() {
    let cases: [(String, WorkspaceKey)] = [
        ("http://localhost:3000/a", .host(name: "localhost:3000")),
        ("http://localhost:3001/a", .host(name: "localhost:3001")),
        ("http://127.0.0.1/a", .host(name: "127.0.0.1")),
        ("http://192.168.1.10:8080/a", .host(name: "192.168.1.10:8080")),
        ("https://sub.example.com/a", .host(name: "sub.example.com")),
        ("https://example.com/a", .host(name: "example.com")),
    ]

    for (source, expectedKey) in cases {
        let tabNote = note(tab: tab(), source: NoteSource(url: source))
        #expect(WorkspaceResolver.resolve(tabNote, workspaces: []) == .implicit(expectedKey))
    }
}

@Test func trashedAndEphemeralNotesResolveWithoutMutation() {
    let workspaces = [record(appRecordID, keys: [.app(bundleID: "com.example.Notes")])]
    let trashed = note(
        anchor: .app(bundleID: "com.example.Notes"),
        workspaceOverride: missingRecordID,
        trashedAt: Date(timeIntervalSinceReferenceDate: 200),
        ephemeral: true
    )
    let before = trashed

    #expect(WorkspaceResolver.resolve(trashed, workspaces: workspaces) == .record(appRecordID))
    #expect(trashed == before)
    #expect(trashed.workspaceOverride == missingRecordID)
}
