import Foundation
import Testing
@testable import WebbyCore

@Suite struct NoteStoreTests {
    let dir: URL
    let file: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("webby-tests-\(UUID().uuidString)")
        file = dir.appendingPathComponent("nested/notes.json")
    }

    func sampleNote(_ text: String = "hash map, O(n)") -> Note {
        Note(
            anchor: .web(page: PageURL(host: "leetcode.com", path: "/problems/two-sum"), scope: .prefix(path: "/problems/two-sum")),
            text: text,
            frame: NoteFrame(x: 40, y: 120, width: 260, height: 180),
            placement: .window,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test func missingFileStartsEmpty() throws {
        let store = try NoteStore(fileURL: file)
        #expect(store.notes.isEmpty)
    }

    @Test func roundTripsAllFields() throws {
        let store = try NoteStore(fileURL: file)
        let a = sampleNote()
        let b = Note(anchor: .app(bundleID: "com.apple.Notes"), text: "üñíçødé ✓\nline 2",
                     frame: NoteFrame(x: -1200.5, y: -30, width: 200, height: 100), placement: .screen, collapsed: true)
        store.add(a)
        store.add(b)
        try store.save()

        let reloaded = try NoteStore(fileURL: file)
        #expect(reloaded.notes.map(\.id) == [a.id, b.id])
        #expect(reloaded.note(id: a.id) == a)
        // ISO 8601 drops sub-second precision, so compare b field by field except dates.
        let b2 = try #require(reloaded.note(id: b.id))
        #expect(b2.anchor == b.anchor && b2.text == b.text && b2.frame == b.frame)
        #expect(b2.placement == .screen && b2.collapsed)
    }

    @Test func fileIsVersioned() throws {
        let store = try NoteStore(fileURL: file)
        store.add(sampleNote())
        try store.save()
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(json?["version"] as? Int == NoteStore.currentVersion)
    }

    @Test func updateAndRemove() throws {
        let store = try NoteStore(fileURL: file)
        let note = sampleNote()
        store.add(note)

        let later = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(store.update(id: note.id, now: later) { $0.text = "two pointers" })
        #expect(store.note(id: note.id)?.text == "two pointers")
        #expect(store.note(id: note.id)?.updatedAt == later)
        #expect(store.note(id: note.id)?.createdAt == note.createdAt)
        #expect(!store.update(id: UUID()) { $0.text = "x" })

        #expect(store.remove(id: note.id))
        #expect(!store.remove(id: note.id))
        #expect(store.notes.isEmpty)
    }

    @Test func filtersByContext() throws {
        let store = try NoteStore(fileURL: file)
        let web = sampleNote()
        let app = Note(anchor: .app(bundleID: "com.apple.Notes"), frame: NoteFrame(x: 0, y: 0, width: 1, height: 1), placement: .window)
        store.add(web)
        store.add(app)

        #expect(store.notes(matching: .web(PageURL(host: "leetcode.com", path: "/problems/two-sum/solutions"))).map(\.id) == [web.id])
        #expect(store.notes(matching: .app(bundleID: "com.apple.Notes")).map(\.id) == [app.id])
        #expect(store.notes(matching: .app(bundleID: "com.google.Chrome")).isEmpty)
    }

    @Test func corruptFileIsMovedAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: file)

        let store = try NoteStore(fileURL: file, now: Date(timeIntervalSince1970: 1234))
        #expect(store.notes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let aside = file.deletingLastPathComponent().appendingPathComponent("notes.corrupt-1234.json")
        #expect(try Data(contentsOf: aside) == garbage)
    }

    @Test func saveLeavesNoTempFiles() throws {
        let store = try NoteStore(fileURL: file)
        store.add(sampleNote())
        try store.save()
        store.add(sampleNote("second"))
        try store.save()
        let contents = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(contents == ["notes.json"])
        #expect(try NoteStore(fileURL: file).notes.count == 2)
    }
}
