import Foundation
import Testing
@testable import WebbyCore

private let exportRecordA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
private let exportRecordB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
private let exportNoteA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
private let exportNoteB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
private let exportNoteC = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!

private func exportDate(_ value: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: value)
}

private func exportRecord(
    _ id: UUID,
    keys: [WorkspaceKey],
    createdAt: Date = exportDate(0)
) -> WorkspaceRecord {
    WorkspaceRecord(id: id, keys: keys, createdAt: createdAt)
}

private func exportNote(
    _ id: UUID,
    anchor: Anchor? = nil,
    tab: TabBinding? = nil,
    workspaceOverride: UUID? = nil,
    text: String = "note",
    source: NoteSource? = nil,
    trashedAt: Date? = nil,
    ephemeral: Bool = false,
    createdAt: Date = exportDate(10)
) -> Note {
    Note(
        id: id,
        anchor: anchor,
        tab: tab,
        workspaceOverride: workspaceOverride,
        text: text,
        source: source,
        frame: NoteFrame(x: 1, y: 2, width: 3, height: 4),
        placement: .window,
        trashedAt: trashedAt,
        createdAt: createdAt,
        ephemeral: ephemeral
    )
}

private func exportTab(_ url: String) -> TabBinding {
    TabBinding(
        browser: "chrome",
        profile: "Default",
        session: "session",
        tabID: 7,
        windowID: 2,
        index: 1,
        lastURL: url,
        lastTitle: "Title"
    )
}

private func exportWeb(
    _ host: String,
    path: String = "/page",
    query: String? = nil,
    scope: WebScope = .page
) -> Anchor {
    .web(page: PageURL(host: host, path: path, query: query), scope: scope)
}

@Test func exportIsByteIdenticalAndSorted() throws {
    let workspaces = [
        exportRecord(exportRecordB, keys: [.tabsWithoutPage, .localFiles]),
        exportRecord(exportRecordA, keys: [.host(name: "example.com"), .app(bundleID: "com.app")]),
    ]
    let notes = [
        exportNote(exportNoteB, anchor: exportWeb("example.com")),
        exportNote(exportNoteA, anchor: exportWeb("other.com")),
    ]
    let options = ExportJSONOptions()

    let first = try ExportJSON.encode(notes: notes, workspaces: workspaces, options: options)
    let second = try ExportJSON.encode(notes: notes, workspaces: workspaces, options: options)
    #expect(first == second)

    let document = try NotesDocument.decode(first, version: 2)
    #expect(document.notes.map(\.id) == [exportNoteA, exportNoteB])
    #expect(document.workspaces.map(\.id) == [exportRecordA, exportRecordB])
    #expect(document.workspaces[0].keys == [
        .app(bundleID: "com.app"),
        .host(name: "example.com"),
    ])
    #expect(document.workspaces[1].keys == [.localFiles, .tabsWithoutPage])
}

@Test func exportSelectsWorkspaceAndExplicitNotes() throws {
    let workspaces = [
        exportRecord(exportRecordA, keys: [.host(name: "example.com"), .app(bundleID: "com.app")]),
    ]
    let notes = [
        exportNote(exportNoteA, anchor: exportWeb("example.com")),
        exportNote(exportNoteB, anchor: .app(bundleID: "com.app")),
        exportNote(exportNoteC, anchor: exportWeb("other.com")),
    ]

    let workspaceData = try ExportJSON.encode(
        notes: notes,
        workspaces: workspaces,
        options: ExportJSONOptions(selection: .workspace(.record(exportRecordA)))
    )
    let workspaceDocument = try NotesDocument.decode(workspaceData, version: 2)
    #expect(workspaceDocument.notes.map(\.id) == [exportNoteA, exportNoteB])
    #expect(workspaceDocument.workspaces.map(\.id) == [exportRecordA])

    let explicitData = try ExportJSON.encode(
        notes: notes,
        workspaces: workspaces,
        options: ExportJSONOptions(selection: .notes([exportNoteC.id]))
    )
    let explicitDocument = try NotesDocument.decode(explicitData, version: 2)
    #expect(explicitDocument.notes.map(\.id) == [exportNoteC])
    #expect(explicitDocument.workspaces.isEmpty)
}

