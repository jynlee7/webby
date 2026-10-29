import Foundation
import Testing
@testable import Webby
import WebbyCore

private let importFlowNow = Date(timeIntervalSince1970: 1_800_000_000)

private struct InjectedImportPlanError: LocalizedError, Equatable {
    var errorDescription: String? { "injected plan failure" }
}

private final class ImportFlowCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func makeImportFlowDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbyImportFlow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func importFlowNote(
    text: String,
    anchor: Anchor? = nil,
    workspaceOverride: UUID? = nil
) -> Note {
    Note(
        anchor: anchor,
        workspaceOverride: workspaceOverride,
        text: text,
        frame: NoteFrame(),
        placement: .window,
        createdAt: importFlowNow,
        updatedAt: importFlowNow
    )
}

@MainActor
private func makeImportFlowController(_ store: NoteStore) -> NotesController {
    let permission = AccessibilityPermission()
    let monitor = ContextMonitor(permission: permission)
    return NotesController(
        store: store,
        monitor: monitor,
        permission: permission,
        themes: .fallback,
        now: { importFlowNow }
    )
}

@MainActor
@Suite struct ImportControllerFlowTests {
    @Test func aCancelledPanelIsANoOp() async throws {
        let directory = try makeImportFlowDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        let existing = importFlowNote(text: "existing")
        #expect(store.add(existing))
        let controller = makeImportFlowController(store)
        let model = LibraryModel(controller: controller, clock: { importFlowNow })

        let loaderCalls = ImportFlowCounter()
        let planCalls = ImportFlowCounter()
        let commitCalls = ImportFlowCounter()
        let alertCalls = ImportFlowCounter()
        let payload = ImportPayload(notes: [], workspaces: [])
        let importController = ImportController(
            model: model,
            notes: controller,
            commitDrafts: { commitCalls.increment() },
            openPanel: { nil },
            loadPayload: { _ in
                loaderCalls.increment()
                return payload
            },
            planBuilder: { payload, notes, workspaces in
                planCalls.increment()
                return try ImportJSON.plan(payload, against: notes, workspaces: workspaces)
            },
            alert: { _, _ in alertCalls.increment() }
        )

        await importController.importJSON()

        #expect(loaderCalls.count == 0)
        #expect(planCalls.count == 0)
        #expect(commitCalls.count == 0)
        #expect(alertCalls.count == 0)
        #expect(model.importStatus == nil)
        #expect(store.notes.map(\.id) == [existing.id])
    }

