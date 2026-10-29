import Foundation
import Testing
@testable import WebbyCore

private let importRecordA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
private let importRecordB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
private let importNoteA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
private let importNoteB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
private let importFreshA = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
private let importFreshB = UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!

private func importDate(_ value: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: value)
}

private func importRecord(
    _ id: UUID,
    keys: [WorkspaceKey],
    createdAt: Date = importDate(0)
) -> WorkspaceRecord {
    WorkspaceRecord(id: id, keys: keys, createdAt: createdAt)
}

private func importNote(
    _ id: UUID,
    anchor: Anchor? = nil,
    tab: TabBinding? = nil,
    workspaceOverride: UUID? = nil,
    text: String = "note",
    source: NoteSource? = nil,
    createdAt: Date = importDate(10),
    updatedAt: Date? = nil,
    revision: Int = 1,
    ephemeral: Bool = false
) -> Note {
    Note(
        id: id,
        anchor: anchor,
        tab: tab,
        workspaceOverride: workspaceOverride,
        text: text,
        revision: revision,
        source: source,
        frame: NoteFrame(x: 1, y: 2, width: 3, height: 4),
        placement: .window,
        createdAt: createdAt,
        updatedAt: updatedAt,
        ephemeral: ephemeral
    )
}

private func importWeb(_ host: String, path: String = "/page") -> Anchor {
    .web(page: PageURL(host: host, path: path), scope: .page)
}

private func importIDFactory(_ ids: [UUID]) -> () -> UUID {
    var index = 0
    return {
        let value = ids[min(index, ids.count - 1)]
        index += 1
        return value
    }
}

