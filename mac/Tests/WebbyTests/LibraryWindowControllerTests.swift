import Foundation
import Testing
@testable import Webby
import WebbyCore

private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbyLibraryWindow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeNote(
    text: String = "",
    trashedAt: Date? = nil,
    ephemeral: Bool = false
) -> Note {
    Note(
        text: text,
        frame: NoteFrame(),
        placement: .screen,
        trashedAt: trashedAt,
        createdAt: fixedNow,
        updatedAt: fixedNow,
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
private final class WindowAvailability: LibraryAppAvailabilityChecking {
    func isInstalled(bundleID: String) -> Bool { false }
    func isRunning(bundleID: String) -> Bool { false }
}

@MainActor
private final class WindowActivation: LibraryAppActivating {
    func activate(bundleID: String) -> Bool { false }
}

@MainActor
private final class WindowPageOpening: LibraryPageOpening {
    func open(page: PageURL, scope: WebScope) -> Bool { false }
}

@MainActor
private final class WindowOverlay: LibraryOverlayPresenting {
    func showAtAnchor(noteID: UUID) -> Bool { false }
}

@MainActor
private final class WindowCurrentApp: LibraryCurrentAppProviding {
    func currentBundleID() -> String? { nil }
}

@MainActor
private func makeWindowController(_ model: LibraryModel) -> LibraryWindowController {
    let actions = LibraryAnchorActions(
        appAvailability: WindowAvailability(),
        appActivation: WindowActivation(),
        pageOpening: WindowPageOpening(),
        overlayPresentation: WindowOverlay(),
        currentApp: WindowCurrentApp()
    )
    // No-op presentation keeps these tests headless: no NSApplication.run, no window.
    return LibraryWindowController(
        model: model,
        actions: actions,
        presentation: { _ in }
    )
}

@MainActor
@Suite struct LibraryWindowControllerTests {
    @Test func selectAndShowRejectMissingAndEphemeralNotes() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        let durable = makeNote(text: "durable")
        let ephemeral = makeNote(text: "ephemeral", ephemeral: true)
        #expect(store.add(durable))
        #expect(store.add(ephemeral))

        let controller = makeController(store)
        let window = makeWindowController(LibraryModel(controller: controller, clock: { fixedNow }))

        #expect(window.selectNote(UUID()) == false)
        #expect(window.selectNote(ephemeral.id) == false)
        #expect(window.showNote(UUID()) == false)
        #expect(window.showNote(ephemeral.id) == false)
        #expect(window.present(noteID: ephemeral.id) == false)
        #expect(window.model.selectedNoteID == nil)
    }

    @Test func selectAndShowAcceptExistingAndTrashedNotes() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        let active = makeNote(text: "active")
        let trashed = makeNote(text: "trashed", trashedAt: fixedNow)
        #expect(store.add(active))
        #expect(store.add(trashed))

        let controller = makeController(store)
        let model = LibraryModel(controller: controller, clock: { fixedNow })
        let window = makeWindowController(model)

        #expect(window.selectNote(active.id) == true)
        #expect(model.selectedNoteID == active.id)

        #expect(window.showNote(trashed.id) == true)
        #expect(model.selectedNoteID == trashed.id)
        #expect(model.selectedSection == .trash)

        #expect(window.present(noteID: active.id) == true)
        #expect(model.selectedNoteID == active.id)
    }

    @Test func repeatedPresentKeepsOneModelAndOneStoreSnapshot() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        let note = makeNote(text: "shared")
        #expect(store.add(note))

        let controller = makeController(store)
        let model = LibraryModel(controller: controller, clock: { fixedNow })
        let window = makeWindowController(model)

        window.present()
        let firstModel = window.model
        window.present()

        #expect(window.model === firstModel)
        #expect(window.model.notes.map(\.id) == model.notes.map(\.id))

        let second = makeNote(text: "added later")
        #expect(store.add(second))
        model.refresh()

        #expect(window.model === firstModel)
        #expect(window.model.notes.map(\.id) == model.notes.map(\.id))
        #expect(window.model.notes.contains { $0.id == second.id })
    }
}

@MainActor
@Test func quittingCommitsThePendingLibraryDraft() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
    let note = Note(text: "saved", frame: NoteFrame(), placement: .screen)
    #expect(store.add(note))
    let controller = makeController(store)
    let window = makeWindowController(LibraryModel(controller: controller, clock: { fixedNow }))

    window.draft.load(note: note)
    window.draft.text = "typed before quit"
    window.commitPendingEdits()

    #expect(store.note(id: note.id)?.text == "typed before quit")
    #expect(!window.draft.isDirty)
}
