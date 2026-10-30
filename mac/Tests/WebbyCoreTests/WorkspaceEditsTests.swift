import Foundation
import Testing
@testable import WebbyCore

private let weDate = Date(timeIntervalSince1970: 1_700_000_000)
private let weLater = Date(timeIntervalSince1970: 1_700_000_500)

private func weNote(host: String? = nil, override: UUID? = nil) -> Note {
    Note(
        anchor: host.map { .web(page: PageURL(host: $0, path: "/"), scope: .page) },
        workspaceOverride: override,
        frame: NoteFrame(),
        placement: .window,
        createdAt: weDate,
        updatedAt: weDate
    )
}

private func weStore(notes: [Note], workspaces: [WorkspaceRecord] = []) throws -> (NoteStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbyWorkspaceEditsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("notes.json")
    let store = NoteStore(fileURL: url, now: weDate)
    for note in notes { store.add(note) }
    if !workspaces.isEmpty { try store.replaceWorkspaces(workspaces) }
    return (store, dir)
}

private let a = WorkspaceKey.host(name: "a.example")
private let b = WorkspaceKey.host(name: "b.example")
private let c = WorkspaceKey.host(name: "c.example")

@Test func renameMaterializesImplicitWorkspaceAndBlankRestoresDefault() throws {
    let edit = try WorkspaceEdits.rename(.implicit(a), to: "  Research ", in: [], now: weDate)
    #expect(edit.records.count == 1)
    #expect(edit.records[0].keys == [a])
    #expect(edit.records[0].title == "Research")
    #expect(edit.destination == .record(edit.records[0].id))

    let cleared = try WorkspaceEdits.rename(edit.destination, to: " \n", in: edit.records)
    #expect(cleared.records[0].title == nil)
    #expect(cleared.records.count == 1)
}

@Test func pinMaterializesAndTogglesExistingRecord() throws {
    let pinned = try WorkspaceEdits.setPinned(.implicit(a), true, in: [], now: weDate)
    #expect(pinned.records[0].pinned)
    let unpinned = try WorkspaceEdits.setPinned(pinned.destination, false, in: pinned.records)
    #expect(unpinned.records.count == 1 && !unpinned.records[0].pinned)
}

@Test func inboxAndUnknownRecordsAreRejected() {
    #expect(throws: WorkspaceEditError.inboxNotEditable) {
        try WorkspaceEdits.rename(.inbox, to: "x", in: [])
    }
    #expect(throws: WorkspaceEditError.inboxNotEditable) {
        try WorkspaceEdits.merge(.inbox, into: .implicit(a), records: [], notes: [])
    }
    #expect(throws: WorkspaceEditError.inboxNotEditable) {
        try WorkspaceEdits.merge(.implicit(a), into: .inbox, records: [], notes: [])
    }
    let missing = UUID()
    #expect(throws: WorkspaceEditError.unknownRecord(missing)) {
        try WorkspaceEdits.setPinned(.record(missing), true, in: [])
    }
    #expect(throws: WorkspaceEditError.mergeIntoSelf) {
        try WorkspaceEdits.merge(.implicit(a), into: .implicit(a), records: [], notes: [])
    }
}

@Test func mergeImplicitWorkspacesUnionsKeysIntoTarget() throws {
    let edit = try WorkspaceEdits.merge(.implicit(a), into: .implicit(b), records: [], notes: [], now: weDate)
    #expect(edit.records.count == 1)
    #expect(Set(edit.records[0].keys) == [a, b])
    #expect(edit.destination == .record(edit.records[0].id))
}

@Test func mergeRecordsKeepsTargetSettingsRemovesSourceAndRepointsOverrides() throws {
    let source = WorkspaceRecord(title: "S", keys: [a], pinned: true)
    let target = WorkspaceRecord(title: "T", keys: [b])
    let overridden = weNote(host: "zzz.example", override: source.id)
    let other = weNote(host: "zzz.example", override: target.id)
    let edit = try WorkspaceEdits.merge(
        .record(source.id), into: .record(target.id),
        records: [source, target], notes: [overridden, other]
    )
    #expect(edit.records.count == 1)
    #expect(edit.records[0].id == target.id)
    #expect(edit.records[0].title == "T")
    #expect(!edit.records[0].pinned)
    #expect(Set(edit.records[0].keys) == [a, b])
    #expect(edit.overrideChanges == [WorkspaceOverrideChange(noteID: overridden.id, workspace: target.id)])
}

@Test func splitMovesKeyBackAndRejectsLastKey() throws {
    let record = WorkspaceRecord(keys: [a, b])
    let edit = try WorkspaceEdits.split(b, from: record.id, in: [record])
    #expect(edit.records[0].keys == [a])
    #expect(throws: WorkspaceEditError.cannotSplitLastKey) {
        try WorkspaceEdits.split(a, from: record.id, in: edit.records)
    }
    #expect(throws: WorkspaceEditError.keyNotInRecord) {
        try WorkspaceEdits.split(c, from: record.id, in: [record])
    }
}

