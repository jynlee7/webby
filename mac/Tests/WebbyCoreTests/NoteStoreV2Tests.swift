import Foundation
import Testing
@testable import WebbyCore

@Suite struct NoteStoreV2Tests {
    private let created = Date(timeIntervalSinceReferenceDate: 123_456.789)
    private let edited = Date(timeIntervalSinceReferenceDate: 123_500.125)

    private var tab: TabBinding {
        TabBinding(browser: "com.google.Chrome", profile: "profile", session: "session", tabID: 1,
                   windowID: 2, index: 0, lastURL: "https://example.com/a", lastTitle: "Example",
                   closedAt: nil, pendingRestore: false)
    }

    private func withStore(_ body: (NoteStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.json")
        try body(NoteStore(fileURL: url, now: created), url)
    }

    private func note(tab: TabBinding? = nil, ephemeral: Bool = false) -> Note {
        Note(anchor: .app(bundleID: "com.apple.TextEdit"), tab: tab, text: "original",
             revision: 5, frame: NoteFrame(x: 1, y: 2, width: 300, height: 200),
             placement: .window, createdAt: created, updatedAt: created, ephemeral: ephemeral)
    }

    @Test func contentEditsAdvanceRevisionOnce() throws {
        let changes: [NoteStore.ContentChange] = [
            .text("new text"),
            .anchor(nil),
            .workspaceOverride(UUID()),
            .attachment(anchor: nil, tab: tab),
        ]
        for change in changes {
            try withStore { store, _ in
                let original = note()
                store.add(original)
                #expect(store.updateContent(id: original.id, change: change, now: edited))
                let updated = try #require(store.note(id: original.id))
                #expect(updated.revision == 6)
                #expect(updated.updatedAt == edited)
                #expect(updated.createdAt == created)
                #expect(updated.id == original.id)
            }
        }
    }

    @Test func exhaustedRevisionRejectsTheEditWithoutChangingContent() throws {
        try withStore { store, _ in
            var original = note()
            original.revision = Int.max
            store.add(original)
            #expect(!store.updateContent(id: original.id, change: .text("new text"), now: edited))
            #expect(store.note(id: original.id) == original)
        }
    }

    @Test func layoutAndSettingsNeverCountAsContentEdits() throws {
        let changes: [NoteStore.LayoutChange] = [
            .frame(NoteFrame(x: 7, y: 8, width: 400, height: 250)),
            .placement(.screen), .collapsed(true), .hidden(true),
            .appearance(NoteAppearance(paletteIndex: 2, hideDecoration: true)),
            .pinnedAt(edited), .excludedFromAgent(true), .keep,
        ]
        for change in changes {
            try withStore { store, _ in
                let original = note(ephemeral: true)
                store.add(original)
                #expect(store.updateLayout(id: original.id, change: change))
                let updated = try #require(store.note(id: original.id))
                #expect(updated.revision == original.revision)
                #expect(updated.updatedAt == original.updatedAt)
                #expect(updated.text == original.text)
                #expect(updated.anchor == original.anchor)
            }
        }
    }

    @Test func bindingBookkeepingPreservesContentMetadata() throws {
        try withStore { store, _ in
            let original = note(tab: tab)
            store.add(original)
            #expect(store.updateBinding(id: original.id) {
                $0.tabID = 10
                $0.windowID = 20
                $0.index = 3
                $0.session = "new session"
                $0.lastURL = "https://other.example/b"
                $0.lastTitle = "Other"
                $0.closedAt = edited
                $0.pendingRestore = true
            })
            let updated = try #require(store.note(id: original.id))
            #expect(updated.revision == original.revision)
            #expect(updated.updatedAt == original.updatedAt)
            #expect(updated.tab?.tabID == 10)
            #expect(updated.tab?.closedAt == edited)
            #expect(updated.tab?.pendingRestore == true)
            #expect(store.updateContent(id: original.id,
                                        change: .attachment(anchor: updated.anchor, tab: nil), now: edited))
            #expect(store.note(id: original.id)?.revision == 6)
            #expect(store.note(id: original.id)?.tab == nil)
        }
    }

    @Test func noOpAndMissingIDEditsDoNothing() throws {
        try withStore { store, _ in
            let original = note(tab: tab)
            store.add(original)
            #expect(!store.updateContent(id: original.id, change: .text(original.text), now: edited))
            #expect(!store.updateContent(id: original.id, change: .anchor(original.anchor), now: edited))
            #expect(!store.updateContent(id: original.id, change: .workspaceOverride(nil), now: edited))
            var binding = tab
            binding.lastURL = "https://different.example"
            #expect(!store.updateContent(id: original.id,
                                         change: .attachment(anchor: original.anchor, tab: binding), now: edited))
            #expect(!store.updateBinding(id: original.id) { _ in })
            #expect(!store.updateLayout(id: original.id, change: .collapsed(false)))
            #expect(!store.updateContent(id: UUID(), change: .text("missing"), now: edited))
            #expect(!store.updateLayout(id: UUID(), change: .hidden(true)))
            #expect(!store.updateBinding(id: UUID()) { $0.tabID = 8 })
            #expect(store.note(id: original.id) == original)
        }
    }

    @Test func trashRestoresAndPurgesOnlyBeforeCutoff() throws {
        try withStore { store, _ in
            let old = note()
            let boundary = note()
            let active = note()
            [old, boundary, active].forEach { store.add($0) }
            #expect(store.trash(id: old.id, now: created))
            #expect(store.trash(id: boundary.id, now: edited))
            #expect(!store.trash(id: boundary.id, now: edited))
            #expect(store.note(id: old.id)?.revision == 5)
            #expect(store.note(id: old.id)?.updatedAt == created)
            #expect(store.notes(matching: .app(bundleID: "com.apple.TextEdit")).map(\.id) == [active.id])
            #expect(store.restore(id: old.id))
            #expect(!store.restore(id: old.id))
            #expect(store.note(id: old.id)?.revision == 5)
            store.trash(id: old.id, now: created)
            #expect(store.purgeTrash(olderThan: edited) == 1)
            #expect(store.note(id: old.id) == nil)
            #expect(store.note(id: boundary.id) != nil)
            #expect(store.note(id: active.id) == active)
            try store.save()
            let loaded = NoteStore(fileURL: store.fileURL)
            #expect(loaded.note(id: boundary.id)?.trashedAt == edited)
            #expect(loaded.restore(id: boundary.id))
            #expect(loaded.note(id: boundary.id)?.revision == 5)
        }
    }

    @Test func ephemeralNotesNeverReachDiskUntilKept() throws {
        try withStore { store, url in
            let transient = note(ephemeral: true)
            let durable = note()
            store.add(transient)
            store.add(durable)
            try store.save()
            let first = NoteStore(fileURL: url)
            #expect(first.notes == [durable])
            #expect(store.notes.count == 2)
            #expect(store.updateLayout(id: transient.id, change: .keep))
            try store.save()
            let second = NoteStore(fileURL: url)
            #expect(second.notes.count == 2)
            #expect(second.notes.allSatisfy { !$0.ephemeral })
            #expect(second.note(id: transient.id)?.revision == transient.revision)
        }
    }

    @Test func inboxAndWorkspaceOnlyNotesPersistWithoutOverlay() throws {
        try withStore { store, url in
            let record = WorkspaceRecord(title: "Example", keys: [.host(name: "example.com")])
            try store.replaceWorkspaces([record])
            let inbox = Note(frame: NoteFrame(), placement: .screen, createdAt: created)
            let workspaceNote = Note(workspaceOverride: record.id, frame: NoteFrame(), placement: .screen,
                                     createdAt: created)
            store.add(inbox)
            store.add(workspaceNote)
            #expect(store.notes(matching: .app(bundleID: "com.apple.TextEdit")).isEmpty)
            try store.save()
            let loaded = NoteStore(fileURL: url)
            #expect(loaded.notes == [inbox, workspaceNote])
            #expect(loaded.workspaces == [record])
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect(Set(object.keys) == ["version", "notes", "workspaces"])
            #expect(object["version"] as? Int == 2)
        }
    }

    @Test func workspaceValidationDoesNotStrandDanglingOverrides() throws {
        try withStore { store, url in
            let key = WorkspaceKey.host(name: "example.com")
            let first = WorkspaceRecord(keys: [key])
            let second = WorkspaceRecord(keys: [key])
            #expect(throws: (any Error).self) { try store.replaceWorkspaces([first, second]) }
            #expect(store.workspaces.isEmpty)
            try store.replaceWorkspaces([first])
            var dangling = note()
            dangling.workspaceOverride = UUID()
            store.add(dangling)
            try store.save()
            #expect(NoteStore(fileURL: url).notes == [dangling])
        }
    }

    @Test func readOnlyStoreRejectsMutationAndSkipsPurge() throws {
        try withStore { _, url in
            let original = Data(#"{"version":99,"future":"schema"}"#.utf8)
            try original.write(to: url)
            let store = NoteStore(fileURL: url)
            let missingID = UUID()
            #expect(!store.add(note()))
            #expect(!store.updateContent(id: missingID, change: .text("new")))
            #expect(!store.updateLayout(id: missingID, change: .hidden(true)))
            #expect(!store.updateBinding(id: missingID) { $0.index = 3 })
            #expect(!store.trash(id: missingID))
            #expect(!store.restore(id: missingID))
            #expect(store.purgeTrash(olderThan: edited) == 0)
            #expect(throws: NoteStore.StoreError.self) { try store.save() }
            #expect(throws: NoteStore.StoreError.self) { try store.replaceWorkspaces([]) }
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test func orderedFlushPersistsNewestGeneration() async throws {
        try withStore { _, url in }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.json")
        let store = NoteStore(fileURL: url, now: created)
        let first = note()
        store.add(first)
        #expect(store.mutationGeneration == 1)
        await store.enqueueSave()
        store.updateContent(id: first.id, change: .text("newer"), now: edited)
        #expect(store.mutationGeneration == 2)
        await store.enqueueSave()
        try await store.flush()
        #expect(store.hasUnsavedChanges == false)
        #expect(store.committedGeneration == 2)
        #expect(NoteStore(fileURL: url).notes.first?.text == "newer")
    }

    @Test func readOnlyStoreRejectsEverySavePath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.json")
        let original = Data(#"{"version":99,"future":"schema"}"#.utf8)
        try original.write(to: url)
        let store = NoteStore(fileURL: url)
        #expect(throws: NoteStore.StoreError.self) { try store.save() }
        #expect(throws: NoteStore.StoreError.self) { try store.saveSynchronously() }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func migratedFileStillWritesOnFirstSaveWithoutMutations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.json")
        let original = Data(#"{"version":1,"notes":[]}"#.utf8)
        try original.write(to: url)
        let store = NoteStore(fileURL: url, now: created)
        #expect(store.mutationGeneration == 0)
        try store.save()
        let backup = try #require(store.migrationBackupURL)
        #expect(try Data(contentsOf: backup) == original)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["version"] as? Int == 2)
    }

    @Test func migrationConflictUsesThePublicStoreError() throws {
        try withStore { _, url in
            try Data(#"{"version":1,"notes":[]}"#.utf8).write(to: url)
            let store = NoteStore(fileURL: url)
            let external = Data(#"{"version":99,"future":"updated by another writer"}"#.utf8)
            try external.write(to: url)
            #expect(throws: NoteStore.StoreError.sourceChanged) { try store.save() }
            #expect(try Data(contentsOf: url) == external)
            #expect(store.migrationBackupURL == nil)
        }
    }

    @Test func v1LoadsWithoutWritingThenCreatesOneExactBackup() throws {
        try withStore { _, url in
            let original = Data(#" { "version":1, "notes":[{"id":"11111111-1111-1111-1111-111111111111","anchor":{"web":{"page":{"host":"www.example.com","path":"/a"},"scope":{"page":{}}}},"text":"old","frame":{"x":1.25,"y":2,"width":300,"height":200},"placement":"window","collapsed":true,"createdAt":123456.789,"updatedAt":123500.125}] } "#.utf8)
            try original.write(to: url)
            let store = NoteStore(fileURL: url, now: created)
            #expect(store.mode == .writable)
            #expect(store.notes.count == 1)
            #expect(store.workspaces.isEmpty)
            #expect(store.notes.first?.revision == 1)
            #expect(store.notes.first?.createdAt == created)
            #expect(store.migrationBackupURL == nil)
            #expect(try Data(contentsOf: url) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["notes.json"])
            try store.save()
            let backup = try #require(store.migrationBackupURL)
            #expect(backup.lastPathComponent.hasPrefix("notes.v1-"))
            #expect(try Data(contentsOf: backup) == original)
            let reloaded = NoteStore(fileURL: url)
            #expect(reloaded.notes == store.notes)
            #expect(reloaded.workspaces.isEmpty)
            let expected = PageURL(host: "www.example.com", path: "/a")
            #expect(reloaded.notes.first?.anchor?.matches(.web(expected)) == true)
            try store.save()
            #expect(store.migrationBackupURL == backup)
            #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).count == 2)
        }
    }
}
