import Foundation
import Testing
@testable import Webby
import WebbyCore

private let selectionNow = Date(timeIntervalSince1970: 1_800_000_000)

private func makeSelectionDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbyLibrarySelection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func selectionNote(
    id: UUID = UUID(),
    text: String,
    anchor: Anchor? = nil,
    workspaceOverride: UUID? = nil,
    trashedAt: Date? = nil,
    ephemeral: Bool = false
) -> Note {
    Note(
        id: id,
        anchor: anchor,
        workspaceOverride: workspaceOverride,
        text: text,
        frame: NoteFrame(),
        placement: .screen,
        trashedAt: trashedAt,
        createdAt: selectionNow,
        updatedAt: selectionNow,
        ephemeral: ephemeral
    )
}

@MainActor
private func makeSelectionController(_ store: NoteStore) -> NotesController {
    let permission = AccessibilityPermission()
    let monitor = ContextMonitor(permission: permission)
    return NotesController(
        store: store,
        monitor: monitor,
        permission: permission,
        themes: .fallback,
        now: { selectionNow }
    )
}

@MainActor
private func makeSelectionStore() throws -> (NoteStore, URL) {
    let directory = try makeSelectionDirectory()
    return (NoteStore(fileURL: directory.appendingPathComponent("notes.json")), directory)
}

private func selectionIDs(_ notes: [LibraryNote]) -> Set<UUID> {
    Set(notes.map(\.id))
}

@MainActor
@Suite struct LibraryModelSelectionAndCompiledTests {
    @Test func togglingSetAndClearingSelectionKeepFocusCoherent() throws {
        let (store, directory) = try makeSelectionStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
        let thirdID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!
        let first = selectionNote(id: firstID, text: "alpha")
        let second = selectionNote(id: secondID, text: "beta")
        let third = selectionNote(id: thirdID, text: "gamma")
        for note in [first, second, third] {
            #expect(store.add(note))
        }

        let model = LibraryModel(controller: makeSelectionController(store), clock: { selectionNow })
        model.select(section: .all)
        #expect(selectionIDs(model.visibleNotes) == [firstID, secondID, thirdID])

        #expect(model.toggleSelection(firstID))
        #expect(model.selectedNoteIDs == [firstID])
        #expect(model.focusedNoteID == firstID)

        #expect(model.toggleSelection(secondID))
        #expect(model.selectedNoteIDs == [firstID, secondID])
        #expect(model.focusedNoteID == secondID)

        #expect(!model.toggleSelection(firstID))
        #expect(model.selectedNoteIDs == [secondID])
        #expect(model.focusedNoteID == secondID)

        #expect(!model.toggleSelection(secondID))
        #expect(model.selectedNoteIDs.isEmpty)
        #expect(model.focusedNoteID == nil)

        // A fresh set selection focuses the lowest identifier when there is no
        // current focus, then keeps an existing focused row that stays selected.
        model.setSelection([firstID, secondID])
        #expect(model.selectedNoteIDs == [firstID, secondID])
        #expect(model.focusedNoteID == firstID)

        model.setSelection([secondID])
        #expect(model.selectedNoteIDs == [secondID])
        #expect(model.focusedNoteID == secondID)

        model.setSelection([firstID, secondID])
        #expect(model.selectedNoteIDs == [firstID, secondID])
        #expect(model.focusedNoteID == secondID)

        model.clearSelection()
        #expect(model.selectedNoteIDs.isEmpty)
        #expect(model.focusedNoteID == nil)

        // A plain row click collapses a multi-selection to one row and keeps the
        // sidebar context unchanged.
        #expect(model.selectRow(secondID))
        #expect(model.selectedNoteIDs == [secondID])
        #expect(model.focusedNoteID == secondID)
        #expect(model.selectedSection == .all)

        model.setSelection([firstID, secondID])
        #expect(model.selectedNoteIDs == [firstID, secondID])
        #expect(model.focusedNoteID == secondID)

        #expect(model.selectRow(firstID))
        #expect(model.selectedNoteIDs == [firstID])
        #expect(model.focusedNoteID == firstID)

        let beforeMissing = model.selectedNoteIDs
        let beforeFocus = model.focusedNoteID
        #expect(!model.selectRow(UUID()))
        #expect(model.selectedNoteIDs == beforeMissing)
        #expect(model.focusedNoteID == beforeFocus)
    }

