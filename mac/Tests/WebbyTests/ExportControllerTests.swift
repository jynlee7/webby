import Foundation
import Testing
@testable import Webby
import WebbyCore

private let exportTestNow = Date(timeIntervalSince1970: 1_800_000_000)

private func makeExportDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbyExportController-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func exportTestNote(
    id: UUID = UUID(),
    text: String,
    anchor: Anchor? = nil,
    workspaceOverride: UUID? = nil,
    ephemeral: Bool = false
) -> Note {
    Note(
        id: id,
        anchor: anchor,
        workspaceOverride: workspaceOverride,
        text: text,
        frame: NoteFrame(),
        placement: .window,
        createdAt: exportTestNow,
        updatedAt: exportTestNow,
        ephemeral: ephemeral
    )
}

@MainActor
private func makeExportController(_ store: NoteStore) -> NotesController {
    let permission = AccessibilityPermission()
    let monitor = ContextMonitor(permission: permission)
    return NotesController(
        store: store,
        monitor: monitor,
        permission: permission,
        themes: .fallback,
        now: { exportTestNow }
    )
}

@MainActor
private func makeExportModel(
    notes: [Note],
    workspaces: [WorkspaceRecord] = []
) throws -> (LibraryModel, URL) {
    let directory = try makeExportDirectory()
    let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
    if !workspaces.isEmpty {
        try store.replaceWorkspaces(workspaces)
    }
    for note in notes {
        #expect(store.add(note))
    }
    let model = LibraryModel(controller: makeExportController(store), clock: { exportTestNow })
    return (model, directory)
}

private func decodedNoteIDs(_ data: Data) throws -> Set<UUID> {
    Set(try ImportJSON.decode(data).notes.map(\.id))
}

