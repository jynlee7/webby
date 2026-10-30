import Foundation
import Testing
@testable import Webby
import WebbyCore

private let selectionNow = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
private func makeSelectionModel(hosts: [String]) throws -> (LibraryModel, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbyWorkspaceSelection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
    for host in hosts {
        let note = Note(
            anchor: .web(page: PageURL(host: host, path: "/"), scope: .page),
            text: host,
            frame: NoteFrame(),
            placement: .screen,
            createdAt: selectionNow,
            updatedAt: selectionNow
        )
        #expect(store.add(note))
    }
    let permission = AccessibilityPermission()
    let controller = NotesController(
        store: store,
        monitor: ContextMonitor(permission: permission),
        permission: permission,
        themes: .fallback,
        now: { selectionNow }
    )
    return (LibraryModel(controller: controller, clock: { selectionNow }), directory)
}

@MainActor
@Suite struct LibraryModelWorkspaceSelectionTests {
    private func group(_ model: LibraryModel, host: String) throws -> LibraryWorkspaceGroup {
        try #require(model.result.workspaces.first { $0.destination == .implicit(.host(name: host)) })
    }

    @Test func renamingASelectedImplicitWorkspaceSelectsItsRecord() throws {
        let (model, directory) = try makeSelectionModel(hosts: ["a.example"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let implicit = try group(model, host: "a.example")
        model.select(workspace: implicit.destination)

        model.rename(implicit, to: "Alpha")

        guard case .record? = model.selectedWorkspace else {
            Issue.record("expected a record, got \(String(describing: model.selectedWorkspace))")
            return
        }
        #expect(model.selectedWorkspaceGroup?.displayName == "Alpha")
    }

    @Test func mergingTheSelectedSourceSelectsTheTarget() throws {
        let (model, directory) = try makeSelectionModel(hosts: ["a.example", "b.example"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try group(model, host: "a.example")
        let target = try group(model, host: "b.example")
        model.select(workspace: source.destination)

        model.merge(source, into: target)

        guard case .record(let id)? = model.selectedWorkspace else {
            Issue.record("expected a record, got \(String(describing: model.selectedWorkspace))")
            return
        }
        #expect(model.selectedWorkspaceGroup?.record?.id == id)
        #expect(model.selectedWorkspaceGroup?.record?.keys.count == 2)
    }

    @Test func pinningASelectedImplicitWorkspaceKeepsItSelected() throws {
        let (model, directory) = try makeSelectionModel(hosts: ["a.example"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let implicit = try group(model, host: "a.example")
        model.select(workspace: implicit.destination)

        model.setPinned(implicit, pinned: true)

        guard case .record? = model.selectedWorkspace else {
            Issue.record("expected a record, got \(String(describing: model.selectedWorkspace))")
            return
        }
        #expect(model.selectedWorkspaceGroup?.pinned == true)
    }
}
