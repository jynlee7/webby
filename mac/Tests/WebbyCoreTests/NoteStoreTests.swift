import Foundation
import Testing
@testable import WebbyCore

private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbyNoteStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func removeTempDirectory(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
}

private func makeNote(
    id: UUID = UUID(),
    anchor: Anchor = .app(bundleID: "com.example.Notes"),
    text: String = "",
    createdAt: Date = baseDate
) -> Note {
    Note(
        id: id,
        anchor: anchor,
        text: text,
        frame: NoteFrame(x: 10, y: 20, width: 300, height: 200),
        placement: .window,
        createdAt: createdAt,
        updatedAt: createdAt
    )
}

@Test func missingFileOpensEmptyWritableStoreAndCreatesNothing() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("nested", isDirectory: true).appendingPathComponent("notes.json")
    let store = try NoteStore(fileURL: url, now: baseDate)

    #expect(store.fileURL == url)
    #expect(store.notes.isEmpty)
    #expect(store.mode == .writable)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
}

@Test func crudAndQueries() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let store = try NoteStore(fileURL: root.appendingPathComponent("notes.json"), now: baseDate)
    let appNote = makeNote(text: "App note")
    let siteNote = makeNote(anchor: .web(page: PageURL(host: "example.com", path: "/"), scope: .site))
    let pageNote = makeNote(anchor: .web(page: PageURL(host: "example.com", path: "/docs"), scope: .page))
    store.add(appNote)
    store.add(siteNote)
    store.add(pageNote)

    #expect(store.notes.count == 3)
    #expect(store.note(id: appNote.id) == appNote)
    #expect(store.note(id: UUID()) == nil)

    #expect(store.notes(matching: .app(bundleID: "com.example.Notes")).map(\.id) == [appNote.id])
    #expect(store.notes(matching: .web(PageURL(host: "example.com", path: "/docs"))).map(\.id) == [siteNote.id, pageNote.id])
    #expect(store.notes(matching: .web(PageURL(host: "example.com", path: "/other"))).map(\.id) == [siteNote.id])

    let updatedAt = baseDate.addingTimeInterval(120)
    #expect(store.update(id: appNote.id, now: updatedAt) { $0.text = "Changed" })
    #expect(store.note(id: appNote.id)?.text == "Changed")
    #expect(store.note(id: appNote.id)?.updatedAt == updatedAt)

    #expect(store.remove(id: siteNote.id))
    #expect(store.note(id: siteNote.id) == nil)
    #expect(store.notes.count == 2)
}

@Test func updateAndRemoveMissingIDsReturnFalse() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let store = try NoteStore(fileURL: root.appendingPathComponent("notes.json"), now: baseDate)

    #expect(!store.update(id: UUID(), now: baseDate) { $0.text = "No note" })
    #expect(!store.remove(id: UUID()))
    #expect(store.notes.isEmpty)
}

@Test func saveCreatesParentAndReloadsEqualNotes() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root
        .appendingPathComponent("deep", isDirectory: true)
        .appendingPathComponent("nested", isDirectory: true)
        .appendingPathComponent("notes.json")
    let store = try NoteStore(fileURL: url, now: baseDate)
    let notes = [
        makeNote(text: "One", createdAt: baseDate),
        makeNote(
            anchor: .web(page: PageURL(host: "example.com", path: "/docs"), scope: .prefix(path: "/docs")),
            text: "Two",
            createdAt: baseDate.addingTimeInterval(-60)
        ),
    ]
    notes.forEach(store.add)

    try store.save()

    #expect(FileManager.default.fileExists(atPath: url.path))

    let data = try Data(contentsOf: url)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["version"] as? Int == NoteStore.currentVersion)
    #expect((object["notes"] as? [[String: Any]])?.count == notes.count)

    let reloaded = try NoteStore(fileURL: url)
    #expect(reloaded.mode == .writable)
    #expect(reloaded.notes == notes)
}

private func expectCorruption(contents: Data) throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    try contents.write(to: url)

    let store = try NoteStore(fileURL: url, now: baseDate)

    #expect(store.mode == .writable)
    #expect(store.notes.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))

    let sibling = root.appendingPathComponent("notes.corrupt-\(Int(baseDate.timeIntervalSince1970)).json")
    #expect(FileManager.default.fileExists(atPath: sibling.path))
    let moved = try Data(contentsOf: sibling)
    #expect(moved == contents)
    let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(files == [sibling.lastPathComponent])
}

@Test func malformedJSONIsMovedAside() throws {
    try expectCorruption(contents: Data("{not valid json".utf8))
}

@Test func validJSONWithInvalidV1SchemaIsMovedAside() throws {
    try expectCorruption(contents: Data(#"{"version":1,"notes":"not-an-array"}"#.utf8))
}

@Test func newerVersionOpensReadOnlyWithoutDecodingNotesOrWriting() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let contents = Data(#"{"version":99,"unrecognized":"payload without notes"}"#.utf8)
    try contents.write(to: url)

    let store = try NoteStore(fileURL: url, now: baseDate)

    #expect(store.mode == .readOnly(newerVersion: 99))
    #expect(store.notes.isEmpty)
    #expect(try Data(contentsOf: url) == contents)
    let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(files == ["notes.json"])

    #expect(throws: NoteStore.StoreError.readOnly(newerVersion: 99)) {
        try store.save()
    }
    #expect(try Data(contentsOf: url) == contents)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["notes.json"])
}

@Test func defaultFileURLPointsAtApplicationSupportWithoutWriting() throws {
    let url = NoteStore.defaultFileURL
    let before = try? Data(contentsOf: url)

    _ = NoteStore.defaultFileURL

    #expect(url.path.hasSuffix("/Webby/notes.json"))
    #expect(url.lastPathComponent == "notes.json")
    #expect(url.deletingLastPathComponent().lastPathComponent == "Webby")
    #expect((try? Data(contentsOf: url)) == before)
}
