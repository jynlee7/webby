import Foundation
import Testing
@testable import Webby
import WebbyCore

private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
private final class Counter {
    var value = 0
}

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbyLibraryBridge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeNote(
    text: String = "",
    anchor: Anchor? = nil,
    tab: TabBinding? = nil,
    trashedAt: Date? = nil,
    ephemeral: Bool = false
) -> Note {
    Note(
        anchor: anchor,
        tab: tab,
        text: text,
        frame: NoteFrame(),
        placement: .screen,
        trashedAt: trashedAt,
        createdAt: fixedNow,
        updatedAt: fixedNow,
        ephemeral: ephemeral
    )
}

private func makeTab() -> TabBinding {
    TabBinding(
        browser: "com.google.Chrome",
        profile: "profile",
        session: "session",
        tabID: 7,
        windowID: 2,
        index: 0,
        lastURL: "https://example.com/a"
    )
}

@MainActor
private func makeController(_ store: NoteStore, now: Date = fixedNow) -> NotesController {
    let permission = AccessibilityPermission()
    let monitor = ContextMonitor(permission: permission)
    return NotesController(
        store: store,
        monitor: monitor,
        permission: permission,
        themes: .fallback,
        now: { now }
    )
}

@MainActor
@Suite struct NotesControllerLibraryTests {
    @Test func ephemeralNotesAreExcludedAndRefusedByLibrary() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        let ephemeral = makeNote(text: "secret", ephemeral: true)
        let durable = makeNote(text: "public")
        #expect(store.add(ephemeral))
        #expect(store.add(durable))

        let controller = makeController(store)
        let changes = Counter()
        controller.onLibraryChange = { changes.value += 1 }

        #expect(controller.libraryNotes.map(\.id) == [durable.id])
        #expect(controller.libraryWorkspaces.isEmpty)

        let generation = store.mutationGeneration
        controller.updateLibraryText(id: ephemeral.id, text: "changed")
        controller.setPinned(id: ephemeral.id, pinned: true)
        controller.setHidden(id: ephemeral.id, hidden: true)
        controller.setExcludedFromAgent(id: ephemeral.id, excluded: true)
        controller.setLibraryAttachment(id: ephemeral.id, anchor: .app(bundleID: "com.example.App"), workspace: nil)
        controller.trashLibraryNote(id: ephemeral.id)

        #expect(store.mutationGeneration == generation)
        #expect(store.note(id: ephemeral.id)?.text == "secret")
        #expect(store.note(id: ephemeral.id)?.pinnedAt == nil)
        #expect(store.note(id: ephemeral.id)?.hidden == false)
        #expect(store.note(id: ephemeral.id)?.excludedFromAgent == false)
        #expect(store.note(id: ephemeral.id)?.trashedAt == nil)
        #expect(changes.value == 0)

