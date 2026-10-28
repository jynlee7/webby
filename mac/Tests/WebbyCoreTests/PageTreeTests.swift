import Foundation
import Testing
@testable import WebbyCore

private let treeRecordID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!

private func uuid(_ suffix: String) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-000000000" + suffix)!
}

private func date(_ value: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: value)
}

private func record(keys: [WorkspaceKey]) -> WorkspaceRecord {
    WorkspaceRecord(id: treeRecordID, keys: keys, createdAt: date(0))
}

private func treeNote(
    _ suffix: String,
    anchor: Anchor? = nil,
    tab: TabBinding? = nil,
    workspaceOverride: UUID? = nil,
    hidden: Bool = false,
    collapsed: Bool = false,
    excludedFromAgent: Bool = false,
    trashedAt: TimeInterval? = nil,
    ephemeral: Bool = false,
    created: TimeInterval,
    updated: TimeInterval? = nil
) -> Note {
    Note(
        id: uuid(suffix),
        anchor: anchor,
        tab: tab,
        workspaceOverride: workspaceOverride,
        frame: NoteFrame(),
        placement: .window,
        collapsed: collapsed,
        hidden: hidden,
        trashedAt: trashedAt.map(date),
        excludedFromAgent: excludedFromAgent,
        createdAt: date(created),
        updatedAt: date(updated ?? created),
        ephemeral: ephemeral
    )
}

private func tab() -> TabBinding {
    TabBinding(
        browser: "chrome",
        profile: "Default",
        session: "session-1",
        tabID: 7,
        windowID: 1,
        index: 0,
        lastURL: "https://example.com/ignored"
    )
}

private func web(
    _ path: String,
    query: String? = nil,
    host: String = "example.com",
    scope: WebScope = .page
) -> Anchor {
    .web(page: PageURL(host: host, path: path, query: query), scope: scope)
}

private func exactPage(
    _ path: String,
    query: String? = nil,
    host: String = "example.com"
) -> Anchor {
    .web(page: PageURL(host: host, path: path, query: query), scope: .page)
}

private func ids(_ notes: [LibraryNote]) -> [String] {
    notes.map { $0.id.uuidString.suffix(3).lowercased() }
}

private func allNotes(in tree: PageTree) -> [LibraryNote] {
    var result = tree.notAttached

    for host in tree.hosts {
        result.append(contentsOf: host.siteWide)
        appendNotes(in: host.root, to: &result)
    }

    return result
}

private func appendNotes(in node: PageTreeNode, to result: inout [LibraryNote]) {
    result.append(contentsOf: node.prefixNotes)
    for page in node.exactPages {
        result.append(contentsOf: page.notes)
    }
    for child in node.children {
        appendNotes(in: child, to: &result)
    }
}

@Test func notAttachedHoldsWorkspaceOnlyTabAndAppNotes() {
    let workspaces = [record(keys: [.host(name: "example.com"), .app(bundleID: "com.example.app")])]
    let workspaceOnly = treeNote(
        "003",
        workspaceOverride: treeRecordID,
        created: 300
    )
    let tabNote = treeNote(
        "002",
        anchor: exactPage("/ignored"),
        tab: tab(),
        created: 200
    )
    let appNote = treeNote(
        "001",
        anchor: .app(bundleID: "com.example.app"),
        created: 100
    )

    let tree = PageTree.build(
        notes: [workspaceOnly, appNote, tabNote],
        destination: .record(treeRecordID),
        workspaces: workspaces
    )

    #expect(tree.hosts.isEmpty)
    #expect(ids(tree.notAttached) == ["001", "002", "003"])
}

@Test func tabWinsOverARetainedPageAnchor() {
    let workspaces = [record(keys: [.host(name: "example.com")])]
    let anchoredTab = treeNote(
        "001",
        anchor: exactPage("/docs/install", query: "v=2"),
        tab: tab(),
        created: 100
    )

    let tree = PageTree.build(
        notes: [anchoredTab],
        destination: .record(treeRecordID),
        workspaces: workspaces
    )

    #expect(ids(tree.notAttached) == ["001"])
    #expect(tree.hosts.isEmpty)
}

