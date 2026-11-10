import Foundation
import Testing
@testable import Webby
import WebbyCore

/// One look per workspace override, like a workspace skin.
@MainActor
private struct WorkspaceThemes: NoteThemeSource {
    let looks: [UUID: NoteThemes]

    func themes(for note: Note) -> NoteThemes {
        note.workspaceOverride.flatMap { looks[$0] } ?? .fallback
    }

    func themes() -> NoteThemes { .fallback }
}

@MainActor
@Suite struct NotesControllerSkinTests {
    @Test func movingAnOpenNoteToAnotherWorkspaceShowsThatWorkspacesSkin() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebbyNoteSkins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        let first = WorkspaceRecord(keys: [.host(name: "one.example")])
        let second = WorkspaceRecord(keys: [.host(name: "two.example")])
        try store.replaceWorkspaces([first, second])
        let bundleID = "com.example.App"
        let note = Note(
            anchor: .app(bundleID: bundleID),
            workspaceOverride: first.id,
            frame: NoteFrame(),
            placement: .screen
        )
        #expect(store.add(note))

        var firstLook = NoteThemes.fallback
        firstLook.revision = 1
        var secondLook = NoteThemes.fallback
        secondLook.revision = 2
        let permission = AccessibilityPermission()
        let monitor = ContextMonitor(permission: permission)
        monitor.app = ContextMonitor.FrontApp(bundleID: bundleID, pid: 1, name: "Example")
        let controller = NotesController(
            store: store,
            monitor: monitor,
            permission: permission,
            skins: WorkspaceThemes(looks: [first.id: firstLook, second.id: secondLook]),
            assets: SkinAssetCache(folder: { _ in nil })
        )
        defer { controller.windows.values.forEach { $0.close() } }

        controller.layout()
        let overlay = try #require(controller.windows[note.id])
        #expect(overlay.model.themes == firstLook)

        controller.setLibraryAttachment(id: note.id, anchor: .app(bundleID: bundleID), workspace: second.id)

        #expect(controller.windows[note.id] === overlay)
        #expect(overlay.model.themes == secondLook)
    }
}
