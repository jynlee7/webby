import AppKit
import Foundation
import WebbyCore

/// Runs the Export menu's save-panel flow and builds deterministic export data.
///
/// The controller commits the retained editor drafts before it takes its snapshot.
/// It never writes through the panel directly; writes go to a temporary sibling and
/// only replace the destination after the panel (or the injected confirmation) has
/// accepted an overwrite.
@MainActor
final class ExportController {
    enum Format: String, CaseIterable, Equatable, Sendable {
        case markdown
        case html
        case json

        var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .html: return "html"
            case .json: return "json"
            }
        }
    }

    enum ExportError: LocalizedError, Equatable {
        case destinationExists(URL)

        var errorDescription: String? {
            switch self {
            case .destinationExists(let url):
                return "A file already exists at \(url.path)."
            }
        }
    }

    struct Document: Equatable {
        let data: Data
        let filename: String
        let format: Format
    }

    typealias SnapshotProvider = @MainActor () -> LibraryModel.ExportSnapshot
    typealias SavePanelProvider = @MainActor (String, Format) -> URL?
    typealias Writer = @MainActor (Data, URL, Bool) throws -> Void
    typealias OverwriteConfirmation = @MainActor (URL) -> Bool

    private let model: LibraryModel
    private let commitDrafts: @MainActor () -> Void
    private let snapshot: SnapshotProvider
    private let savePanel: SavePanelProvider
    private let writer: Writer
    private let confirmOverwrite: OverwriteConfirmation

    init(
        model: LibraryModel,
        commitDrafts: @escaping @MainActor () -> Void = {},
        snapshot: SnapshotProvider? = nil,
        savePanel: @escaping SavePanelProvider = ExportController.presentSavePanel,
        writer: @escaping Writer = ExportController.writeAtomically,
        confirmOverwrite: @escaping OverwriteConfirmation = { _ in true }
    ) {
        self.model = model
        self.commitDrafts = commitDrafts
        self.snapshot = snapshot ?? { model.exportSnapshot() }
        self.savePanel = savePanel
        self.writer = writer
        self.confirmOverwrite = confirmOverwrite
    }

    /// Builds the file contents and deterministic name. Drafts are committed before
    /// the snapshot so the export includes text that is still in the editor.
    func makeDocument(
        selection: LibraryExportSelection,
        format: Format,
        includeCanonicalSourceURLs: Bool = false
    ) throws -> Document {
        commitDrafts()
        let snapshot = snapshot()

        switch format {
        case .json:
            let jsonSelection: ExportJSONOptions.Selection
            switch selection {
            case .workspace(let destination):
                jsonSelection = .workspace(destination)
            case .all:
                jsonSelection = .all
            case .selected(let ids):
                jsonSelection = .notes(ids)
            case .page:
                jsonSelection = .notes(Set(notes(for: selection, snapshot: snapshot).map(\.id)))
            }

            let data = try ExportJSON.encode(
                notes: snapshot.notes,
                workspaces: snapshot.workspaces,
                options: ExportJSONOptions(
                    includeCanonicalSourceURLs: includeCanonicalSourceURLs,
                    selection: jsonSelection
                ),
                queryRules: snapshot.queryRules
            )
            return Document(
                data: data,
                filename: filename(for: selection, format: format, snapshot: snapshot),
                format: format
            )

        case .markdown, .html:
            let document = compiledDocument(for: selection, snapshot: snapshot)
            let rendered: String
            switch format {
            case .markdown:
                rendered = MarkdownRenderer.render(document)
            case .html:
                rendered = HTMLRenderer.render(document)
            case .json:
                preconditionFailure("Handled above")
            }
            return Document(
                data: Data(rendered.utf8),
                filename: filename(for: selection, format: format, snapshot: snapshot),
                format: format
            )
        }
    }

    /// Shows the save panel and writes the document. Read-only stores are allowed;
    /// export is a pure read of the Library snapshot.
    @discardableResult
    func export(
        selection: LibraryExportSelection,
        format: Format,
        includeCanonicalSourceURLs: Bool = false
    ) throws -> URL? {
        let document = try makeDocument(
            selection: selection,
            format: format,
            includeCanonicalSourceURLs: includeCanonicalSourceURLs
        )
        guard let url = savePanel(document.filename, format) else { return nil }

        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists && !confirmOverwrite(url) {
            return nil
        }

        try writer(document.data, url, exists)
        model.exportStatus = "Exported \(document.filename)"
        return url
    }

    /// UI entry point that reports failures without throwing into SwiftUI.
    func run(
        selection: LibraryExportSelection,
        format: Format,
        includeCanonicalSourceURLs: Bool = false
    ) {
        do {
            _ = try export(
                selection: selection,
                format: format,
                includeCanonicalSourceURLs: includeCanonicalSourceURLs
            )
        } catch {
            Self.present(error: error)
        }
    }

    static func presentSavePanel(filename: String, format: Format) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false
        panel.allowedFileTypes = [format.fileExtension]
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Writes a temporary sibling and moves it into place. When `allowOverwrite` is
    /// false, an existing file is an error instead of a silent replacement.
    static func writeAtomically(_ data: Data, to url: URL, allowOverwrite: Bool) throws {
        let manager = FileManager.default
        let exists = manager.fileExists(atPath: url.path)
        if exists && !allowOverwrite {
            throw ExportError.destinationExists(url)
        }

        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )

        do {
            try data.write(to: temporary, options: .atomic)
            if exists {
                _ = try manager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: url)
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    static func present(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Export Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Content

    private func notes(
        for selection: LibraryExportSelection,
        snapshot: LibraryModel.ExportSnapshot
    ) -> [Note] {
        let durable = snapshot.notes.filter { !$0.ephemeral }

        switch selection {
        case .workspace(let destination):
            return durable.filter {
                LibraryEligibility.isOrdinary($0)
                    && WorkspaceResolver.resolve($0, workspaces: snapshot.workspaces) == destination
            }

        case .page(let destination, let page):
            let document = CompiledDocument.page(
                page,
                destination: destination,
                notes: snapshot.notes,
                workspaces: snapshot.workspaces,
                queryRules: snapshot.queryRules
            )
            let ids = Set(document.sections.flatMap { $0.notes.map(\.id) })
            return durable.filter { ids.contains($0.id) }

        case .all:
            return durable.filter(LibraryEligibility.isOrdinary)

        case .selected(let ids):
            return durable.filter { ids.contains($0.id) }
        }
    }

    private func compiledDocument(
        for selection: LibraryExportSelection,
        snapshot: LibraryModel.ExportSnapshot
    ) -> CompiledDocument {
        switch selection {
        case .workspace(let destination):
            return CompiledDocument.workspace(
                destination: destination,
                notes: snapshot.notes,
                workspaces: snapshot.workspaces,
                queryRules: snapshot.queryRules
            )

        case .page(let destination, let page):
            return CompiledDocument.page(
                page,
                destination: destination,
                notes: snapshot.notes,
                workspaces: snapshot.workspaces,
                queryRules: snapshot.queryRules
            )

        case .all:
            return selectedDocument(
                title: "All Notes",
                notes: notes(for: selection, snapshot: snapshot),
                snapshot: snapshot
            )

        case .selected:
            return selectedDocument(
                title: "Selected Notes",
                notes: notes(for: selection, snapshot: snapshot),
                snapshot: snapshot
            )
        }
    }

    private func selectedDocument(
        title: String,
        notes: [Note],
        snapshot: LibraryModel.ExportSnapshot
    ) -> CompiledDocument {
        let section = CompiledSection(
            kind: .workspaceNotes,
            heading: title,
            notes: compiledNotes(notes, queryRules: snapshot.queryRules)
        )
        return CompiledDocument(
            scope: .workspace(.inbox),
            title: title,
            sections: [section]
        )
    }

    private func compiledNotes(_ notes: [Note], queryRules: [QueryRule]) -> [CompiledNote] {
        NoteOrdering.sorted(notes, by: .pinnedThenCreatedAscending).map { note in
            let (title, body) = Self.titleAndBody(note.text)
            return CompiledNote(
                id: note.id,
                title: title,
                body: body,
                createdAt: note.createdAt,
                isPinned: note.pinnedAt != nil,
                isHidden: note.hidden,
                isCollapsed: note.collapsed,
                isExcludedFromAgent: note.excludedFromAgent,
                tags: Tags.parse(note.text).map(\.name),
                noteLink: CompiledLink(title: "Open note", url: NoteLink.url(for: note.id)),
                pageLink: Self.pageLink(for: note, queryRules: queryRules)
            )
        }
    }

    private static func pageLink(for note: Note, queryRules: [QueryRule]) -> CompiledLink? {
        guard case .web(let page, _)? = note.anchor,
              let url = CanonicalExportURL.make(for: page, queryRules: queryRules)
        else { return nil }
        return CompiledLink(title: "Open page", url: url)
    }

    private static func titleAndBody(_ text: String) -> (title: String, body: String) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        guard let titleIndex = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else {
            return ("Untitled", "")
        }

        let title = lines[titleIndex].trimmingCharacters(in: .whitespaces)
        var bodyLines = Array(lines[(titleIndex + 1)...])
        while let first = bodyLines.first,
              first.trimmingCharacters(in: .whitespaces).isEmpty {
            bodyLines.removeFirst()
        }
        while let last = bodyLines.last,
              last.trimmingCharacters(in: .whitespaces).isEmpty {
            bodyLines.removeLast()
        }
        return (title, bodyLines.joined(separator: "\n"))
    }

    // MARK: - Filenames

    private func filename(
        for selection: LibraryExportSelection,
        format: Format,
        snapshot: LibraryModel.ExportSnapshot
    ) -> String {
        let base: String
        switch selection {
        case .workspace(let destination):
            base = Self.slug(workspaceName(for: destination, snapshot: snapshot)) + "-workspace"
        case .page(_, let page):
            base = Self.slug(page.host + page.path) + "-page"
        case .all:
            base = "all-notes"
        case .selected:
            base = "selected-notes"
        }
        return "webby-\(base).\(format.fileExtension)"
    }

    private func workspaceName(
        for destination: WorkspaceDestination,
        snapshot: LibraryModel.ExportSnapshot
    ) -> String {
        switch destination {
        case .inbox:
            return "inbox"
        case .implicit(let key):
            return key.displayName
        case .record(let id):
            guard let record = snapshot.workspaces.first(where: { $0.id == id }) else {
                return "workspace"
            }
            if let title = record.title?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                return title
            }
            if let key = record.keys.map(\.displayName).min() {
                return key
            }
            return "workspace"
        }
    }

    private static func slug(_ text: String) -> String {
        let folded = text.precomposedStringWithCanonicalMapping.lowercased()
        var output = ""
        var lastWasSeparator = true

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                output.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                output.append("-")
                lastWasSeparator = true
            }
        }

        while output.hasSuffix("-") {
            output.removeLast()
        }
        if output.count > 60 {
            output = String(output.prefix(60))
            while output.hasSuffix("-") {
                output.removeLast()
            }
        }
        return output.isEmpty ? "notes" : output
    }
}