    @Test func readPayloadRefusesAFileLargerThanTheBoundedLimit() throws {
        let directory = try makeImportFlowDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("export.json")
        let valid = Data(#"{"version":2,"notes":[],"workspaces":[]}"#.utf8)
        try valid.write(to: url)

        let payload = try ImportController.readPayload(from: url, maximumBytes: valid.count)
        #expect(payload.notes.isEmpty)
        #expect(payload.workspaces.isEmpty)

        do {
            _ = try ImportController.readPayload(from: url, maximumBytes: valid.count - 1)
            Issue.record("Expected a file over the import limit to be refused")
        } catch let error as ImportController.ImportError {
            #expect(error == .fileTooLarge(valid.count - 1))
        }

        #expect(try Data(contentsOf: url) == valid)
    }

    @Test func decodeFailureSurfacesWithoutMutatingStoreOrFile() async throws {
        let directory = try makeImportFlowDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notesURL = directory.appendingPathComponent("notes.json")
        let sourceURL = directory.appendingPathComponent("broken.json")
        let broken = Data(#"{"version":2,"notes":"#.utf8)
        try broken.write(to: sourceURL)

        let store = NoteStore(fileURL: notesURL)
        let existing = importFlowNote(text: "existing")
        #expect(store.add(existing))
        try store.save()
        let notesBefore = try Data(contentsOf: notesURL)

        let controller = makeImportFlowController(store)
        let model = LibraryModel(controller: controller, clock: { importFlowNow })
        let commitCalls = ImportFlowCounter()
        var alerts: [(String, String)] = []
        let importController = ImportController(
            model: model,
            notes: controller,
            commitDrafts: { commitCalls.increment() },
            openPanel: { sourceURL },
            alert: { title, message in alerts.append((title, message)) }
        )

        await importController.importJSON()

        #expect(commitCalls.count == 0)
        #expect(alerts.count == 1)
        #expect(alerts.first?.0 == "Import Failed")
        #expect(model.importStatus?.hasPrefix("Import failed:") == true)
        #expect(store.notes.map(\.id) == [existing.id])
        #expect(try Data(contentsOf: notesURL) == notesBefore)
        #expect(try Data(contentsOf: sourceURL) == broken)
    }

    @Test func planFailureSurfacesWithoutMutatingStoreOrFile() async throws {
        let directory = try makeImportFlowDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notesURL = directory.appendingPathComponent("notes.json")
        let sourceURL = directory.appendingPathComponent("export.json")
        let exported = try ExportJSON.encode(
            notes: [importFlowNote(text: "incoming")],
            workspaces: []
        )
        try exported.write(to: sourceURL)

        let store = NoteStore(fileURL: notesURL)
        let existing = importFlowNote(text: "existing")
        #expect(store.add(existing))
        try store.save()
        let notesBefore = try Data(contentsOf: notesURL)

        let controller = makeImportFlowController(store)
        let model = LibraryModel(controller: controller, clock: { importFlowNow })
        let planCalls = ImportFlowCounter()
        var alerts: [(String, String)] = []
        let importController = ImportController(
            model: model,
            notes: controller,
            openPanel: { sourceURL },
            planBuilder: { _, _, _ in
                planCalls.increment()
                throw InjectedImportPlanError()
            },
            alert: { title, message in alerts.append((title, message)) }
        )

        await importController.importJSON()

        #expect(planCalls.count == 1)
        #expect(alerts.count == 1)
        #expect(alerts.first?.0 == "Import Failed")
        #expect(alerts.first?.1 == "injected plan failure")
        #expect(model.importStatus == "Import failed: injected plan failure")
        #expect(store.notes.map(\.id) == [existing.id])
        #expect(try Data(contentsOf: notesURL) == notesBefore)
        #expect(try Data(contentsOf: sourceURL) == exported)
    }

    @Test func successfulImportAppliesThePlanThroughTheControllerOnce() async throws {
        let directory = try makeImportFlowDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notesURL = directory.appendingPathComponent("notes.json")
        let sourceURL = directory.appendingPathComponent("export.json")
        let recordID = UUID(uuidString: "33333333-0000-0000-0000-000000000041")!
        let record = WorkspaceRecord(
            id: recordID,
            keys: [.host(name: "example.com")],
            createdAt: importFlowNow
        )
        let imported = Note(
            anchor: .web(page: PageURL(host: "example.com", path: "/docs"), scope: .page),
            workspaceOverride: recordID,
            text: "imported heading",
            frame: NoteFrame(),
            placement: .window,
            createdAt: importFlowNow,
            updatedAt: importFlowNow
        )
        let exported = try ExportJSON.encode(notes: [imported], workspaces: [record])
        try exported.write(to: sourceURL)

        let store = NoteStore(fileURL: notesURL)
        let existing = importFlowNote(text: "existing")
        #expect(store.add(existing))
        try store.save()
        let beforeGeneration = store.mutationGeneration

        let controller = makeImportFlowController(store)
        let model = LibraryModel(controller: controller, clock: { importFlowNow })
        let planCalls = ImportFlowCounter()
        var alerts: [(String, String)] = []
        let importController = ImportController(
            model: model,
            notes: controller,
            openPanel: { sourceURL },
            planBuilder: { payload, notes, workspaces in
                planCalls.increment()
                return try ImportJSON.plan(payload, against: notes, workspaces: workspaces)
            },
            alert: { title, message in alerts.append((title, message)) }
        )

        await importController.importJSON()

        #expect(planCalls.count == 1)
        #expect(store.mutationGeneration == beforeGeneration + 1)
        #expect(store.notes.map(\.id).contains(existing.id))
        #expect(store.notes.contains { $0.id == imported.id && $0.text == "imported heading" })
        // New workspaces receive fresh IDs; the imported key and override are preserved.
        let importedRecord = store.workspaces.first { $0.keys.contains(.host(name: "example.com")) }
        let record = try #require(importedRecord)
        #expect(store.notes.first { $0.id == imported.id }?.workspaceOverride == record.id)
        #expect(alerts.count == 1)
        #expect(alerts.first?.0 == "Import Complete")
        #expect(alerts.first?.1 == "1 note, 1 workspace")
        #expect(model.importStatus == "1 note, 1 workspace")
        if case let .succeeded(result) = controller.importState {
            #expect(
                result.summary
                    == ImportPlan.Summary(
                        notesAdded: 1,
                        workspacesAdded: 1,
                        workspacesUpdated: 0
                    )
            )
        } else {
            Issue.record("Expected the controller import state to succeed")
        }
        #expect(try Data(contentsOf: sourceURL) == exported)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    }
}
