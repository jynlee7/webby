import Foundation
import Testing
@testable import WebbyCore

private func makeID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

private func makeDate(_ value: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: value)
}

private let utcStart = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
}()

private func makeNote(
    id: UUID,
    text: String = "",
    anchor: Anchor? = nil,
    tab: TabBinding? = nil,
    workspaceOverride: UUID? = nil,
    source: NoteSource? = nil,
    hidden: Bool = false,
    collapsed: Bool = false,
    excludedFromAgent: Bool = false,
    pinnedAt: Date? = nil,
    trashedAt: Date? = nil,
    ephemeral: Bool = false,
    createdAt: Date = makeDate(0),
    updatedAt: Date? = nil
) -> Note {
    Note(
        id: id,
        anchor: anchor,
        tab: tab,
        workspaceOverride: workspaceOverride,
        text: text,
        source: source,
        frame: NoteFrame(),
        placement: .window,
        collapsed: collapsed,
        hidden: hidden,
        pinnedAt: pinnedAt,
        trashedAt: trashedAt,
        excludedFromAgent: excludedFromAgent,
        createdAt: createdAt,
        updatedAt: updatedAt ?? createdAt,
        ephemeral: ephemeral
    )
}

private func webAnchor(
    _ host: String,
    path: String = "/",
    scope: WebScope = .page
) -> Anchor {
    .web(page: PageURL(host: host, path: path), scope: scope)
}

private func tab(closedAt: Date? = nil) -> TabBinding {
    TabBinding(
        browser: "chrome",
        profile: "Default",
        session: "session",
        tabID: 7,
        windowID: 2,
        index: 1,
        lastURL: "https://elsewhere.example.com/",
        closedAt: closedAt
    )
}

private func record(_ id: UUID, keys: [WorkspaceKey]) -> WorkspaceRecord {
    WorkspaceRecord(id: id, keys: keys, createdAt: makeDate(0))
}

private func search(
    _ text: String,
    _ cache: LibrarySearchCache,
    _ notes: [Note],
    workspaces: [WorkspaceRecord] = []
) -> [UUID] {
    cache.search(SearchQuery.parse(text), notes: notes, workspaces: workspaces)
}

@Test func cacheFoldsCaseAndDiacriticsForTextAndTags() {
    let id = makeID(1)
    let note = makeNote(id: id, text: "Café Résumé\nBody CAFÉ #Résumé")
    let cache = LibrarySearchCache(notes: [note])
    let entry = cache.entry(for: id)

    #expect(entry?.firstLine == "cafe resume")
    #expect(entry?.text == "cafe resume\nbody cafe #resume")
    #expect(entry?.tagKeys == ["resume"])
    #expect(search("cafe", cache, [note]) == [id])
    #expect(search("RÉSUMÉ", cache, [note]) == [id])
    #expect(search("tag:resume", cache, [note]) == [id])
    #expect(search("tag:RÉSUMÉ", cache, [note]) == [id])
}

@Test func cacheMissFoldsTheCurrentNoteOnDemand() {
    let pinned = makeNote(
        id: makeID(1),
        text: "Needle #dp",
        pinnedAt: makeDate(10)
    )
    let emptyCache = LibrarySearchCache()

    #expect(search("is:pinned", emptyCache, [pinned]) == [pinned.id])
    #expect(search("needle", emptyCache, [pinned]) == [pinned.id])
    #expect(search("tag:dp", emptyCache, [pinned]) == [pinned.id])
}

@Test func tagFilterAcceptsTheDisplayedHashPrefix() {
    let note = makeNote(id: makeID(1), text: "#dp")
    let cache = LibrarySearchCache(notes: [note])

    #expect(search("tag:dp", cache, [note]) == [note.id])
    #expect(search("tag:#dp", cache, [note]) == [note.id])
}

@Test func siteFileMatchesLocalFilesWorkspace() {
    let fileNote = makeNote(
        id: makeID(1),
        text: "local",
        anchor: webAnchor("file", path: "/Users/me/note.md")
    )
    let cache = LibrarySearchCache(notes: [fileNote])

    #expect(search("site:file", cache, [fileNote]) == [fileNote.id])
}

@Test func tagsUseExactFoldedSearchKeysRatherThanPrefixes() {
    let id = makeID(1)
    let note = makeNote(id: id, text: "#Café #dp #a-b")
    let cache = LibrarySearchCache(notes: [note])

    #expect(search("tag:cafe", cache, [note]) == [id])
    #expect(search("tag:CAFÉ", cache, [note]) == [id])
    #expect(search("tag:ca", cache, [note]).isEmpty)
    #expect(search("tag:dp tag:a-b", cache, [note]) == [id])
    #expect(search("tag:dp tag:missing", cache, [note]).isEmpty)
}

