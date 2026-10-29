import AppKit
import Foundation
import WebbyCore

/// Runs the JSON import open-panel flow against the live Library snapshot.
///
/// The selected export file is only read, never moved or rewritten. Decoding and
/// planning are side-effect-free; the store mutation happens only through the
/// existing serialized `NotesController.importNotes(_:)` transaction.
@MainActor
final class ImportController {
    enum ImportError: LocalizedError, Equatable {
        case fileTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .fileTooLarge(let limit):
                return "That JSON file is larger than the \(limit / 1_048_576) MB import limit."
            }
        }
    }

    static let maximumImportBytes = 50 * 1_048_576

    typealias OpenPanelProvider = @MainActor () -> URL?
    typealias PayloadLoader = @MainActor (URL) throws -> ImportPayload
    typealias PlanBuilder = @MainActor (
        ImportPayload,
        [Note],
        [WorkspaceRecord]
    ) throws -> ImportPlan
    typealias AlertPresenter = @MainActor (String, String) -> Void

    private let model: LibraryModel
    private let notes: NotesController
    private let commitDrafts: @MainActor () -> Void
    private let openPanel: OpenPanelProvider
    private let loadPayload: PayloadLoader
    private let planBuilder: PlanBuilder
    private let alert: AlertPresenter

    init(
        model: LibraryModel,
        notes: NotesController,
        commitDrafts: @escaping @MainActor () -> Void = {},
        openPanel: @escaping OpenPanelProvider = ImportController.presentOpenPanel,
        loadPayload: @escaping PayloadLoader = { try ImportController.readPayload(from: $0) },
        planBuilder: PlanBuilder? = nil,
        alert: @escaping AlertPresenter = ImportController.presentAlert
    ) {
        self.model = model
        self.notes = notes
        self.commitDrafts = commitDrafts
        self.openPanel = openPanel
        self.loadPayload = loadPayload
        self.planBuilder = planBuilder ?? { payload, notes, workspaces in
            try ImportJSON.plan(payload, against: notes, workspaces: workspaces)
        }
        self.alert = alert
    }

    /// Cancelling the panel is a no-op. A failed decode or plan shows an alert and
    /// leaves both the selected file and the store untouched.
    func importJSON() async {
        guard let url = openPanel() else { return }

        model.importStatus = "Importing..."
        do {
            let payload = try loadPayload(url)
            commitDrafts()
            let plan = try planBuilder(
                payload,
                notes.libraryNotes,
                notes.libraryWorkspaces
            )
            let summary = try await notes.importNotes(plan)

            model.importStatus = summary.reason
            alert("Import Complete", summary.reason)
        } catch {
            model.importStatus = "Import failed: \(error.localizedDescription)"
            alert("Import Failed", error.localizedDescription)
        }
    }

    static func presentOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["json"]
        panel.message = "Choose a Webby JSON export to import."
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Reads at most the import limit plus one byte, so an oversized file is rejected
    /// without loading the whole thing into memory.
    static func readPayload(
        from url: URL,
        maximumBytes: Int = ImportController.maximumImportBytes
    ) throws -> ImportPayload {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw ImportError.fileTooLarge(maximumBytes)
        }
        return try ImportJSON.decode(data)
    }

    static func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = title == "Import Failed" ? .warning : .informational
        alert.runModal()
    }
}
