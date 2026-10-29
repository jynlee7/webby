import Foundation
import Testing
@testable import Webby
import WebbyCore

private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbyLibraryModel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeNote(
    text: String = "",
    anchor: Anchor? = nil,
    tab: TabBinding? = nil,
    workspaceOverride: UUID? = nil,
    pinnedAt: Date? = nil,
    trashedAt: Date? = nil,
    ephemeral: Bool = false,
    updatedAt: Date = fixedNow
) -> Note {
    Note(
        anchor: anchor,
        tab: tab,
        workspaceOverride: workspaceOverride,
        text: text,
        frame: NoteFrame(),
        placement: .screen,
        pinnedAt: pinnedAt,
        trashedAt: trashedAt,
        createdAt: fixedNow,
        updatedAt: updatedAt,
        ephemeral: ephemeral
    )
}

@MainActor
private func makeController(_ store: NoteStore) -> NotesController {
    let permission = AccessibilityPermission()
    let monitor = ContextMonitor(permission: permission)
    return NotesController(
        store: store,
        monitor: monitor,
        permission: permission,
        themes: .fallback,
        now: { fixedNow }
    )
}

@MainActor
private func makeStore() throws -> (NoteStore, URL) {
    let directory = try makeTempDirectory()
    return (NoteStore(fileURL: directory.appendingPathComponent("notes.json")), directory)
}

private func ids(_ notes: [LibraryNote]) -> Set<UUID> {
    Set(notes.map(\.id))
}

@MainActor
@Suite struct LibraryModelTests {
    @Test func defaultsToInboxAndReportsSidebarCounts() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = WorkspaceRecord(keys: [.host(name: "example.com")], createdAt: fixedNow)
        try store.replaceWorkspaces([record])

        let inbox = makeNote(text: "inbox")
        let pinned = makeNote(text: "pinned", pinnedAt: fixedNow)
        let workspace = makeNote(
            text: "workspace",
            anchor: .web(page: PageURL(host: "example.com", path: "/a"), scope: .page)
        )
        let trashed = makeNote(text: "trash", trashedAt: fixedNow.addingTimeInterval(-60))
        #expect(store.add(inbox))
        #expect(store.add(pinned))
        #expect(store.add(workspace))
        #expect(store.add(trashed))

        let model = LibraryModel(controller: makeController(store), clock: { fixedNow })

        #expect(model.selectedSection == .inbox)
        #expect(model.selectedWorkspace == nil)
        #expect(model.selectedPage == .all)
        #expect(model.selectedNoteID == nil)
        #expect(model.selectedTagKey == nil)
        #expect(model.searchText.isEmpty)
        #expect(model.searchDiagnostics.isEmpty)