@Test func freeTextNeverIndexesTheRawSourceURLOrTitle() {
    let id = makeID(1)
    let note = makeNote(
        id: id,
        text: "hello",
        source: NoteSource(
            url: "https://secret.example.com/tokenneedle?auth=private",
            title: "tokenneedle"
        )
    )
    let cache = LibrarySearchCache(notes: [note])

    #expect(cache.entry(for: id)?.text == "hello")
    #expect(search("tokenneedle", cache, [note]).isEmpty)
    #expect(search("secret", cache, [note]).isEmpty)
    #expect(search("hello", cache, [note]) == [id])
}

@Test func requiredSiteTagAndTextQueryUsesAndSemantics() {
    let a = makeNote(
        id: makeID(1),
        text: "hash #dp\nfirst",
        anchor: webAnchor("leetcode.com", path: "/a"),
        updatedAt: makeDate(100)
    )
    let b = makeNote(
        id: makeID(2),
        text: "hash #dp\nsecond",
        anchor: webAnchor("leetcode.com", path: "/b"),
        updatedAt: makeDate(300)
    )
    let otherSite = makeNote(
        id: makeID(3),
        text: "hash #dp",
        anchor: webAnchor("example.com"),
        updatedAt: makeDate(400)
    )
    let otherTag = makeNote(
        id: makeID(4),
        text: "hash #other",
        anchor: webAnchor("leetcode.com"),
        updatedAt: makeDate(500)
    )
    let notes = [a, b, otherSite, otherTag]
    let cache = LibrarySearchCache(notes: notes)

    #expect(search("site:leetcode.com tag:dp hash", cache, notes) == [b.id, a.id])
    #expect(search("site:leetcode.com tag:dp", cache, notes) == [b.id, a.id])
    #expect(search("site:example.com hash", cache, notes) == [otherSite.id])
    #expect(search("site:leetcode.com tag:dp missing", cache, notes).isEmpty)
}

@Test func defaultSearchExcludesTrashAndTrashedSelectsOnlyTrash() {
    let ordinary = makeNote(id: makeID(1), text: "ordinary")
    let hidden = makeNote(id: makeID(2), text: "hidden", hidden: true)
    let collapsed = makeNote(id: makeID(3), text: "collapsed", collapsed: true)
    let excluded = makeNote(
        id: makeID(4),
        text: "excluded",
        excludedFromAgent: true
    )
    let ephemeral = makeNote(id: makeID(5), text: "ephemeral", ephemeral: true)
    let trashed = makeNote(
        id: makeID(6),
        text: "trashed",
        trashedAt: makeDate(10)
    )
    let trashedHidden = makeNote(
        id: makeID(7),
        text: "trashed hidden",
        hidden: true,
        trashedAt: makeDate(20)
    )
    let notes = [ordinary, hidden, collapsed, excluded, ephemeral, trashed, trashedHidden]
    let cache = LibrarySearchCache(notes: notes)

    #expect(
        Set(search("", cache, notes))
            == Set([ordinary.id, hidden.id, collapsed.id, excluded.id, ephemeral.id])
    )
    #expect(Set(search("is:trashed", cache, notes)) == Set([trashed.id, trashedHidden.id]))
    #expect(search("is:trashed is:hidden", cache, notes) == [trashedHidden.id])
    #expect(search("is:hidden", cache, notes) == [hidden.id])
}

@Test func inboxAndTabStatesUseTheWorkspaceResolver() {
    let recordID = makeID(10)
    let workspaces = [record(recordID, keys: [.host(name: "example.com")])]

    let inbox = makeNote(id: makeID(1), text: "inbox")
    let dangling = makeNote(
        id: makeID(2),
        text: "dangling",
        workspaceOverride: makeID(99)
    )
    let overridden = makeNote(
        id: makeID(3),
        text: "overridden",
        workspaceOverride: recordID
    )
    let openTab = makeNote(id: makeID(4), text: "open tab", tab: tab())
    let closedTab = makeNote(
        id: makeID(5),
        text: "closed tab",
        tab: tab(closedAt: makeDate(50))
    )
    let anchored = makeNote(
        id: makeID(6),
        text: "anchored",
        anchor: webAnchor("example.com")
    )
    let notes = [inbox, dangling, overridden, openTab, closedTab, anchored]
    let cache = LibrarySearchCache(notes: notes)

    #expect(Set(search("is:inbox", cache, notes, workspaces: workspaces)) == Set([inbox.id, dangling.id]))
    #expect(Set(search("is:tab", cache, notes, workspaces: workspaces)) == Set([openTab.id, closedTab.id]))
    #expect(search("is:inbox is:pinned", cache, notes, workspaces: workspaces).isEmpty)
}