private func importApply(
    _ plan: ImportPlan,
    to notes: [Note],
    workspaces: [WorkspaceRecord]
) -> ([Note], [WorkspaceRecord]) {
    var updates = Dictionary(
        plan.workspaceUpdates.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    let mergedWorkspaces = workspaces.map { record in
        updates.removeValue(forKey: record.id) ?? record
    }
    let combinedWorkspaces = mergedWorkspaces + plan.workspaceUpdates.filter {
        updates[$0.id] != nil
    } + plan.workspacesToAdd
    return (notes + plan.notesToAdd, combinedWorkspaces)
}

private func importMembershipName(_ note: Note, _ workspaces: [WorkspaceRecord]) -> String {
    switch WorkspaceResolver.resolve(note, workspaces: workspaces) {
    case .inbox:
        return "Inbox"
    case .implicit(let key):
        return key.displayName
    case .record(let id):
        guard let record = workspaces.first(where: { $0.id == id }) else {
            return "Missing"
        }
        return record.keys.map(\.displayName).sorted().joined(separator: "|")
    }
}

private let importV1Fixture = #"""
{
  "version": 1,
  "notes": [
    {
      "id": "6B29FC40-CA47-1067-B31D-00DD010662DA",
      "anchor": { "app": { "bundleID": "com.apple.TextEdit" } },
      "text": "Version one",
      "frame": { "x": 1, "y": 2, "width": 3, "height": 4 },
      "placement": "window",
      "collapsed": false,
      "createdAt": 100,
      "updatedAt": 200
    }
  ]
}
"""#

@Test func decodeAcceptsVersionOneThroughMigration() throws {
    let payload = try ImportJSON.decode(Data(importV1Fixture.utf8))
    #expect(payload.workspaces.isEmpty)
    #expect(payload.notes.count == 1)
    let note = try #require(payload.notes.first)
    #expect(note.id == UUID(uuidString: "6B29FC40-CA47-1067-B31D-00DD010662DA"))
    #expect(note.text == "Version one")
    #expect(note.revision == 1)
    #expect(note.tab == nil)
    #expect(note.workspaceOverride == nil)
    #expect(note.source == nil)
    #expect(note.ephemeral == false)
}

@Test func decodeAcceptsVersionTwo() throws {
    let note = importNote(importNoteA, anchor: importWeb("example.com"))
    let workspace = importRecord(importRecordA, keys: [.host(name: "example.com")])
    let data = try NotesDocument.encode(
        NotesDocument(notes: [note], workspaces: [workspace]),
        version: 2
    )

    let payload = try ImportJSON.decode(data)
    #expect(payload.notes == [note])
    #expect(payload.workspaces == [workspace])
}

@Test func decodeRefusesNewerVersionsAndMalformedRoots() {
    let newer = Data(#"{"version":3,"notes":[],"workspaces":[]}"#.utf8)
    do {
        _ = try ImportJSON.decode(newer)
        Issue.record("Expected a newer version to be refused")
    } catch let error as ImportJSONError {
        #expect(error == .unsupportedVersion(3))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    for malformed in [
        #"{"#,
        #"[]"#,
        #"{"version":"two"}"#,
        #"{"notes":[]}"#,
    ] {
        do {
            _ = try ImportJSON.decode(Data(malformed.utf8))
            Issue.record("Expected malformed data to be refused: \(malformed)")
        } catch let error as ImportJSONError {
            #expect(error == .malformedRoot)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func planIntoEmptyStoreKeepsEligibleNotesAndMembership() throws {
    let workspace = importRecord(importRecordA, keys: [.host(name: "example.com")])
    let notes = [
        importNote(
            importNoteA,
            anchor: importWeb("example.com"),
            tab: TabBinding(
                browser: "chrome",
                profile: "Default",
                session: "session",
                tabID: 1,
                windowID: 1,
                index: 0,
                lastURL: "https://example.com/page?token=secret"
            ),
            workspaceOverride: importRecordA,
            text: "A",
            source: NoteSource(url: "https://example.com/page?token=secret", title: "A"),
            createdAt: importDate(10),
            updatedAt: importDate(20),
            revision: 4
        ),
        importNote(
            importNoteB,
            text: "Inbox",
            createdAt: importDate(30)
        ),
    ]

    let data = try ExportJSON.encode(notes: notes, workspaces: [workspace])
    let payload = try ImportJSON.decode(data)
    let plan = try ImportJSON.plan(
        payload,
        against: [],
        workspaces: [],
        makeID: importIDFactory([importFreshA])
    )
    let (importedNotes, importedWorkspaces) = importApply(plan, to: [], workspaces: [])

    #expect(importedNotes.count == notes.count)
    let importedIDs = importedNotes.map(\.id).sorted { $0.uuidString < $1.uuidString }
    let originalIDs = notes.map(\.id).sorted { $0.uuidString < $1.uuidString }
    #expect(importedIDs == originalIDs)
    for original in notes {
        let imported = try #require(importedNotes.first { $0.id == original.id })
        #expect(imported.text == original.text)
        #expect(imported.createdAt == original.createdAt)
        #expect(imported.updatedAt == original.updatedAt)
        #expect(imported.revision == original.revision)
        #expect(imported.tab == nil)
        #expect(imported.ephemeral == false)
        #expect(importMembershipName(imported, importedWorkspaces)
            == importMembershipName(original, [workspace]))
    }
}

@Test func importingTwiceAddsCopiesAndLeavesExistingNotesAlone() throws {
    let original = [
        importNote(importNoteA, anchor: importWeb("example.com"), text: "Original")
    ]
    let existingWorkspaces = [
        importRecord(importRecordA, keys: [.host(name: "example.com")])
    ]
    let payload = ImportPayload(
        notes: [
            importNote(
                importNoteB,
                anchor: importWeb("example.com"),
                workspaceOverride: importRecordA,
                text: "Imported"
            )
        ],
        workspaces: [
            importRecord(importRecordA, keys: [.host(name: "example.com")])
        ]
    )

    let first = try ImportJSON.plan(
        payload,
        against: original,
        workspaces: existingWorkspaces,
        makeID: importIDFactory([importFreshA])
    )
    let (firstNotes, firstWorkspaces) = importApply(
        first,
        to: original,
        workspaces: existingWorkspaces
    )
    #expect(original.map(\.text) == ["Original"])
    #expect(firstNotes.map(\.text).contains("Imported"))

    let second = try ImportJSON.plan(
        payload,
        against: firstNotes,
        workspaces: firstWorkspaces,
        makeID: importIDFactory([importFreshB])
    )
    #expect(second.notesToAdd.count == 1)
    #expect(second.workspacesToAdd.isEmpty)
    #expect(Set(second.notesToAdd.map(\.id)).isDisjoint(with: Set(firstNotes.map(\.id))))
    #expect(second.notesToAdd[0].workspaceOverride == firstWorkspaces[0].id)
}

@Test func planRefreshesExistingAndIntraImportUUIDClashes() throws {
    let existing = importNote(importNoteA, text: "Existing")
    let payload = ImportPayload(
        notes: [
            importNote(importNoteA, text: "First import"),
            importNote(importNoteA, text: "Second import"),
        ],
        workspaces: []
    )

    let plan = try ImportJSON.plan(
        payload,
        against: [existing],
        workspaces: [],
        makeID: importIDFactory([importFreshA, importFreshB])
    )

    #expect(plan.notesToAdd.count == 2)
    #expect(Set(plan.notesToAdd.map(\.id)) == Set([importFreshA, importFreshB]))
    #expect(Set(plan.notesToAdd.map(\.text)) == Set(["First import", "Second import"]))
    #expect(existing.text == "Existing")
}

@Test func planFoldsImportedWorkspaceKeysAndRemapsOverrides() throws {
    let existing = importRecord(importRecordA, keys: [.host(name: "example.com")])
    let imported = importRecord(
        importRecordB,
        keys: [.host(name: "example.com"), .app(bundleID: "com.app")]
    )
    let note = importNote(
        importNoteA,
        anchor: importWeb("example.com"),
        workspaceOverride: importRecordB
    )
    let payload = ImportPayload(notes: [note], workspaces: [imported])

    let plan = try ImportJSON.plan(
        payload,
        against: [],
        workspaces: [existing],
        makeID: importIDFactory([importFreshA])
    )

    #expect(plan.workspacesToAdd.isEmpty)
    #expect(plan.workspaceUpdates.count == 1)
    #expect(plan.workspaceUpdates[0].id == importRecordA)
    #expect(plan.workspaceUpdates[0].keys == [
        .app(bundleID: "com.app"),
        .host(name: "example.com"),
    ])
    #expect(plan.notesToAdd[0].workspaceOverride == importRecordA)
}

@Test func planRefusesKeysSpanningMultipleExistingRecords() throws {
    let first = importRecord(importRecordA, keys: [.host(name: "example.com")])
    let second = importRecord(importRecordB, keys: [.app(bundleID: "com.app")])
    let imported = importRecord(
        UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!,
        keys: [.host(name: "example.com"), .app(bundleID: "com.app")]
    )
    let payload = ImportPayload(notes: [], workspaces: [imported])

    do {
        _ = try ImportJSON.plan(payload, against: [], workspaces: [first, second])
        Issue.record("Expected ambiguous workspace ownership to be refused")
    } catch let error as ImportJSONError {
        #expect(error == .ambiguousWorkspaceKeys([
            .app(bundleID: "com.app"),
            .host(name: "example.com"),
        ]))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func planIsDeterministicWithAnInjectedIDSource() throws {
    let imported = importRecord(importRecordB, keys: [.app(bundleID: "com.app")])
    let note = importNote(
        importNoteA,
        workspaceOverride: importRecordB,
        text: "Deterministic"
    )
    let payload = ImportPayload(notes: [note], workspaces: [imported])

    let first = try ImportJSON.plan(
        payload,
        against: [],
        workspaces: [],
        makeID: importIDFactory([importFreshA])
    )
    let second = try ImportJSON.plan(
        payload,
        against: [],
        workspaces: [],
        makeID: importIDFactory([importFreshA])
    )

    #expect(first == second)
    #expect(first.notesToAdd[0].workspaceOverride == importFreshA)
    #expect(first.workspacesToAdd[0].id == importFreshA)
}

@Test func decodeDoesNotMutateInputData() throws {
    let note = importNote(importNoteA, text: "Stable")
    let data = try NotesDocument.encode(
        NotesDocument(notes: [note], workspaces: []),
        version: 2
    )
    let original = Array(data)

    _ = try ImportJSON.decode(data)
    _ = try ImportJSON.decode(data)

    #expect(Array(data) == original)
}