    @Test func selectionPrunesTrashRestorePurgeSearchFilterAndRefresh() throws {
        let (store, directory) = try makeSelectionStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000011")!
        let secondID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000012")!
        let thirdID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000013")!
        let ephemeralID = UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000014")!
        let first = selectionNote(id: firstID, text: "alpha")
        let second = selectionNote(id: secondID, text: "beta")
        let third = selectionNote(id: thirdID, text: "gamma")
        let ephemeral = selectionNote(id: ephemeralID, text: "temporary", ephemeral: true)
        for note in [first, second, third, ephemeral] {
            #expect(store.add(note))
        }

        let model = LibraryModel(controller: makeSelectionController(store), clock: { selectionNow })
        model.select(section: .all)
        #expect(selectionIDs(model.visibleNotes) == [firstID, secondID, thirdID])

        // A caller that supplies an ephemeral ID directly still gets it pruned.
        model.selectedNoteIDs = [firstID, ephemeralID]
        model.refresh()
        #expect(model.selectedNoteIDs == [firstID])
        #expect(!model.selectedNoteIDs.contains(ephemeralID))

        #expect(!model.toggleSelection(ephemeralID))
        model.setSelection([firstID, ephemeralID])
        #expect(model.selectedNoteIDs == [firstID])

        #expect(model.toggleSelection(firstID))
        #expect(model.toggleSelection(secondID))
        #expect(model.selectedNoteIDs == [firstID, secondID])
        #expect(model.focusedNoteID == secondID)

        // Trash removes the note from the visible set and from the table selection.
        model.trash(id: firstID)
        #expect(model.selectedNoteIDs == [secondID])
        #expect(model.focusedNoteID == secondID)

        // Restore from Trash drops the now-hidden row and its focus.
        model.select(section: .trash)
        #expect(model.selectedNoteIDs.isEmpty)
        #expect(model.focusedNoteID == nil)
        #expect(model.selectNote(firstID))
        #expect(model.selectedNoteIDs == [firstID])
        model.restore(id: firstID)
        #expect(model.selectedNoteIDs.isEmpty)
        #expect(model.focusedNoteID == nil)

        // Search filters the multi-selection, and an empty query does not resurrect
        // an unfocused row.
        model.select(section: .all)
        #expect(model.toggleSelection(firstID))
        #expect(model.toggleSelection(secondID))
        #expect(model.focusedNoteID == secondID)
        model.searchText = "alpha"
        #expect(selectionIDs(model.visibleNotes) == [firstID])
        #expect(model.selectedNoteIDs == [firstID])
        #expect(model.focusedNoteID == nil)

        model.searchText = ""
        #expect(model.selectedNoteIDs == [firstID])
        #expect(model.focusedNoteID == nil)

        // Refresh keeps a visible focused row and prunes an injected ephemeral ID.
        #expect(model.selectRow(firstID))
        #expect(model.selectedNoteIDs == [firstID])
        #expect(model.focusedNoteID == firstID)
        model.selectedNoteIDs = [firstID, ephemeralID]
        model.refresh()
        #expect(model.selectedNoteIDs == [firstID])
        #expect(model.focusedNoteID == firstID)

        // Emptying Trash prunes the purged row.
        model.trash(id: thirdID)
        model.select(section: .trash)
        #expect(model.selectNote(thirdID))
        #expect(model.selectedNoteIDs == [thirdID])
        model.requestEmptyTrash()
        model.confirmEmptyTrash()
        #expect(model.selectedNoteIDs.isEmpty)
        #expect(model.focusedNoteID == nil)
    }

    @Test func compiledDocumentUsesSidebarScopeInsteadOfSearchResults() throws {
        let (store, directory) = try makeSelectionStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let recordID = UUID(uuidString: "11111111-0000-0000-0000-000000000021")!
        let page = PageURL(host: "example.com", path: "/docs/install")
        let record = WorkspaceRecord(
            id: recordID,
            title: "Docs",
            keys: [.host(name: "example.com")],
            createdAt: selectionNow
        )
        try store.replaceWorkspaces([record])

        let inbox = selectionNote(text: "inbox needle")
        let pageNote = selectionNote(
            text: "page needle",
            anchor: .web(page: page, scope: .page),
            workspaceOverride: recordID
        )
        #expect(store.add(inbox))
        #expect(store.add(pageNote))

        let model = LibraryModel(controller: makeSelectionController(store), clock: { selectionNow })
        #expect(model.selectedSection == .inbox)

        // A query that matches a workspace note must not change the Inbox compile.
        model.searchText = "page needle"
        #expect(model.visibleNotes.map(\.id) == [pageNote.id])
        let inboxDocument = try #require(model.compiledDocument())
        #expect(inboxDocument.scope == .workspace(.inbox))
        #expect(inboxDocument.title == "Inbox")
        #expect(Set(inboxDocument.sections.flatMap { $0.notes.map(\.id) }) == [inbox.id])

        // The page compile follows the selected note's page, not the query.
        #expect(model.selectNote(pageNote.id))
        #expect(model.selectedPage == .page(page))
        model.searchText = "inbox needle"
        #expect(model.visibleNotes.map(\.id) == [inbox.id])
        let pageDocument = try #require(model.compiledDocument())
        #expect(pageDocument.scope == .page(.record(recordID), page))
        #expect(Set(pageDocument.sections.flatMap { $0.notes.map(\.id) }) == [pageNote.id])

        // A workspace "All pages" selection compiles the whole workspace.
        model.select(workspace: .record(recordID))
        model.select(page: .all)
        let workspaceDocument = try #require(model.compiledDocument())
        #expect(workspaceDocument.scope == .workspace(.record(recordID)))
        #expect(Set(workspaceDocument.sections.flatMap { $0.notes.map(\.id) }) == [pageNote.id])
    }
}