@Test func mergedWorkspaceRecordsExposeEveryMemberKey() {
    let mergedID = makeID(20)
    let workspaces = [
        record(mergedID, keys: [
            .host(name: "a.com"),
            .host(name: "b.com"),
            .app(bundleID: "com.example.App"),
        ]),
    ]

    let a = makeNote(id: makeID(1), text: "a", anchor: webAnchor("a.com"))
    let b = makeNote(id: makeID(2), text: "b", anchor: webAnchor("b.com"))
    let overridden = makeNote(
        id: makeID(3),
        text: "override",
        workspaceOverride: mergedID
    )
    let app = makeNote(
        id: makeID(4),
        text: "app",
        anchor: .app(bundleID: "com.example.App")
    )
    let c = makeNote(id: makeID(5), text: "c", anchor: webAnchor("c.com"))
    let notes = [a, b, overridden, app, c]
    let cache = LibrarySearchCache(notes: notes)

    let merged = Set([a.id, b.id, overridden.id, app.id])
    #expect(Set(search("site:a.com", cache, notes, workspaces: workspaces)) == merged)
    #expect(Set(search("site:b.com", cache, notes, workspaces: workspaces)) == merged)
    #expect(Set(search("app:COM.EXAMPLE.APP", cache, notes, workspaces: workspaces)) == merged)
    #expect(
        Set(search("site:a.com site:b.com", cache, notes, workspaces: workspaces))
            == merged
    )
    #expect(search("site:a.com app:com.example.App", cache, notes, workspaces: workspaces).count == 4)
    #expect(search("site:c.com", cache, notes, workspaces: workspaces) == [c.id])
    #expect(search("site:c.com app:com.example.App", cache, notes, workspaces: workspaces).isEmpty)
}

@Test func siteMatchesTheNormalizedHostIncludingItsPort() {
    let withPort = makeNote(
        id: makeID(1),
        text: "port",
        anchor: webAnchor("example.com:8443")
    )
    let withoutPort = makeNote(
        id: makeID(2),
        text: "plain",
        anchor: webAnchor("example.com")
    )
    let notes = [withPort, withoutPort]
    let cache = LibrarySearchCache(notes: notes)

    #expect(search("site:example.com:8443", cache, notes) == [withPort.id])
    #expect(search("site:EXAMPLE.COM:8443", cache, notes) == [withPort.id])
    #expect(search("site:example.com", cache, notes) == [withoutPort.id])
    #expect(search("site:www.example.com", cache, notes).isEmpty)

    let storedDoubleWww = makeNote(
        id: makeID(3),
        text: "double www",
        anchor: webAnchor("www.example.com")
    )
    let allNotes = notes + [storedDoubleWww]
    let rebuilt = LibrarySearchCache(notes: allNotes)
    #expect(search("site:www.example.com", rebuilt, allNotes) == [storedDoubleWww.id])
}

@Test func scopeMatchesOnlyTheNotesWebAnchorScope() {
    let page = makeNote(
        id: makeID(1),
        text: "page",
        anchor: webAnchor("example.com", scope: .page)
    )
    let prefix = makeNote(
        id: makeID(2),
        text: "prefix",
        anchor: webAnchor("example.com", path: "/docs", scope: .prefix(path: "/docs"))
    )
    let site = makeNote(
        id: makeID(3),
        text: "site",
        anchor: webAnchor("example.com", scope: .site)
    )
    let app = makeNote(
        id: makeID(4),
        text: "app",
        anchor: .app(bundleID: "com.example.App")
    )
    let inbox = makeNote(id: makeID(5), text: "inbox")
    let notes = [page, prefix, site, app, inbox]
    let cache = LibrarySearchCache(notes: notes)

    #expect(search("scope:page", cache, notes) == [page.id])
    #expect(search("scope:prefix", cache, notes) == [prefix.id])
    #expect(search("scope:site", cache, notes) == [site.id])
    #expect(search("scope:page scope:site", cache, notes).isEmpty)
}

