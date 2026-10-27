import Foundation
import Testing
@testable import WebbyCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private let baseDate = Date(timeIntervalSince1970: 1_700_000_000.789)
private let baseDateStamp = "20231114-221320-789"

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

@Test func currentVersionMatchesSharedLoader() {
    #expect(NoteStore.currentVersion == VersionedJSONFile<[Note]>.currentVersion)
}

@Test func missingFileOpensEmptyWritableStoreAndCreatesNothing() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("nested", isDirectory: true).appendingPathComponent("notes.json")
    let store = NoteStore(fileURL: url, now: baseDate)

    #expect(store.fileURL == url)
    #expect(store.notes.isEmpty)
    #expect(store.mode == .writable)
    #expect(store.outcome == .missing)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
}

@Test func crudAndQueries() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let store = NoteStore(fileURL: root.appendingPathComponent("notes.json"), now: baseDate)
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

    let store = NoteStore(fileURL: root.appendingPathComponent("notes.json"), now: baseDate)

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
    let store = NoteStore(fileURL: url, now: baseDate)
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
    #expect(object["content"] == nil)

    let reloaded = NoteStore(fileURL: url)
    #expect(reloaded.mode == .writable)
    #expect(reloaded.outcome == .loaded)
    #expect(reloaded.notes == notes)
}

private func expectCorruption(contents: Data) throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    try contents.write(to: url)

    let store = NoteStore(fileURL: url, now: baseDate)

    #expect(store.mode == .writable)
    #expect(store.notes.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))

    guard case .recovered(let sibling) = store.outcome else {
        Issue.record("Expected the corrupt file to be moved aside")
        return
    }
    #expect(sibling.lastPathComponent.hasPrefix("notes.corrupt-\(baseDateStamp)-"))
    #expect(sibling.lastPathComponent.hasSuffix(".json"))
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

    let store = NoteStore(fileURL: url, now: baseDate)

    #expect(store.mode == .readOnly(.newerVersion(found: 99, supported: NoteStore.currentVersion)))
    #expect(store.outcome == .newer(version: 99))
    #expect(store.notes.isEmpty)
    #expect(try Data(contentsOf: url) == contents)
    let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(files == ["notes.json"])

    do {
        try store.save()
        Issue.record("Expected saving a newer notes file to fail")
    } catch let error as NoteStore.StoreError {
        #expect(error == .readOnly(.newerVersion(found: 99, supported: NoteStore.currentVersion)))
        #expect(error.localizedDescription.contains("newer version of Webby"))
        #expect(error.localizedDescription.contains("Saving is disabled"))
    }
    #expect(try Data(contentsOf: url) == contents)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["notes.json"])
}

@Test func noteStoreUnreadableFileIsReadOnlyAndByteIdentical() throws {
    guard geteuid() != 0 else { return }

    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let contents = Data(#"{"version":1,"notes":[]}"#.utf8)
    try contents.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    let store = NoteStore(fileURL: url, now: baseDate)

    guard case .readOnly(.unreadable(let reason)) = store.mode else {
        Issue.record("Expected an unreadable file to open read-only")
        return
    }
    #expect(!reason.isEmpty)
    #expect(store.outcome == .unreadable)
    #expect(store.notes.isEmpty)

    do {
        try store.save()
        Issue.record("Expected saving an unreadable file to fail")
    } catch let error as NoteStore.StoreError {
        guard case .readOnly(.unreadable) = error else {
            Issue.record("Expected the save error to be read-only unreadable")
            return
        }
    }

    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    #expect(try Data(contentsOf: url) == contents)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["notes.json"])
}

@Test func noteStoreNonRegularFileIsReadOnlyAndUntouched() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

    let store = NoteStore(fileURL: url, now: baseDate)

    guard case .readOnly(.unreadable(let reason)) = store.mode else {
        Issue.record("Expected a non-regular file to open read-only")
        return
    }
    #expect(!reason.isEmpty)
    #expect(store.outcome == .unreadable)
    #expect(store.notes.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["notes.json"])
}

@Test func saveAfterRecoveryWritesFreshValidFile() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    try Data("{broken".utf8).write(to: url)

    let store = NoteStore(fileURL: url, now: baseDate)
    guard case .recovered = store.outcome else {
        Issue.record("Expected the corrupt file to be moved aside")
        return
    }
    #expect(store.mode == .writable)
    #expect(store.notes.isEmpty)

    let note = makeNote(text: "Recovered")
    store.add(note)
    try store.save()

    let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(object["version"] as? Int == NoteStore.currentVersion)
    #expect((object["notes"] as? [[String: Any]])?.count == 1)
    #expect(object["content"] == nil)

    let reloaded = NoteStore(fileURL: url)
    #expect(reloaded.mode == .writable)
    #expect(reloaded.outcome == .loaded)
    #expect(reloaded.notes == [note])
}

@Test func saveAndReloadPreserveDoubleWwwHostIdentity() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let page = try #require(PageURL(string: "https://www.www.example.com/a"))
    let note = makeNote(anchor: .web(page: page, scope: .page))
    let store = NoteStore(fileURL: url, now: baseDate)
    store.add(note)

    try store.save()
    let reloaded = NoteStore(fileURL: url)

    #expect(reloaded.notes == [note])
    #expect(reloaded.notes.first?.anchor.matches(.web(page)) == true)
}

@Test func saveAndReloadPreserveReferenceDatePrecision() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let note = makeNote(createdAt: Date(timeIntervalSinceReferenceDate: 123_456.789))
    let store = NoteStore(fileURL: url, now: baseDate)
    store.add(note)

    try store.save()
    let reloaded = NoteStore(fileURL: url)

    #expect(reloaded.notes == [note])
}

@Test func defaultFileURLPointsAtApplicationSupport() {
    let url = NoteStore.defaultFileURL

    #expect(url.path.hasSuffix("/Webby/notes.json"))
    #expect(url.lastPathComponent == "notes.json")
    #expect(url.deletingLastPathComponent().lastPathComponent == "Webby")
}
