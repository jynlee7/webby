import Foundation
import Testing
@testable import Webby
import WebbyCore

private let rewriteNow = Date(timeIntervalSince1970: 1_800_000_000)

private func rewriteNote(_ id: String) throws -> Note {
    let page = try #require(PageURL(string: "https://youtube.com/watch?v=\(id)", queryRules: QueryRules.builtIns))
    return Note(
        anchor: .web(page: page, scope: .page),
        text: id,
        frame: NoteFrame(),
        placement: .screen,
        createdAt: rewriteNow,
        updatedAt: rewriteNow
    )
}

@MainActor
private func rewriteController(_ store: NoteStore) -> NotesController {
    let permission = AccessibilityPermission()
    return NotesController(
        store: store,
        monitor: ContextMonitor(permission: permission),
        permission: permission,
        themes: .fallback,
        now: { rewriteNow }
    )
}

@MainActor
@Suite struct NotesControllerAnchorRewriteTests {
    @Test func convertRewritesEveryAnchorAsOneMutationNotification() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebbyRewrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        let a = try rewriteNote("A")
        let b = try rewriteNote("B")
        #expect(store.add(a) && store.add(b))
        let controller = rewriteController(store)

        let settings = QueryRulesPane.removing(host: "youtube.com", key: "v", from: .default)
        let plan = try #require(
            QueryRulesPane(settings: settings, notes: controller.libraryNotes)
                .convertPlan(host: "youtube.com", key: "v")
        )
        var notifications = 0
        controller.addLibraryObserver { notifications += 1 }

        #expect(controller.applyAnchorRewrites(plan.rewrites) == 2)
        #expect(notifications == 1)
        let expected = Anchor.web(page: PageURL(host: "youtube.com", path: "/watch"), scope: .page)
        for note in [a, b] {
            let updated = try #require(store.note(id: note.id))
            #expect(updated.anchor == expected)
            #expect(updated.revision == note.revision + 1)
        }
        #expect(store.hasUnsavedChanges)
    }

    @Test func readOnlyStoreChangesNothing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebbyRewrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.json")
        try Data(#"{"version":99,"notes":[],"workspaces":[]}"#.utf8).write(to: url)
        let controller = rewriteController(NoteStore(fileURL: url))

        let rewrite = QueryRulesPane.AnchorRewrite(
            noteID: UUID(),
            anchor: .web(page: PageURL(host: "youtube.com", path: "/watch"), scope: .page)
        )
        #expect(controller.applyAnchorRewrites([rewrite]) == 0)
        #expect(!controller.store.hasUnsavedChanges)
    }
}