        #expect(model.sidebarCounts[.inbox] == 2)
        #expect(model.sidebarCounts[.pinned] == 1)
        #expect(model.sidebarCounts[.all] == 3)
        #expect(model.sidebarCounts[.workspaces] == 1)
        #expect(model.sidebarCounts[.trash] == 1)
        #expect(ids(model.visibleNotes) == [inbox.id, pinned.id])
    }

    @Test func selectsNotesAcrossInboxWorkspacesTagsAndTrash() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = WorkspaceRecord(keys: [.host(name: "example.com")], createdAt: fixedNow)
        try store.replaceWorkspaces([record])

        let inbox = makeNote(text: "plain")
        let tagged = makeNote(text: "#Swift tagged")
        let page = PageURL(host: "example.com", path: "/docs/install")
        let workspace = makeNote(
            text: "web",
            anchor: .web(page: page, scope: .page)
        )
        let trashed = makeNote(text: "old", trashedAt: fixedNow)
        let ephemeral = makeNote(text: "temporary", ephemeral: true)
        for note in [inbox, tagged, workspace, trashed, ephemeral] {
            #expect(store.add(note))
        }

        let model = LibraryModel(controller: makeController(store), clock: { fixedNow })

        #expect(model.selectNote(inbox.id))
        #expect(model.selectedSection == .inbox)
        #expect(model.selectedNoteID == inbox.id)
        #expect(model.selectedNote?.id == inbox.id)

        #expect(model.selectNote(workspace.id))
        #expect(model.selectedSection == .workspaces)
        #expect(model.selectedWorkspace == .record(record.id))
        #expect(model.selectedPage == .page(page))
        #expect(model.selectedNoteID == workspace.id)

        let tag = try #require(model.result.tags.first { $0.searchKey == "swift" })
        model.select(tag.tag)
        #expect(model.selectedSection == .tags)
        #expect(model.selectedTagKey == "swift")
        #expect(model.selectedTag == tag.tag)
        #expect(ids(model.visibleNotes) == [tagged.id])

        #expect(model.selectNote(trashed.id))
        #expect(model.selectedSection == .trash)
        #expect(model.selectedNoteID == trashed.id)

        let selectionBeforeMissing = model.selectedNoteID
        #expect(!model.selectNote(UUID()))
        #expect(model.selectedNoteID == selectionBeforeMissing)
        #expect(!model.selectNote(ephemeral.id))
        #expect(model.selectedNoteID == selectionBeforeMissing)
    }

    @Test func searchFiltersUsesTheCacheAndReportsDiagnostics() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let alpha = makeNote(text: "alpha beta")
        let gamma = makeNote(text: "gamma")
        #expect(store.add(alpha))
        #expect(store.add(gamma))

        let model = LibraryModel(controller: makeController(store), clock: { fixedNow })
        model.select(section: .inbox)

        model.searchText = "alpha"
        #expect(ids(model.visibleNotes) == [alpha.id])
        #expect(model.searchDiagnostics.isEmpty)

        model.searchText = "site:"
        #expect(model.visibleNotes.isEmpty)
        #expect(model.searchDiagnostics.count == 1)

        model.searchText = ""
        #expect(ids(model.visibleNotes) == [alpha.id, gamma.id])

        model.updateText(id: alpha.id, text: "delta")
        #expect(model.searchCacheRebuildCount == 1)
        #expect(model.searchCacheEntryCount == 2)

        model.searchText = "delta"
        #expect(ids(model.visibleNotes) == [alpha.id])
        model.searchText = "alpha"
        #expect(model.visibleNotes.isEmpty)
    }

    @Test func trashSearchAddsTrashedEligibility() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let active = makeNote(text: "alpha active")
        let trashed = makeNote(text: "alpha old", trashedAt: fixedNow.addingTimeInterval(-60))
        #expect(store.add(active))
        #expect(store.add(trashed))

        let model = LibraryModel(controller: makeController(store), clock: { fixedNow })
        model.select(section: .trash)
        model.searchText = "alpha"

        #expect(ids(model.visibleNotes) == [trashed.id])
        #expect(model.searchQuery.clauses == [.text("alpha")])
        #expect(model.effectiveSearchQuery.clauses.contains(.state(.trashed)))
    }

    @Test func pageSelectionUsesThePageTree() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = WorkspaceRecord(keys: [.host(name: "example.com")], createdAt: fixedNow)
        try store.replaceWorkspaces([record])

        let site = makeNote(
            text: "site",
            anchor: .web(page: PageURL(host: "example.com", path: "/landing"), scope: .site)
        )
        let prefix = makeNote(
            text: "prefix",
            anchor: .web(
                page: PageURL(host: "example.com", path: "/stored"),
                scope: .prefix(path: "/docs")
            )
        )
        let pageURL = PageURL(host: "example.com", path: "/docs/install", query: "v=2")
        let page = makeNote(
            text: "page",
            anchor: .web(page: pageURL, scope: .page)
        )
        for note in [site, prefix, page] {
            #expect(store.add(note))
        }

        let model = LibraryModel(controller: makeController(store), clock: { fixedNow })
        model.select(workspace: .record(record.id))
        #expect(ids(model.visibleNotes) == [site.id, prefix.id, page.id])

        model.select(page: .notAttached)
        #expect(model.visibleNotes.isEmpty)

        model.select(page: .site(host: "example.com"))
        #expect(ids(model.visibleNotes) == [site.id, prefix.id, page.id])

        model.select(page: .prefix(host: "example.com", path: "/docs"))
        #expect(ids(model.visibleNotes) == [prefix.id, page.id])

        model.select(page: .page(pageURL))
        #expect(ids(model.visibleNotes) == [page.id])

        #expect(model.selectNote(page.id))
        #expect(model.selectedPage == .page(pageURL))
        #expect(model.selectedNoteID == page.id)

        #expect(model.selectNote(site.id))
        #expect(model.selectedPage == .site(host: "example.com"))
        #expect(ids(model.visibleNotes) == [site.id, prefix.id, page.id])
    }

    @Test func selectionRepairsAfterTrashRestoreSearchAndAttachmentChanges() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = WorkspaceRecord(keys: [.host(name: "example.com")], createdAt: fixedNow)
        try store.replaceWorkspaces([record])

        let alpha = makeNote(text: "alpha")
        let beta = makeNote(text: "beta")
        let oldPage = PageURL(host: "example.com", path: "/old")
        let newPage = PageURL(host: "example.com", path: "/new")
        let web = makeNote(text: "web", anchor: .web(page: oldPage, scope: .page))
        for note in [alpha, beta, web] {
            #expect(store.add(note))
        }

        let model = LibraryModel(controller: makeController(store), clock: { fixedNow })

        #expect(model.selectNote(alpha.id))
        model.trash(id: alpha.id)
        #expect(model.selectedNoteID == nil)
        #expect(model.result.trash.map(\.id) == [alpha.id])

        model.select(section: .trash)
        #expect(model.selectNote(alpha.id))
        model.restore(id: alpha.id)
        #expect(model.selectedNoteID == nil)
        #expect(model.result.trash.isEmpty)

        model.select(section: .inbox)
        #expect(model.selectNote(beta.id))
        model.searchText = "alpha"
        #expect(model.selectedNoteID == nil)
        model.searchText = ""

        #expect(model.selectNote(web.id))
        #expect(model.selectedPage == .page(oldPage))
        model.attach(
            id: web.id,
            anchor: .web(page: newPage, scope: .page),
            workspace: record.id
        )
        #expect(model.selectedPage == .all)
        #expect(model.selectedNoteID == web.id)
        #expect(ids(model.visibleNotes).contains(web.id))

        model.trash(id: alpha.id)
        model.select(section: .trash)
        #expect(model.selectNote(alpha.id))
        model.requestEmptyTrash()
        model.confirmEmptyTrash()
        #expect(model.selectedNoteID == nil)
        #expect(model.result.trash.isEmpty)
    }

    @Test func emptyTrashConfirmationCountsCancelsAndConfirms() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = makeNote(text: "first", trashedAt: fixedNow.addingTimeInterval(-60))
        let second = makeNote(text: "second", trashedAt: fixedNow.addingTimeInterval(-30))
        #expect(store.add(first))
        #expect(store.add(second))

        let model = LibraryModel(controller: makeController(store), clock: { fixedNow })

        model.requestEmptyTrash()
        #expect(model.pendingEmptyTrash?.count == 2)
        #expect(model.pendingEmptyTrash?.ids == [first.id, second.id])
        model.cancelEmptyTrash()
        #expect(model.pendingEmptyTrash == nil)
        #expect(store.note(id: first.id) != nil)
        #expect(store.note(id: second.id) != nil)

        model.requestEmptyTrash()
        model.confirmEmptyTrash()
        #expect(model.pendingEmptyTrash == nil)
        #expect(store.note(id: first.id) == nil)
        #expect(store.note(id: second.id) == nil)
        #expect(model.result.trash.isEmpty)
    }

    @Test func observerRegistrationIsUniqueAndRemovedOnDeinit() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = makeNote(text: "note")
        #expect(store.add(note))

        let controller = makeController(store)
        #expect(controller.libraryObserverCount == 0)

        var model: LibraryModel? = LibraryModel(controller: controller, clock: { fixedNow })
        #expect(controller.libraryObserverCount == 1)

        let second = LibraryModel(controller: controller, clock: { fixedNow })
        #expect(controller.libraryObserverCount == 2)

        controller.setPinned(id: note.id, pinned: true)
        #expect(model?.result.pinned.map(\.id) == [note.id])
        #expect(second.result.pinned.map(\.id) == [note.id])

        model = nil
        #expect(controller.libraryObserverCount == 1)
        #expect(second.result.pinned.map(\.id) == [note.id])
    }

    @Test func refreshDoesNotMutateTheStoreAndKeepsEphemeralNotesOut() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let durable = makeNote(text: "durable")
        let ephemeral = makeNote(text: "temporary", ephemeral: true)
        #expect(store.add(durable))
        #expect(store.add(ephemeral))

        let controller = makeController(store)
        let model = LibraryModel(controller: controller, clock: { fixedNow })
        let generation = store.mutationGeneration
        let notesBefore = store.notes

        model.refresh()

        #expect(store.mutationGeneration == generation)
        #expect(store.notes == notesBefore)
        #expect(controller.libraryNotes.allSatisfy { !$0.ephemeral })
        #expect(model.visibleNotes.map(\.id) == [durable.id])
    }

    @Test func workspaceAppNamesComeFromTheInjectedOverride() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = makeNote(
            text: "app",
            anchor: .app(bundleID: "com.apple.TextEdit")
        )
        #expect(store.add(note))

        let model = LibraryModel(
            controller: makeController(store),
            clock: { fixedNow },
            workspaceDisplayName: { key in
                if case .app(let bundleID) = key {
                    return bundleID == "com.apple.TextEdit" ? "TextEdit" : bundleID
                }
                return key.displayName
            }
        )

        let group = try #require(model.result.workspaces.first)
        #expect(model.displayName(for: group) == "TextEdit")
    }
}