@MainActor
@Suite struct ExportControllerTests {
    @Test func filenamesAreDeterministicForEverySelection() throws {
        let recordID = UUID(uuidString: "11111111-0000-0000-0000-000000000031")!
        let page = PageURL(host: "example.com", path: "/docs/install")
        let record = WorkspaceRecord(
            id: recordID,
            title: "Docs Site",
            keys: [.host(name: "example.com")],
            createdAt: exportTestNow
        )
        let note = exportTestNote(
            text: "Page heading",
            anchor: .web(page: page, scope: .page),
            workspaceOverride: recordID
        )
        let (model, directory) = try makeExportModel(notes: [note], workspaces: [record])
        defer { try? FileManager.default.removeItem(at: directory) }
        let export = ExportController(model: model)

        #expect(try export.makeDocument(selection: .all, format: .json).filename == "webby-all-notes.json")
        #expect(
            try export.makeDocument(selection: .selected([note.id]), format: .markdown).filename
                == "webby-selected-notes.md"
        )
        #expect(
            try export.makeDocument(selection: .workspace(.inbox), format: .html).filename
                == "webby-inbox-workspace.html"
        )
        #expect(
            try export.makeDocument(selection: .workspace(.record(recordID)), format: .json).filename
                == "webby-docs-site-workspace.json"
        )
        #expect(
            try export.makeDocument(selection: .page(.record(recordID), page), format: .json).filename
                == "webby-example-com-docs-install-page.json"
        )

        let first = try export.makeDocument(selection: .all, format: .json)
        let second = try export.makeDocument(selection: .all, format: .json)
        #expect(first.data == second.data)
        #expect(first.filename == second.filename)
    }

    @Test func markdownHTMLAndJSONRespectEverySelectionScope() throws {
        let recordID = UUID(uuidString: "22222222-0000-0000-0000-000000000032")!
        let page = PageURL(host: "example.com", path: "/docs")
        let record = WorkspaceRecord(
            id: recordID,
            keys: [.host(name: "example.com")],
            createdAt: exportTestNow
        )
        let inbox = exportTestNote(text: "Inbox Heading\nInbox body")
        let pageNote = exportTestNote(
            text: "Page Heading\nPage body",
            anchor: .web(page: page, scope: .page),
            workspaceOverride: recordID
        )
        let (model, directory) = try makeExportModel(
            notes: [inbox, pageNote],
            workspaces: [record]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let export = ExportController(model: model)

        let allJSON = try export.makeDocument(selection: .all, format: .json)
        #expect(try decodedNoteIDs(allJSON.data) == [inbox.id, pageNote.id])

        let selectedJSON = try export.makeDocument(
            selection: .selected([inbox.id]),
            format: .json
        )
        #expect(try decodedNoteIDs(selectedJSON.data) == [inbox.id])

        let workspaceJSON = try export.makeDocument(
            selection: .workspace(.record(recordID)),
            format: .json
        )
        #expect(try decodedNoteIDs(workspaceJSON.data) == [pageNote.id])

        let pageJSON = try export.makeDocument(
            selection: .page(.record(recordID), page),
            format: .json
        )
        #expect(try decodedNoteIDs(pageJSON.data) == [pageNote.id])

        let selectedMarkdown = try export.makeDocument(
            selection: .selected([inbox.id]),
            format: .markdown
        )
        let markdown = String(decoding: selectedMarkdown.data, as: UTF8.self)
        #expect(markdown.contains("Inbox Heading"))
        #expect(!markdown.contains("Page Heading"))

        let workspaceHTML = try export.makeDocument(
            selection: .workspace(.record(recordID)),
            format: .html
        )
        let html = String(decoding: workspaceHTML.data, as: UTF8.self)
        #expect(html.contains("Page Heading"))
        #expect(!html.contains("Inbox Heading"))
    }

    @Test func draftCommitRunsBeforeTheSnapshot() throws {
        let (model, directory) = try makeExportModel(notes: [exportTestNote(text: "Model note")])
        defer { try? FileManager.default.removeItem(at: directory) }

        var events: [String] = []
        let snapshot = LibraryModel.ExportSnapshot(
            notes: [exportTestNote(text: "Snapshot note")],
            workspaces: [],
            queryRules: []
        )
        let export = ExportController(
            model: model,
            commitDrafts: { events.append("commit") },
            snapshot: {
                events.append("snapshot")
                return snapshot
            }
        )

        let document = try export.makeDocument(selection: .all, format: .json)

        #expect(events == ["commit", "snapshot"])
        #expect(try decodedNoteIDs(document.data).count == 1)
    }

    @Test func atomicWriterPublishesThroughATemporarySiblingAndRefusesSilentOverwrite() throws {
        let directory = try makeExportDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("export.json")
        let first = Data("first".utf8)
        let second = Data("second".utf8)

        try ExportController.writeAtomically(first, to: destination, allowOverwrite: false)
        #expect(try Data(contentsOf: destination) == first)

        do {
            try ExportController.writeAtomically(second, to: destination, allowOverwrite: false)
            Issue.record("Expected an existing destination to be refused")
        } catch let error as ExportController.ExportError {
            #expect(error == .destinationExists(destination))
        }
        #expect(try Data(contentsOf: destination) == first)

        try ExportController.writeAtomically(second, to: destination, allowOverwrite: true)
        #expect(try Data(contentsOf: destination) == second)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains { $0.hasSuffix(".tmp") })
    }

    @Test func exportRefusesToOverwriteWithoutConfirmation() throws {
        let (model, directory) = try makeExportModel(notes: [exportTestNote(text: "Export body")])
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("export.json")
        let original = Data("original".utf8)
        try original.write(to: destination)

        var writerCalled = false
        var confirmations = 0
        let export = ExportController(
            model: model,
            savePanel: { _, _ in destination },
            writer: { data, url, _ in
                writerCalled = true
                try data.write(to: url)
            },
            confirmOverwrite: { url in
                #expect(url == destination)
                confirmations += 1
                return false
            }
        )

        let result = try export.export(selection: .all, format: .json)

        #expect(result == nil)
        #expect(confirmations == 1)
        #expect(writerCalled == false)
        #expect(try Data(contentsOf: destination) == original)
        #expect(model.exportStatus == nil)
    }

    @Test func selectedNoteExportExcludesEphemeralNotes() throws {
        let (model, directory) = try makeExportModel(notes: [exportTestNote(text: "Model note")])
        defer { try? FileManager.default.removeItem(at: directory) }

        let durable = exportTestNote(text: "Durable heading")
        let ephemeral = exportTestNote(text: "Ephemeral heading", ephemeral: true)
        let snapshot = LibraryModel.ExportSnapshot(
            notes: [durable, ephemeral],
            workspaces: [],
            queryRules: []
        )
        let export = ExportController(model: model, snapshot: { snapshot })
        let selection = LibraryExportSelection.selected([durable.id, ephemeral.id])

        let json = try export.makeDocument(selection: selection, format: .json)
        #expect(try decodedNoteIDs(json.data) == [durable.id])

        let markdownDocument = try export.makeDocument(selection: selection, format: .markdown)
        let markdown = String(decoding: markdownDocument.data, as: UTF8.self)
        #expect(markdown.contains("Durable heading"))
        #expect(!markdown.contains("Ephemeral heading"))
    }
}
