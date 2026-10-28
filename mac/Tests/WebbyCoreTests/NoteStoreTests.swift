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
    anchor: Anchor? = .app(bundleID: "com.example.Notes"),
    tab: TabBinding? = nil,
    hidden: Bool = false,
    trashedAt: Date? = nil,
    text: String = "",
    createdAt: Date = baseDate
) -> Note {
    Note(
        id: id,
        anchor: anchor,
        tab: tab,
        text: text,
        frame: NoteFrame(x: 10, y: 20, width: 300, height: 200),
        placement: .window,
        hidden: hidden,
        trashedAt: trashedAt,
        createdAt: createdAt,
        updatedAt: createdAt
    )
}

@Test func notesFormatVersionIsIndependentOfOtherFiles() {
    #expect(NoteStore.currentVersion == 2)
    #expect(VersionedJSONFile<[String]>.currentVersion == 1)
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

    #expect(store.notes(matching: Context(appBundleID: "com.example.Notes")).map(\.id) == [appNote.id])
    #expect(store.notes(matching: Context(
        appBundleID: "com.google.Chrome",
        page: PageURL(host: "example.com", path: "/docs")
    )).map(\.id) == [siteNote.id, pageNote.id])
    #expect(store.notes(matching: Context(
        appBundleID: "com.google.Chrome",
        page: PageURL(host: "example.com", path: "/other")
    )).map(\.id) == [siteNote.id])

    let updatedAt = baseDate.addingTimeInterval(120)
    #expect(store.updateContent(id: appNote.id, change: .text("Changed"), now: updatedAt))
    #expect(store.note(id: appNote.id)?.text == "Changed")
    #expect(store.note(id: appNote.id)?.updatedAt == updatedAt)

    #expect(store.trash(id: siteNote.id, now: updatedAt))
    #expect(store.note(id: siteNote.id)?.trashedAt == updatedAt)
    #expect(store.notes.count == 3)
    #expect(store.notes(matching: Context(
        appBundleID: "com.google.Chrome",
        page: PageURL(host: "example.com", path: "/other")
    )).isEmpty)
}

@Test func notesMatchingUsesVisibilityWhileKeepingOrderAndNotMutating() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let store = NoteStore(fileURL: root.appendingPathComponent("notes.json"), now: baseDate)
    let liveBinding = TabBinding(
        browser: "com.google.Chrome", profile: "profile-a", session: "session-a",
        tabID: 7, windowID: 2, index: 0, lastURL: "https://example.com/a"
    )
    let closedBinding = TabBinding(
        browser: "com.google.Chrome", profile: "profile-a", session: "session-a",
        tabID: 8, windowID: 2, index: 1, lastURL: "https://example.com/a",
        closedAt: baseDate
    )

    let siteNote = makeNote(
        anchor: .web(page: PageURL(host: "example.com", path: "/"), scope: .site),
        text: "site"
    )
    let closedNote = makeNote(
        anchor: .web(page: PageURL(host: "example.com", path: "/docs"), scope: .page),
        tab: closedBinding,
        text: "closed"
    )
    let hiddenAppNote = makeNote(anchor: .app(bundleID: "com.example.Notes"), hidden: true, text: "hidden")
    let trashedAppNote = makeNote(
        anchor: .app(bundleID: "com.example.Notes"),
        trashedAt: baseDate,
        text: "trashed"
    )
    let tabNote = makeNote(anchor: nil, tab: liveBinding, text: "tab")
    let appNote = makeNote(anchor: .app(bundleID: "com.example.Notes"), text: "app")
    let inboxNote = makeNote(anchor: nil, text: "inbox")
    let pageNote = makeNote(
        anchor: .web(page: PageURL(host: "example.com", path: "/docs"), scope: .page),
        text: "page"
    )
    let contradictoryTabNote = makeNote(
        anchor: .app(bundleID: "com.example.Other"),
        tab: liveBinding,
        text: "contradictory"
    )
    let all = [
        siteNote, closedNote, hiddenAppNote, trashedAppNote, tabNote,
        appNote, inboxNote, pageNote, contradictoryTabNote,
    ]
    all.forEach { #expect(store.add($0)) }

    let before = store.notes
    let generation = store.mutationGeneration

    let appMatches = store.notes(matching: Context(appBundleID: "com.example.Notes"))
    #expect(appMatches.map(\.id) == [hiddenAppNote.id, appNote.id])

    let pageMatches = store.notes(matching: Context(
        appBundleID: "com.google.Chrome",
        page: PageURL(host: "example.com", path: "/docs")
    ))
    #expect(pageMatches.map(\.id) == [siteNote.id, pageNote.id])

    let liveTab = TabRef(
        browser: "com.google.Chrome", profile: "profile-a", session: "session-a", tabID: 7, windowID: 2
    )
    let tabMatches = store.notes(matching: Context(
        appBundleID: "com.google.Chrome",
        page: PageURL(host: "other.example", path: "/navigated"),
        tab: liveTab
    ))
    #expect(tabMatches.map(\.id) == [tabNote.id, contradictoryTabNote.id])

    let closedTab = TabRef(
        browser: "com.google.Chrome", profile: "profile-a", session: "session-a", tabID: 8, windowID: 2
    )
    let pageOnly = store.notes(matching: Context(
        appBundleID: "com.google.Chrome",
        page: PageURL(host: "example.com", path: "/docs")
    ))
    let closedTabMatches = store.notes(matching: Context(
        appBundleID: "com.google.Chrome",
        page: PageURL(host: "example.com", path: "/docs"),
        tab: closedTab
    ))
    #expect(pageOnly.map(\.id) == [siteNote.id, pageNote.id])
    #expect(closedTabMatches.map(\.id) == [siteNote.id, pageNote.id])
    #expect(Set(pageMatches.map(\.id)).count == pageMatches.count)

    #expect(store.notes == before)
    #expect(store.mutationGeneration == generation)
}

@Test func updateAndTrashMissingIDsReturnFalse() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let store = NoteStore(fileURL: root.appendingPathComponent("notes.json"), now: baseDate)

    #expect(!store.updateContent(id: UUID(), change: .text("No note"), now: baseDate))
    #expect(!store.trash(id: UUID()))
    #expect(!store.restore(id: UUID()))
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
    notes.forEach { store.add($0) }

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
    #expect(reloaded.notes.first?.anchor?.matches(Context(
        appBundleID: "com.google.Chrome",
        page: page
    )) == true)
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