@Test func mergeThenSplitRestoresKeyDerivedDestinations() throws {
    let notes = [weNote(host: "a.example"), weNote(host: "b.example"), weNote(host: "c.example"), weNote()]
    let before = notes.map { WorkspaceResolver.resolve($0, workspaces: []) }

    let merged = try WorkspaceEdits.merge(.implicit(a), into: .implicit(b), records: [], notes: notes)
    let mergedDest = notes.map { WorkspaceResolver.resolve($0, workspaces: merged.records) }
    #expect(mergedDest[0] == merged.destination && mergedDest[1] == merged.destination)
    #expect(mergedDest[2] == before[2] && mergedDest[3] == .inbox)

    let split = try WorkspaceEdits.split(a, from: merged.records[0].id, in: merged.records)
    let afterDest = notes.map { WorkspaceResolver.resolve($0, workspaces: split.records) }
    #expect(afterDest[0] == .implicit(a))
    #expect(afterDest[1] == .record(merged.records[0].id))
    #expect(afterDest[2] == before[2] && afterDest[3] == .inbox)
}

@Test func applyIsOneGenerationAndRepointsOverrides() throws {
    let source = WorkspaceRecord(keys: [a])
    let target = WorkspaceRecord(keys: [b])
    let moved = weNote(override: source.id)
    let untouched = weNote(host: "c.example")
    let (store, dir) = try weStore(notes: [moved, untouched], workspaces: [source, target])
    defer { try? FileManager.default.removeItem(at: dir) }

    let edit = try WorkspaceEdits.merge(
        .record(source.id), into: .record(target.id),
        records: store.workspaces, notes: store.notes
    )
    let generation = store.mutationGeneration
    try store.apply(edit, now: weLater)

    #expect(store.mutationGeneration == generation + 1)
    #expect(store.workspaces == edit.records)
    let note = try #require(store.note(id: moved.id))
    #expect(note.workspaceOverride == target.id)
    #expect(note.revision == moved.revision + 1)
    #expect(note.updatedAt == weLater)
    #expect(store.note(id: untouched.id) == untouched)
}

@Test func applyClearsOverridesToRemovedRecords() throws {
    let record = WorkspaceRecord(keys: [a])
    let note = weNote(host: "x.example", override: record.id)
    let (store, dir) = try weStore(notes: [note], workspaces: [record])
    defer { try? FileManager.default.removeItem(at: dir) }

    let generation = store.mutationGeneration
    try store.apply(WorkspaceEdit(records: [], destination: .inbox), now: weLater)

    #expect(store.mutationGeneration == generation + 1)
    #expect(store.workspaces.isEmpty)
    #expect(store.note(id: note.id)?.workspaceOverride == nil)
    #expect(store.note(id: note.id)?.updatedAt == weLater)
}

@Test func applyFailureLeavesStoreUnchanged() throws {
    let record = WorkspaceRecord(keys: [a])
    let note = weNote(override: record.id)
    let (store, dir) = try weStore(notes: [note], workspaces: [record])
    defer { try? FileManager.default.removeItem(at: dir) }
    let notes = store.notes, workspaces = store.workspaces, generation = store.mutationGeneration

    let duplicate = WorkspaceEdit(records: [record, WorkspaceRecord(keys: [a])], destination: .inbox)
    #expect(throws: (any Error).self) { try store.apply(duplicate) }
    let missingNote = WorkspaceEdit(
        records: [record],
        overrideChanges: [WorkspaceOverrideChange(noteID: UUID(), workspace: nil)],
        destination: .inbox
    )
    #expect(throws: NoteStore.StoreError.invalidWorkspaceEdit) { try store.apply(missingNote) }

    #expect(store.notes == notes && store.workspaces == workspaces)
    #expect(store.mutationGeneration == generation)
}

@Test func applyOnReadOnlyStoreThrowsAndChangesNothing() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbyWorkspaceEditsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("notes.json")
    try Data(#"{"version":99}"#.utf8).write(to: url)
    let store = NoteStore(fileURL: url, now: weDate)

    let edit = try WorkspaceEdits.setPinned(.implicit(a), true, in: [])
    #expect(throws: NoteStore.StoreError.self) { try store.apply(edit) }
    #expect(store.workspaces.isEmpty)
}

@Test func applyingNoOpEditDoesNotAdvanceGeneration() throws {
    let record = WorkspaceRecord(keys: [a])
    let (store, dir) = try weStore(notes: [], workspaces: [record])
    defer { try? FileManager.default.removeItem(at: dir) }
    let generation = store.mutationGeneration
    try store.apply(WorkspaceEdit(records: [record], destination: .record(record.id)))
    #expect(store.mutationGeneration == generation)
}

@Test func pinnedWorkspacesSortFirstInLibrary() throws {
    let older = weNote(host: "a.example")
    var newer = weNote(host: "b.example")
    newer.updatedAt = weLater
    let pin = try WorkspaceEdits.setPinned(.implicit(a), true, in: [])
    let result = LibraryQuery.evaluate(notes: [older, newer], workspaces: pin.records, now: weLater)
    #expect(result.workspaces.map(\.destination) == [pin.destination, .implicit(b)])
}
