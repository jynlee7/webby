import CoreGraphics
import Foundation
import Testing
@testable import WebbyCore

/// What a user sees when they leave an app and come back, including after Webby relaunches.
@Suite struct RestoreRuleTests {
    private let textEdit = Context(appBundleID: "com.apple.TextEdit")
    private let finder = Context(appBundleID: "com.apple.finder")
    private let screens = [CGRect(x: 0, y: 25, width: 1440, height: 875)]
    private let window = CGRect(x: 100, y: 200, width: 800, height: 600)
    private let collapsedHeight: CGFloat = 32

    private func withStoreURL(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("notes.json"))
    }

    private func note(x: Double, collapsed: Bool = false, hidden: Bool = false) -> Note {
        Note(anchor: .app(bundleID: "com.apple.TextEdit"),
             text: "note at \(x)",
             frame: NoteFrame(x: x, y: 40, width: 240, height: 180),
             placement: .window, collapsed: collapsed, hidden: hidden)
    }

    private func plan(_ store: NoteStore, _ context: Context, window: CGRect? = nil) -> [OverlayPlan] {
        OverlayPlanner.plan(notes: store.notes, context: context, window: window ?? self.window,
                            screens: screens, collapsedHeight: collapsedHeight)
    }

    @Test func switchingAwayHidesNotesAndReturningRestoresThemAsTheyWere() throws {
        try withStoreURL { url in
            let store = NoteStore(fileURL: url)
            let expanded = note(x: 20)
            let collapsed = note(x: 300, collapsed: true)
            store.add(expanded)
            store.add(collapsed)

            let before = plan(store, textEdit)
            #expect(plan(store, finder).isEmpty)
            let after = plan(store, textEdit)

            #expect(after == before)
            #expect(after.map(\.collapsed) == [false, true])
            #expect(after[1].frame.height == collapsedHeight)
        }
    }

    @Test func hiddenNoteStaysHiddenOnReturnUntilShown() throws {
        try withStoreURL { url in
            let store = NoteStore(fileURL: url)
            let shown = note(x: 20)
            let hidden = note(x: 300)
            store.add(shown)
            store.add(hidden)
            store.updateLayout(id: hidden.id, change: .hidden(true))

            _ = plan(store, finder)
            #expect(plan(store, textEdit).map(\.noteID) == [shown.id])
            #expect(OverlayPlanner.contextNotes(store.notes, context: textEdit).hidden.map(\.id) == [hidden.id])

            // "Show all" from the menu bar.
            for note in OverlayPlanner.contextNotes(store.notes, context: textEdit).hidden {
                store.updateLayout(id: note.id, change: .hidden(false))
            }
            #expect(plan(store, textEdit).map(\.noteID) == [shown.id, hidden.id])
        }
    }

    @Test func notesComeBackAtTheSameWindowRelativePlaceAfterRelaunch() throws {
        try withStoreURL { url in
            let expanded = note(x: 20)
            let collapsed = note(x: 300, collapsed: true)
            let hidden = note(x: 500, hidden: true)
            let trashed = note(x: 600)
            do {
                let store = NoteStore(fileURL: url)
                for note in [expanded, collapsed, hidden, trashed] { store.add(note) }
                store.trash(id: trashed.id)
                try store.save()
            }

            // Webby relaunched and TextEdit's window opened somewhere else.
            let relaunched = NoteStore(fileURL: url)
            let movedWindow = CGRect(x: 400, y: 300, width: 800, height: 600)
            let planned = plan(relaunched, textEdit, window: movedWindow)

            #expect(planned == [
                OverlayPlan(noteID: expanded.id, frame: CGRect(x: 420, y: 340, width: 240, height: 180), collapsed: false),
                OverlayPlan(noteID: collapsed.id, frame: CGRect(x: 700, y: 340, width: 240, height: collapsedHeight), collapsed: true),
            ])
            #expect(OverlayPlanner.contextNotes(relaunched.notes, context: textEdit).hidden.map(\.id) == [hidden.id])
        }
    }

    @Test func movedNoteReturnsWhereTheUserLeftIt() throws {
        try withStoreURL { url in
            let store = NoteStore(fileURL: url)
            let anchored = note(x: 20)
            store.add(anchored)

            let dropped = CGRect(x: 600, y: 500, width: 260, height: 200)
            let stored = OverlayPlanner.storedFrame(forPanel: dropped, note: anchored, window: window)
            store.updateLayout(id: anchored.id, change: .frame(stored))
            try store.save()

            let relaunched = NoteStore(fileURL: url)
            #expect(plan(relaunched, textEdit).first?.frame == dropped)
            #expect(relaunched.note(id: anchored.id)?.revision == anchored.revision)
        }
    }

    @Test func trashedNoteNeverReturnsUntilRestored() throws {
        try withStoreURL { url in
            let store = NoteStore(fileURL: url)
            let anchored = note(x: 20)
            store.add(anchored)
            store.trash(id: anchored.id)
            #expect(plan(store, textEdit).isEmpty)
            #expect(OverlayPlanner.contextNotes(store.notes, context: textEdit) == ContextNotes())

            store.restore(id: anchored.id)
            #expect(plan(store, textEdit).map(\.noteID) == [anchored.id])
        }
    }

    @Test func collapsingAndHidingAreNotContentEdits() throws {
        try withStoreURL { url in
            let store = NoteStore(fileURL: url)
            let anchored = note(x: 20)
            store.add(anchored)
            store.updateLayout(id: anchored.id, change: .collapsed(true))
            store.updateLayout(id: anchored.id, change: .hidden(true))
            store.updateLayout(id: anchored.id, change: .hidden(false))
            store.updateLayout(id: anchored.id, change: .collapsed(false))

            let current = try #require(store.note(id: anchored.id))
            #expect(current.revision == anchored.revision)
            #expect(current.updatedAt == anchored.updatedAt)
        }
    }
}
