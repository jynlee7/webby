import Foundation
import Testing
@testable import WebbyCore

@Suite struct SaveRequestTests {
    private let created = Date(timeIntervalSinceReferenceDate: 200_000)

    private func withStore(_ body: (NoteStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.json")
        try await body(NoteStore(fileURL: url, now: created), url)
    }

    private func note(_ text: String) -> Note {
        Note(anchor: .app(bundleID: "com.apple.TextEdit"), text: text,
             frame: NoteFrame(x: 10, y: 20, width: 240, height: 180), placement: .window,
             createdAt: created)
    }

    @Test func requestFlushedFromAnotherTaskWritesThatState() async throws {
        try await withStore { store, url in
            let original = note("draft")
            store.add(original)
            let request = store.saveRequest()
            #expect(request.isUnsaved)

            let committed = try await Task.detached { try await request.flush() }.value

            #expect(committed == request.generation)
            #expect(!request.isUnsaved)
            #expect(!store.hasUnsavedChanges)
            #expect(NoteStore(fileURL: url).note(id: original.id)?.text == "draft")
        }
    }

    @Test func synchronousCommitFromAnotherThreadWritesThatState() async throws {
        try await withStore { store, url in
            let original = note("typed then quit")
            store.add(original)
            let request = store.saveRequest()

            let committed = try await Task.detached { try request.commitNow() }.value

            #expect(committed == request.generation)
            #expect(NoteStore(fileURL: url).note(id: original.id)?.text == "typed then quit")
        }
    }

    @Test func olderRequestNeverReplacesANewerCommit() async throws {
        try await withStore { store, url in
            let original = note("first")
            store.add(original)
            let older = store.saveRequest()
            store.updateContent(id: original.id, change: .text("second"))
            let newer = store.saveRequest()
            #expect(newer.generation > older.generation)

            _ = try await newer.flush()
            let reported = try older.commitNow()
            _ = try await older.flush()

            #expect(reported == newer.generation)
            #expect(NoteStore(fileURL: url).note(id: original.id)?.text == "second")
        }
    }

    @Test func readOnlyRequestNeverWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.json")
        let newer = Data(#"{"version": 99, "notes": []}"#.utf8)
        try newer.write(to: url)

        let store = NoteStore(fileURL: url)
        let request = store.saveRequest()

        #expect(throws: NoteStore.StoreError.self) { try request.commitNow() }
        // A read-only store never leaves generation 0, which the writer reports as
        // already durable; what matters is that the file is untouched.
        _ = try? await request.flush()
        #expect(try Data(contentsOf: url) == newer)
    }
}