@Test func exportExcludesEphemeralNotes() throws {
    let notes = [
        exportNote(exportNoteA, text: "durable"),
        exportNote(exportNoteB, text: "temporary", ephemeral: true),
    ]

    let data = try ExportJSON.encode(notes: notes, workspaces: [])
    let document = try NotesDocument.decode(data, version: 2)
    #expect(document.notes.map(\.id) == [exportNoteA])
}

@Test func exportOmitsRawSourceURLAndClearsTabURLByDefault() throws {
    let rawURL = "https://youtube.com/watch?v=abc&t=secret&token=do-not-export"
    let note = exportNote(
        exportNoteA,
        anchor: exportWeb("youtube.com", path: "/watch", query: "v=abc"),
        tab: exportTab(rawURL),
        source: NoteSource(url: rawURL, title: "Video")
    )

    let data = try ExportJSON.encode(notes: [note], workspaces: [])
    let document = try NotesDocument.decode(data, version: 2)
    let encoded = try #require(document.notes.first)
    #expect(encoded.source?.url == nil)
    #expect(encoded.source?.title == "Video")
    #expect(encoded.tab?.lastURL == "")
    #expect(!String(decoding: data, as: UTF8.self).contains("do-not-export"))
}

@Test func exportOptInWritesOnlyCanonicalSourceURL() throws {
    let rawURL = "https://youtube.com/watch?v=abc&t=secret&token=do-not-export"
    let note = exportNote(
        exportNoteA,
        anchor: exportWeb("youtube.com", path: "/watch", query: "v=abc"),
        tab: exportTab(rawURL),
        source: NoteSource(url: rawURL, title: "Video")
    )

    let data = try ExportJSON.encode(
        notes: [note],
        workspaces: [],
        options: ExportJSONOptions(includeCanonicalSourceURLs: true)
    )
    let document = try NotesDocument.decode(data, version: 2)
    let encoded = try #require(document.notes.first)
    #expect(encoded.source?.url == "https://youtube.com/watch?v=abc")
    #expect(encoded.tab?.lastURL == "https://youtube.com/watch?v=abc")
    #expect(!String(decoding: data, as: UTF8.self).contains("do-not-export"))
}

@Test func exportPreservesWorkspaceMembershipForUnanchoredTabNotes() throws {
    let note = exportNote(
        exportNoteA,
        tab: exportTab("https://example.com/page?token=secret"),
        source: NoteSource(url: "https://example.com/page?token=secret")
    )

    let data = try ExportJSON.encode(notes: [note], workspaces: [])
    let document = try NotesDocument.decode(data, version: 2)
    let encoded = try #require(document.notes.first)
    let localRecord = try #require(document.workspaces.first)

    #expect(document.workspaces.count == 1)
    #expect(localRecord.keys == [.host(name: "example.com")])
    #expect(encoded.workspaceOverride == localRecord.id)
    #expect(encoded.anchor == nil)
    #expect(encoded.tab != nil)
}

@Test func exportPreservesExplicitWorkspaceOverridesForAnchoredNotes() throws {
    let workspace = exportRecord(
        exportRecordA,
        keys: [.host(name: "example.com"), .app(bundleID: "com.foreign")]
    )
    let note = exportNote(
        exportNoteA,
        anchor: exportWeb("other.com"),
        workspaceOverride: exportRecordA
    )

    let data = try ExportJSON.encode(notes: [note], workspaces: [workspace])
    let document = try NotesDocument.decode(data, version: 2)
    let encoded = try #require(document.notes.first)

    #expect(encoded.workspaceOverride == exportRecordA)
    #expect(document.workspaces.map(\.id) == [exportRecordA])
    #expect(document.workspaces[0].keys == [
        .app(bundleID: "com.foreign"),
        .host(name: "example.com"),
    ])
}