@Test func updatedFilterIsStrictlyAfterTheUTCBoundary() {
    let before = makeNote(
        id: makeID(1),
        text: "before",
        updatedAt: utcStart.addingTimeInterval(-1)
    )
    let boundary = makeNote(
        id: makeID(2),
        text: "boundary",
        updatedAt: utcStart
    )
    let after = makeNote(
        id: makeID(3),
        text: "after",
        updatedAt: utcStart.addingTimeInterval(1)
    )
    let notes = [before, boundary, after]
    let cache = LibrarySearchCache(notes: notes)

    #expect(search("updated:>2024-01-01", cache, notes) == [after.id])
    #expect(
        search("updated:>2024-01-01 updated:>2023-12-31", cache, notes)
            == [after.id]
    )
    #expect(search("updated:>2024-01-02", cache, notes).isEmpty)
}

@Test func rankingUsesPhraseThenFirstLineThenFullText() {
    let tier0New = makeNote(
        id: makeID(2),
        text: "alpha beta\nbody",
        updatedAt: makeDate(20)
    )
    let tier0Old = makeNote(
        id: makeID(1),
        text: "alpha beta\nbody",
        updatedAt: makeDate(10)
    )
    let tier1LowID = makeNote(
        id: makeID(3),
        text: "alpha x beta\nbody",
        updatedAt: makeDate(50)
    )
    let tier1HighID = makeNote(
        id: makeID(6),
        text: "alpha x beta\nbody",
        updatedAt: makeDate(50)
    )
    let tier2Newest = makeNote(
        id: makeID(4),
        text: "body\nalpha beta",
        updatedAt: makeDate(100)
    )
    let notes = [tier1HighID, tier2Newest, tier0Old, tier1LowID, tier0New]
    let cache = LibrarySearchCache(notes: notes)

    #expect(
        search("alpha beta", cache, notes)
            == [tier0New.id, tier0Old.id, tier1LowID.id, tier1HighID.id, tier2Newest.id]
    )
    #expect(
        search(#""alpha beta""#, cache, notes)
            == [tier0New.id, tier0Old.id, tier2Newest.id]
    )
}

@Test func equalTiersAndDatesUseLowercaseUUIDOrderEvenWhenShuffled() {
    let high = makeNote(id: makeID(10), text: "same #dp", updatedAt: makeDate(100))
    let low = makeNote(id: makeID(9), text: "same #dp", updatedAt: makeDate(100))
    let older = makeNote(id: makeID(1), text: "same #dp", updatedAt: makeDate(50))
    let notes = [high, older, low]
    let cache = LibrarySearchCache(notes: notes)

    #expect(search("tag:dp", cache, notes) == [low.id, high.id, older.id])
}

@Test func cacheUpdateRemoveAndRebuildKeepOnlyCurrentNotes() {
    let first = makeNote(id: makeID(1), text: "First line\nBody")
    let second = makeNote(id: makeID(2), text: "Second")
    var cache = LibrarySearchCache(notes: [first, second])

    #expect(cache.count == 2)
    #expect(cache.entry(for: first.id)?.firstLine == "first line")

    let changed = makeNote(id: first.id, text: "Changed line\nNew body")
    cache.update(changed)
    #expect(cache.entry(for: first.id)?.text == "changed line\nnew body")
    #expect(search("first", cache, [changed, second]).isEmpty)
    #expect(search("changed", cache, [changed, second]) == [first.id])

    cache.remove(id: second.id)
    #expect(cache.count == 1)
    #expect(cache.entry(for: second.id) == nil)

    let third = makeNote(id: makeID(3), text: "Third")
    cache.rebuild(notes: [third])
    #expect(cache.count == 1)
    #expect(cache.entry(for: first.id) == nil)
    #expect(cache.entry(for: third.id)?.text == "third")
}

@Test func searchFoldsCacheMissesAndIgnoresEntriesWithoutCurrentNotes() {
    let first = makeNote(id: makeID(1), text: "first")
    let removed = makeNote(id: makeID(2), text: "removed")
    let ghost = makeNote(id: makeID(99), text: "ghost")
    var cache = LibrarySearchCache(notes: [first, removed, ghost])

    cache.remove(id: removed.id)
    #expect(search("removed", cache, [first, removed]) == [removed.id])
    #expect(search("ghost", cache, [first]).isEmpty)
    #expect(search("first", cache, [first]) == [first.id])
}