@Test func workspaceNamesMarkMissingApps() {
    let textEdit = WorkspaceKey.app(bundleID: "com.apple.TextEdit")
    #expect(LibraryWorkspaceNames.displayName(for: textEdit) { _ in "TextEdit" } == "TextEdit")
    #expect(LibraryWorkspaceNames.displayName(for: textEdit) { _ in nil }
        == "com.apple.TextEdit (not installed)")
    #expect(LibraryWorkspaceNames.displayName(for: textEdit) { _ in "   " }
        == "com.apple.TextEdit (not installed)")
    #expect(LibraryWorkspaceNames.displayName(for: .host(name: "example.com")) { _ in nil }
        == "example.com")
}

@MainActor
@Test func searchSpansSectionsAndRevealClearsTheQuery() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
    let inbox = makeNote(text: "inbox note")
    let workspace = makeNote(text: "workspace needle")
    #expect(store.add(inbox))
    #expect(store.add(workspace))
    let record = WorkspaceRecord(keys: [.host(name: "example.com")], createdAt: fixedNow)
    try store.replaceWorkspaces([record])
    #expect(store.updateContent(id: workspace.id, change: .workspaceOverride(record.id)))

    let model = LibraryModel(controller: makeController(store), clock: { fixedNow })
    model.refresh()
    #expect(model.selectedSection == .inbox)

    model.searchText = "needle"
    #expect(model.visibleNotes.map(\.id) == [workspace.id])

    // Ordinary row selection keeps the query and the other matches.
    #expect(model.selectRow(workspace.id))
    #expect(model.searchText == "needle")
    #expect(model.selectedNoteID == workspace.id)

    // Explicit reveal clears the query.
    model.searchText = "needle"
    #expect(model.revealNote(workspace.id))
    #expect(model.searchText.isEmpty)
    #expect(model.selectedNoteID == workspace.id)
}