@Test func sitePrefixAndPageNotesAreGroupedByHostAndPath() throws {
    let workspaces = [record(keys: [.host(name: "example.com")])]
    let site = treeNote(
        "001",
        anchor: web("/ignored", query: "ignored=1", scope: .site),
        created: 100
    )
    let prefix = treeNote(
        "002",
        anchor: web("/stored", scope: .prefix(path: "/docs")),
        created: 200,
        updated: 200
    )
    let page = treeNote(
        "003",
        anchor: exactPage("/docs/install", query: "v=2"),
        created: 300,
        updated: 300
    )

    let tree = PageTree.build(
        notes: [site, prefix, page],
        destination: .record(treeRecordID),
        workspaces: workspaces
    )

    let host = try #require(tree.hosts.first)
    #expect(tree.hosts.count == 1)
    #expect(host.host == "example.com")
    #expect(ids(host.siteWide) == ["001"])

    let docs = try #require(host.root.children.first)
    #expect(docs.path == "/docs")
    #expect(docs.segment == "docs")
    #expect(ids(docs.prefixNotes) == ["002"])

    let install = try #require(docs.children.first)
    #expect(install.path == "/docs/install")
    #expect(install.prefixNotes.isEmpty)
    #expect(install.exactPages.count == 1)
    #expect(install.exactPages[0].query == "v=2")
    #expect(ids(install.exactPages[0].notes) == ["003"])
}

@Test func prefixUsesItsNormalizedScopePathNotTheStoredPagePath() throws {
    let workspaces = [record(keys: [.host(name: "example.com")])]
    let prefix = treeNote(
        "001",
        anchor: web("/stored/elsewhere", scope: .prefix(path: "/a//b/")),
        created: 100
    )

    let tree = PageTree.build(
        notes: [prefix],
        destination: .record(treeRecordID),
        workspaces: workspaces
    )

    let root = try #require(tree.hosts.first?.root)
    #expect(root.children.map(\.path) == ["/a"])
    let a = try #require(root.children.first)
    #expect(a.children.map(\.path) == ["/a/b"])
    #expect(ids(a.children[0].prefixNotes) == ["001"])
    #expect(!root.children.contains { $0.path == "/stored" })
}

@Test func rootPrefixNotesLiveOnTheEmptyRootNode() throws {
    let workspaces = [record(keys: [.host(name: "example.com")])]
    let rootPrefix = treeNote(
        "002",
        anchor: web("/stored", scope: .prefix(path: "/")),
        created: 200,
        updated: 200
    )
    let site = treeNote("001", anchor: web("/other", scope: .site), created: 100)

    let tree = PageTree.build(
        notes: [rootPrefix, site],
        destination: .record(treeRecordID),
        workspaces: workspaces
    )

    let root = try #require(tree.hosts.first?.root)
    #expect(root.path == "")
    #expect(root.segment == "")
    #expect(ids(root.prefixNotes) == ["002"])
    #expect(root.children.isEmpty)
}

@Test func ancestorsAndChildSegmentsUseCaseSensitiveLexicalOrder() throws {
    let workspaces = [record(keys: [.host(name: "example.com")])]
    let notes = [
        treeNote("001", anchor: exactPage("/a/b"), created: 100),
        treeNote("002", anchor: exactPage("/a/c"), created: 200),
        treeNote("003", anchor: exactPage("/a/b/c"), created: 300),
        treeNote("004", anchor: exactPage("/Z"), created: 400),
        treeNote("005", anchor: exactPage("/a"), created: 500),
    ]

    let tree = PageTree.build(
        notes: notes,
        destination: .record(treeRecordID),
        workspaces: workspaces
    )

    let root = try #require(tree.hosts.first?.root)
    #expect(root.children.map(\.segment) == ["Z", "a"])

    let a = try #require(root.children.first { $0.segment == "a" })
    #expect(a.children.map(\.segment) == ["b", "c"])
    #expect(a.exactPages.count == 1)

    let b = try #require(a.children.first { $0.segment == "b" })
    #expect(b.children.map(\.segment) == ["c"])
    #expect(b.exactPages.count == 1)
    #expect(b.children[0].exactPages.count == 1)
}