        #expect(store.trash(id: ephemeral.id, now: fixedNow))
        #expect(controller.emptyTrash(ids: Set(store.notes.filter { $0.trashedAt != nil }.map(\.id))) == 0)
        #expect(store.note(id: ephemeral.id) != nil)
        #expect(changes.value == 0)
    }

    @Test func libraryTextCommitsDraftsAndSilentlySyncsTheOverlay() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        let original = makeNote(text: "base")
        #expect(store.add(original))

        let controller = makeController(store)
        let changes = Counter()
        let textChanges = Counter()
        controller.onLibraryChange = { changes.value += 1 }

        let model = controller.overlayController(for: original).model
        model.onTextChange = { textChanges.value += 1 }
        model.text = "draft"

        controller.updateLibraryText(id: original.id, text: "library")

        let updated = try #require(store.note(id: original.id))
        #expect(updated.text == "library")
        #expect(updated.revision == original.revision + 2)
        #expect(model.text == "library")
        // One notification for the committed overlay draft, one for the Library edit.
        #expect(changes.value == 2)
        #expect(textChanges.value == 0)
        #expect(store.hasUnsavedChanges)

        model.setTextSilently("library")
        #expect(textChanges.value == 0)

        controller.setPinned(id: original.id, pinned: true)
        #expect(store.note(id: original.id)?.text == "library")
        #expect(store.note(id: original.id)?.revision == original.revision + 2)
        #expect(model.text == "library")
        #expect(changes.value == 3)
    }

    @Test func attachmentOverrideAndLibraryTogglesUseTheExpectedChanges() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        let record = WorkspaceRecord(keys: [.host(name: "example.com")])
        try store.replaceWorkspaces([record])
        let original = makeNote(text: "note", tab: makeTab())
        #expect(store.add(original))

        let controller = makeController(store)
        let changes = Counter()
        controller.onLibraryChange = { changes.value += 1 }

        controller.setLibraryAttachment(
            id: original.id,
            anchor: .app(bundleID: "com.example.App"),
            workspace: record.id
        )
        var updated = try #require(store.note(id: original.id))
        #expect(updated.anchor == .app(bundleID: "com.example.App"))
        #expect(updated.tab == nil)
        #expect(updated.workspaceOverride == record.id)
        #expect(updated.revision == original.revision + 1)
        #expect(changes.value == 1)

        controller.setLibraryAttachment(id: original.id, anchor: nil, workspace: nil)
        updated = try #require(store.note(id: original.id))
        #expect(updated.anchor == nil)
        #expect(updated.tab == nil)
        #expect(updated.workspaceOverride == nil)
        #expect(updated.revision == original.revision + 2)
        #expect(changes.value == 2)

        controller.setPinned(id: original.id, pinned: true)
        #expect(store.note(id: original.id)?.pinnedAt != nil)
        #expect(store.note(id: original.id)?.revision == original.revision + 2)
        #expect(changes.value == 3)

        controller.setHidden(id: original.id, hidden: true)
        #expect(store.note(id: original.id)?.hidden == true)
        #expect(store.note(id: original.id)?.revision == original.revision + 2)
        #expect(changes.value == 4)

        controller.setExcludedFromAgent(id: original.id, excluded: true)
        #expect(store.note(id: original.id)?.excludedFromAgent == true)
        #expect(store.note(id: original.id)?.revision == original.revision + 2)
        #expect(changes.value == 5)

        controller.setLibraryAttachment(id: original.id, anchor: nil, workspace: UUID())
        #expect(changes.value == 5)
        #expect(store.note(id: original.id)?.workspaceOverride == nil)
    }

    @Test func createLibraryNoteWorksWithoutAnAppAndMaterializesOneWorkspace() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.json")
        let store = NoteStore(fileURL: url)

        let controller = makeController(store)
        let changes = Counter()
        controller.onLibraryChange = { changes.value += 1 }
        #expect(controller.appName == nil)

        let inboxID = try #require(controller.createLibraryNote(destination: .inbox))
        let inbox = try #require(store.note(id: inboxID))
        #expect(inbox.anchor == nil)
        #expect(inbox.tab == nil)
        #expect(inbox.workspaceOverride == nil)
        #expect(inbox.frame == NoteFrame())
        #expect(inbox.placement == .screen)
        #expect(!inbox.ephemeral)
        #expect(store.workspaces.isEmpty)
        #expect(changes.value == 1)
        #expect(store.hasUnsavedChanges)

        let key = WorkspaceKey.host(name: "example.com")
        let generationBeforeWorkspace = store.mutationGeneration
        let workspaceID = try #require(controller.createLibraryNote(destination: .workspace(key)))
        #expect(store.mutationGeneration == generationBeforeWorkspace + 1)
        let record = try #require(store.workspaces.first)
        #expect(store.workspaces.count == 1)
        #expect(record.keys == [key])
        #expect(store.note(id: workspaceID)?.workspaceOverride == record.id)
        #expect(changes.value == 2)

        let reusedID = try #require(controller.createLibraryNote(destination: .workspace(key)))
        #expect(store.workspaces.count == 1)
        #expect(store.note(id: reusedID)?.workspaceOverride == record.id)
        #expect(changes.value == 3)

        let byRecordID = try #require(controller.createLibraryNote(destination: .record(record.id)))
        #expect(store.note(id: byRecordID)?.workspaceOverride == record.id)
        #expect(store.workspaces.count == 1)
        #expect(changes.value == 4)

        #expect(controller.createLibraryNote(destination: .record(UUID())) == nil)
        #expect(changes.value == 4)

        let request = store.saveRequest()
        try request.commitNow()
        let loaded = NoteStore(fileURL: url)
        #expect(loaded.workspaces == [record])
        #expect(loaded.note(id: inboxID) != nil)
        #expect(loaded.note(id: workspaceID)?.workspaceOverride == record.id)
        #expect(loaded.note(id: reusedID)?.workspaceOverride == record.id)
        #expect(loaded.note(id: byRecordID)?.workspaceOverride == record.id)
    }

    @Test func trashRestoreAndEmptyTrashStayWithinTheirBoundaries() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        let active = makeNote(text: "active")
        let trashed = makeNote(text: "trashed", trashedAt: fixedNow.addingTimeInterval(-60))
        let ephemeralTrashed = makeNote(
            text: "ephemeral",
            trashedAt: fixedNow.addingTimeInterval(-60),
            ephemeral: true
        )
        #expect(store.add(active))
        #expect(store.add(trashed))
        #expect(store.add(ephemeralTrashed))

        let controller = makeController(store)
        let changes = Counter()
        controller.onLibraryChange = { changes.value += 1 }

        controller.trashLibraryNote(id: active.id)
        #expect(store.note(id: active.id)?.trashedAt == fixedNow)
        #expect(changes.value == 1)

        controller.trashLibraryNote(id: active.id)
        #expect(changes.value == 1)

        controller.restoreLibraryNote(id: active.id)
        #expect(store.note(id: active.id)?.trashedAt == nil)
        #expect(changes.value == 2)

        controller.restoreLibraryNote(id: active.id)
        #expect(changes.value == 2)

        #expect(controller.emptyTrash(ids: Set(store.notes.filter { $0.trashedAt != nil }.map(\.id))) == 1)
        #expect(store.note(id: trashed.id) == nil)
        #expect(store.note(id: active.id) != nil)
        #expect(store.note(id: ephemeralTrashed.id) != nil)
        #expect(changes.value == 3)
        #expect(controller.emptyTrash(ids: Set(store.notes.filter { $0.trashedAt != nil }.map(\.id))) == 0)
        #expect(changes.value == 3)
    }

    @Test func readOnlyStoreRefusesLibraryMutations() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.json")
        try Data(#"{"version":99,"notes":[],"workspaces":[]}"#.utf8).write(to: url)
        let store = NoteStore(fileURL: url)
        #expect(store.mode != .writable)

        let controller = makeController(store)
        let changes = Counter()
        controller.onLibraryChange = { changes.value += 1 }

        #expect(controller.libraryNotes.isEmpty)
        #expect(controller.createLibraryNote(destination: .inbox) == nil)
        controller.updateLibraryText(id: UUID(), text: "new")
        controller.setPinned(id: UUID(), pinned: true)
        controller.trashLibraryNote(id: UUID())
        controller.restoreLibraryNote(id: UUID())
        #expect(controller.emptyTrash(ids: Set(store.notes.filter { $0.trashedAt != nil }.map(\.id))) == 0)
        #expect(changes.value == 0)
        #expect(store.mutationGeneration == 0)
    }

    @Test func startupPurgeUsesTheExactCutoffOnceAndSchedulesASave() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.json")
        let store = NoteStore(fileURL: url)
        let cutoff = fixedNow.addingTimeInterval(-NotesController.trashRetentionPeriod)
        let beforeCutoff = makeNote(text: "old", trashedAt: cutoff.addingTimeInterval(-1))
        let boundary = makeNote(text: "boundary", trashedAt: cutoff)
        let afterCutoff = makeNote(text: "new", trashedAt: cutoff.addingTimeInterval(1))
        let ephemeral = makeNote(
            text: "ephemeral",
            trashedAt: cutoff.addingTimeInterval(-1),
            ephemeral: true
        )
        #expect(store.add(beforeCutoff))
        #expect(store.add(boundary))
        #expect(store.add(afterCutoff))
        #expect(store.add(ephemeral))

        let controller = makeController(store)
        let libraryChanges = Counter()
        let statusChanges = Counter()
        controller.onLibraryChange = { libraryChanges.value += 1 }
        controller.onStatusChange = { statusChanges.value += 1 }

        controller.start()

        #expect(store.note(id: beforeCutoff.id) == nil)
        #expect(store.note(id: boundary.id) != nil)
        #expect(store.note(id: afterCutoff.id) != nil)
        #expect(store.note(id: ephemeral.id) != nil)
        #expect(libraryChanges.value == 1)
        #expect(statusChanges.value > 0)
        #expect(store.hasUnsavedChanges)

        let generation = store.mutationGeneration
        controller.start()
        #expect(libraryChanges.value == 1)
        #expect(store.mutationGeneration == generation)
        #expect(store.note(id: beforeCutoff.id) == nil)

        let request = store.saveRequest()
        try request.commitNow()
        let loaded = NoteStore(fileURL: url)
        #expect(loaded.note(id: beforeCutoff.id) == nil)
        #expect(loaded.note(id: boundary.id) != nil)
        #expect(loaded.note(id: afterCutoff.id) != nil)
    }

    @Test func startupPurgeDoesNothingWhenReadOnly() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.json")
        try Data(#"{"version":99,"notes":[],"workspaces":[]}"#.utf8).write(to: url)
        let store = NoteStore(fileURL: url)
        let controller = makeController(store)
        let libraryChanges = Counter()
        controller.onLibraryChange = { libraryChanges.value += 1 }

        controller.start()

        #expect(libraryChanges.value == 0)
        #expect(store.mutationGeneration == 0)
        #expect(!store.hasUnsavedChanges)
    }

    @Test func statusOnlyChangesDoNotNotifyTheLibraryStream() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let store = NoteStore(fileURL: parent.appendingPathComponent("notes.json"))
        #expect(store.add(makeNote(text: "note")))

        let controller = makeController(store)
        let libraryChanges = Counter()
        let statusChanges = Counter()
        controller.onLibraryChange = { libraryChanges.value += 1 }
        controller.onStatusChange = { statusChanges.value += 1 }

        // Make the save path fail after the store loaded, so only the save status changes.
        try FileManager.default.removeItem(at: parent)
        try Data("blocked".utf8).write(to: parent)
        controller.retrySave()
        for _ in 0..<200 where statusChanges.value == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(statusChanges.value > 0)
        #expect(libraryChanges.value == 0)
    }
}