@MainActor
@Test func emptyTrashDeletesOnlyTheConfirmedNotes() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
    let first = makeNote(text: "first")
    let late = makeNote(text: "late")
    #expect(store.add(first))
    #expect(store.add(late))
    #expect(store.trash(id: first.id))

    let model = LibraryModel(controller: makeController(store), clock: { fixedNow })
    model.refresh()
    model.requestEmptyTrash()
    #expect(model.pendingEmptyTrash?.ids == [first.id])

    // A note trashed after the confirmation is not part of the confirmed set.
    #expect(store.trash(id: late.id))
    model.confirmEmptyTrash()

    #expect(store.note(id: first.id) == nil)
    #expect(store.note(id: late.id)?.trashedAt != nil)
}

@MainActor
@Test func effectiveQueryRulesKeepStoredAnchorQueries() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
    let page = PageURL(string: "https://example.com/watch?v=7", queryRules: [QueryRule(host: "example.com", key: "v")])!
    let note = makeNote(text: "query")
    #expect(store.add(note))
    #expect(store.updateContent(id: note.id, change: .anchor(.web(page: page, scope: .page))))

    let model = LibraryModel(controller: makeController(store), clock: { fixedNow })
    #expect(model.effectiveQueryRules.contains(QueryRule(host: "example.com", key: "v")))
    #expect(model.effectiveQueryRules.contains(QueryRule(host: "youtube.com", key: "v")))
}

@MainActor
@Test func rowSelectionKeepsTheSidebarContext() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
    let record = WorkspaceRecord(keys: [.host(name: "example.com")], createdAt: fixedNow)
    try store.replaceWorkspaces([record])
    let inbox = makeNote(text: "inbox")
    let page = makeNote(
        text: "tagged #work",
        anchor: .web(page: PageURL(host: "example.com", path: "/docs"), scope: .page),
        workspaceOverride: record.id
    )
    #expect(store.add(inbox))
    #expect(store.add(page))

    let model = LibraryModel(controller: makeController(store), clock: { fixedNow })
    model.refresh()

    // All: clicking an Inbox note must not switch the sidebar to Inbox.
    model.select(section: .all)
    #expect(model.selectRow(inbox.id))
    #expect(model.selectedSection == .all)
    #expect(model.selectedNoteID == inbox.id)

    // A workspace "All pages" view must not narrow to the note's page.
    model.select(section: .workspaces)
    model.select(workspace: .record(record.id))
    model.select(page: .all)
    #expect(model.selectRow(page.id))
    #expect(model.selectedPage == .all)

    // A tag view must keep the tag selected.
    model.select(tagKey: Tags.parse("tagged #work").first?.searchKey ?? "work")
    #expect(model.selectRow(page.id))
    #expect(model.selectedSection == .tags)
    #expect(model.selectedTagKey != nil)
}

@MainActor
@Test func revealKeepsTheQueryWhenTheNoteIsMissing() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
    let note = makeNote(text: "needle")
    #expect(store.add(note))

    let model = LibraryModel(controller: makeController(store), clock: { fixedNow })
    model.searchText = "needle"

    #expect(!model.revealNote(UUID()))
    #expect(model.searchText == "needle")
}