@Test func prefixAndExactPageCoexistAtTheSamePath() throws {
    let workspaces = [record(keys: [.host(name: "example.com")])]
    let prefix = treeNote(
        "001",
        anchor: web("/ignored", scope: .prefix(path: "/a")),
        created: 100
    )
    let exact = treeNote("002", anchor: exactPage("/a"), created: 200)

    let tree = PageTree.build(
        notes: [prefix, exact],
        destination: .record(treeRecordID),
        workspaces: workspaces
    )

    let node = try #require(tree.hosts.first?.root.children.first)
    #expect(node.path == "/a")
    #expect(ids(node.prefixNotes) == ["001"])
    #expect(node.exactPages.count == 1)
    #expect(ids(node.exactPages[0].notes) == ["002"])
}

@Test func queryVariantsSortNilFirstThenLexicallyAndNotesByUpdatedDescending() throws {
    let workspaces = [record(keys: [.host(name: "example.com")])]
    let notes = [
        treeNote("004", anchor: exactPage("/search", query: "b=2"), created: 400, updated: 40),
        treeNote("003", anchor: exactPage("/search"), created: 300, updated: 30),
        treeNote("002", anchor: exactPage("/search", query: "a=1"), created: 200, updated: 20),
        treeNote("001", anchor: exactPage("/search"), created: 100, updated: 100),
    ]

    let tree = PageTree.build(
        notes: notes,
        destination: .record(treeRecordID),
        workspaces: workspaces
    )

    let node = try #require(tree.hosts.first?.root.children.first)
    #expect(node.exactPages.map(\.query) == [nil, "a=1", "b=2"])
    #expect(ids(node.exactPages[0].notes) == ["001", "003"])
    #expect(ids(node.exactPages[1].notes) == ["002"])
    #expect(node.exactPages[2].page.query == "b=2")
}

@Test func mergedRecordKeepsSeparateSortedHostGroups() {
    let workspaces = [
        record(keys: [
            .host(name: "b.example.com"),
            .host(name: "a.example.com"),
        ])
    ]
    let bNote = treeNote("001", anchor: exactPage("/b", host: "b.example.com"), created: 100)
    let aNote = treeNote("002", anchor: exactPage("/a", host: "a.example.com"), created: 200)

    let tree = PageTree.build(
        notes: [bNote, aNote],
        destination: .record(treeRecordID),
        workspaces: workspaces
    )

    #expect(tree.hosts.map(\.host) == ["a.example.com", "b.example.com"])
    #expect(tree.hosts[0].root.children.map(\.path) == ["/a"])
    #expect(tree.hosts[1].root.children.map(\.path) == ["/b"])
}

@Test func fileNotesUseAFileHostGroupWithinLocalFiles() throws {
    let workspaces = [record(keys: [.localFiles])]
    let filePage = PageURL(host: "file", path: "/Users/me/note.md")
    let note = treeNote(
        "001",
        anchor: .web(page: filePage, scope: .page),
        created: 100
    )

    let tree = PageTree.build(
        notes: [note],
        destination: .record(treeRecordID),
        workspaces: workspaces
    )

    let host = try #require(tree.hosts.first)
    #expect(tree.hosts.count == 1)
    #expect(host.host == "file")
    #expect(host.root.children.map(\.path) == ["/Users"])

    let me = try #require(host.root.children.first?.children.first)
    let leaf = try #require(me.children.first)
    #expect(me.path == "/Users/me")
    #expect(leaf.path == "/Users/me/note.md")
    #expect(ids(leaf.exactPages[0].notes) == ["001"])
}

@Test func hiddenCollapsedEphemeralAndExcludedNotesAreIncluded() throws {
    let workspaces = [record(keys: [.host(name: "example.com")])]
    let hidden = treeNote(
        "001",
        anchor: web("/hidden", scope: .site),
        hidden: true,
        collapsed: true,
        excludedFromAgent: true,
        ephemeral: true,
        created: 100
    )
    let page = treeNote(
        "002",
        anchor: exactPage("/page"),
        hidden: true,
        ephemeral: true,
        created: 200
    )

    let tree = PageTree.build(
        notes: [hidden, page],
        destination: .record(treeRecordID),
        workspaces: workspaces
    )

    let host = try #require(tree.hosts.first)
    #expect(ids(host.siteWide) == ["001"])
    #expect(ids(host.root.children[0].exactPages[0].notes) == ["002"])
}

@Test func trashedNotesAreExcluded() {
    let workspaces = [record(keys: [.host(name: "example.com")])]
    let trashed = treeNote(
        "001",
        anchor: exactPage("/a"),
        trashedAt: 50,
        created: 100
    )
    let ordinary = treeNote("002", anchor: exactPage("/b"), created: 200)

    let tree = PageTree.build(
        notes: [trashed, ordinary],
        destination: .record(treeRecordID),
        workspaces: workspaces
    )

    #expect(tree.notAttached.isEmpty)
    #expect(tree.hosts.flatMap { allNotesForHost($0) }.map(\.id) == [uuid("002")])
}

private func allNotesForHost(_ host: PageTreeHost) -> [LibraryNote] {
    var notes = host.siteWide
    appendNotes(in: host.root, to: &notes)
    return notes
}

@Test func buildsTenThousandDistinctPathsWithoutLosingNotes() {
    let workspaces = [record(keys: [.host(name: "example.com")])]
    let notes = (0..<10_000).map { index in
        Note(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
            anchor: exactPage(String(format: "/pages/%05d", index)),
            frame: NoteFrame(),
            placement: .window,
            createdAt: date(TimeInterval(index))
        )
    }

    let tree = PageTree.build(
        notes: notes,
        destination: .record(treeRecordID),
        workspaces: workspaces
    )

    #expect(allNotes(in: tree).count == 10_000)
}

@Test func shuffledInputProducesTheSameTree() {
    let workspaces = [
        record(keys: [
            .host(name: "example.com"),
            .host(name: "other.example.com"),
        ])
    ]
    let notes = [
        treeNote("001", anchor: web("/site", scope: .site), created: 100),
        treeNote("002", anchor: web("/stored", scope: .prefix(path: "/docs")), created: 200),
        treeNote("003", anchor: exactPage("/docs/a", query: "x=1"), created: 300, updated: 300),
        treeNote("004", anchor: exactPage("/docs/b"), created: 400, updated: 500),
        treeNote("005", anchor: exactPage("/other", host: "other.example.com"), created: 500),
        treeNote("006", workspaceOverride: treeRecordID, created: 600),
        treeNote("007", anchor: exactPage("/tabbed"), tab: tab(), created: 700),
        treeNote("008", anchor: .app(bundleID: "com.example.app"), workspaceOverride: treeRecordID, created: 800),
    ]

    let expected = PageTree.build(
        notes: notes,
        destination: .record(treeRecordID),
        workspaces: workspaces
    )
    let shuffles = [
        notes.reversed(),
        [notes[3], notes[0], notes[7], notes[2], notes[6], notes[1], notes[5], notes[4]],
        [notes[5], notes[4], notes[3], notes[2], notes[1], notes[0], notes[7], notes[6]],
    ]

    for shuffled in shuffles {
        let actual = PageTree.build(
            notes: Array(shuffled),
            destination: .record(treeRecordID),
            workspaces: workspaces
        )
        #expect(actual == expected)
    }
}

@Test func everyEligibleNoteAppearsExactlyOnce() {
    let workspaces = [
        record(keys: [
            .host(name: "example.com"),
            .app(bundleID: "com.example.app"),
        ])
    ]
    let notes = [
        treeNote("001", anchor: web("/site", scope: .site), created: 100),
        treeNote("002", anchor: web("/stored", scope: .prefix(path: "/docs")), created: 200),
        treeNote("003", anchor: exactPage("/docs/a", query: "x=1"), created: 300),
        treeNote("004", anchor: exactPage("/docs/a"), hidden: true, ephemeral: true, created: 400),
        treeNote("005", workspaceOverride: treeRecordID, created: 500),
        treeNote("006", anchor: exactPage("/tabbed"), tab: tab(), created: 600),
        treeNote("007", anchor: .app(bundleID: "com.example.app"), created: 700),
        treeNote("008", anchor: exactPage("/trashed"), trashedAt: 50, created: 800),
        treeNote("009", anchor: exactPage("/other", host: "other.example.com"), created: 900),
    ]

    let tree = PageTree.build(
        notes: notes,
        destination: .record(treeRecordID),
        workspaces: workspaces
    )
    let actual = allNotes(in: tree)
    let expectedIDs = Set(["001", "002", "003", "004", "005", "006", "007"].map { uuid($0) })

    #expect(actual.count == expectedIDs.count)
    #expect(Set(actual.map(\.id)) == expectedIDs)
}
