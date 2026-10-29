import AppKit
import SwiftUI
import WebbyCore

struct LibraryContentView: View {
    let model: LibraryModel
    let actions: LibraryAnchorActions
    let draft: LibraryTextDraft
    let exportController: ExportController
    let importController: ImportController
    @Binding var showingNewNote: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.contentMode == .compiled {
                LibraryCompiledPane(model: model, draft: draft)
            } else {
                searchHeader
                Divider()
                noteTable
            }

            if let status = model.exportStatus ?? model.importStatus {
                Divider()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(status)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("View", selection: contentModeBinding) {
                    Text("List").tag(LibraryContentMode.list)
                    Text("Compiled").tag(LibraryContentMode.compiled)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Library view")

                LibraryExportMenu(model: model, exportController: exportController)

                Button {
                    Task { await importController.importJSON() }
                } label: {
                    Label("Import JSON", systemImage: "square.and.arrow.down")
                }
                .disabled(!model.isWritable)
                .accessibilityHint("Imports a Webby JSON export without changing the selected file.")

                Button {
                    draft.commit(to: model)
                    showingNewNote = true
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!model.isWritable)
                .accessibilityHint("Creates an Inbox or workspace note.")

                if let note = model.selectedNote {
                    if note.trashedAt != nil {
                        Button("Restore") {
                            draft.commit(to: model)
                            model.restore(id: note.id)
                        }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                        .disabled(!model.isWritable)
                    } else {
                        Button("Move to Trash") {
                            draft.commit(to: model)
                            model.trash(id: note.id)
                        }
                        .keyboardShortcut(.delete, modifiers: .command)
                        .disabled(!model.isWritable)
                    }
                }

                if model.selectedSection == .trash {
                    Button("Empty Trash", role: .destructive) {
                        draft.commit(to: model)
                        model.requestEmptyTrash()
                    }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(!model.isWritable || model.libraryResult.trash.isEmpty)
                }
            }
        }
        .alert(
            "Empty Trash?",
            isPresented: emptyTrashPresented
        ) {
            Button("Cancel", role: .cancel) {
                model.cancelEmptyTrash()
            }
            .keyboardShortcut(.cancelAction)
            Button(emptyTrashButtonTitle, role: .destructive) {
                draft.commit(to: model)
                model.confirmEmptyTrash()
            }
        } message: {
            Text("This permanently deletes \(trashCountText). You can't undo this.")
        }
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search notes", text: Binding(
                    get: { model.searchText },
                    set: { model.searchText = $0 }
                ))
                .textFieldStyle(.plain)
                .accessibilityLabel("Search notes")
                .accessibilityHint("Searches all Library sections with the existing query syntax.")

                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
                }
            }

            if !model.searchDiagnostics.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.searchDiagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            Text("\(diagnostic.token): \(diagnostic.message)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Search problems")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var noteTable: some View {
        Group {
            if model.visibleNotes.isEmpty {
                ContentUnavailableView {
                    Label(
                        model.searchText.isEmpty ? "No Notes Here" : "No Search Results",
                        systemImage: model.searchText.isEmpty ? "note.text" : "magnifyingglass"
                    )
                } description: {
                    Text(model.searchText.isEmpty
                        ? "Notes in this section appear here."
                        : "Try another search or clear the search field.")
                }
            } else {
                Table(model.visibleNotes, selection: noteSelection) {
                    TableColumn("Note") { item in
                        HStack(spacing: 8) {
                            Image(systemName: noteSymbol(item.note))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.note.summaryLine() ?? "Empty note")
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    if item.note.hidden {
                                        Text("Hidden")
                                    }
                                    if item.note.excludedFromAgent {
                                        Text("No AI")
                                    }
                                    if item.note.trashedAt != nil {
                                        Text("Trashed")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(accessibilityLabel(for: item.note))
                    }
                    .width(min: 220, ideal: 320)

                    TableColumn("Scope") { item in
                        Text(LibraryNotePresentation.scopeDescription(item.note.anchor))
                            .lineLimit(1)
                    }
                    .width(min: 150, ideal: 220)

                    TableColumn("Updated") { item in
                        LibraryNotePresentation.date(item.note.updatedAt)
                            .lineLimit(1)
                    }
                    .width(min: 130, ideal: 170)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var contentModeBinding: Binding<LibraryContentMode> {
        Binding(
            get: { model.contentMode },
            set: { mode in
                // Compiled output is a snapshot, so commit before switching to it.
                if mode == .compiled {
                    draft.commit(to: model)
                }
                model.contentMode = mode
            }
        )
    }

    private var noteSelection: Binding<Set<UUID>> {
        Binding(
            get: { model.selectedNoteIDs },
            set: { newValue in
                // Commit the current draft before the detail pane changes note.
                draft.commit(to: model)
                model.setSelection(newValue)
            }
        )
    }

    private var emptyTrashPresented: Binding<Bool> {
        Binding(
            get: { model.pendingEmptyTrash != nil },
            set: { isPresented in
                if !isPresented {
                    model.cancelEmptyTrash()
                }
            }
        )
    }

    private var trashCount: Int {
        model.pendingEmptyTrash?.count ?? model.libraryResult.trash.count
    }

    private var trashCountText: String {
        trashCount == 1 ? "1 note" : "\(trashCount) notes"
    }

    private var emptyTrashButtonTitle: String {
        trashCount == 1 ? "Delete 1 Note" : "Delete \(trashCount) Notes"
    }

    private func noteSymbol(_ note: Note) -> String {
        if note.trashedAt != nil { return "trash" }
        if note.pinnedAt != nil { return "pin" }
        if note.hidden { return "eye.slash" }
        return note.anchor == nil ? "tray" : "note.text"
    }

    private func accessibilityLabel(for note: Note) -> String {
        var parts = [note.summaryLine() ?? "Empty note"]
        parts.append(LibraryNotePresentation.scopeDescription(note.anchor))
        if note.pinnedAt != nil { parts.append("Pinned") }
        if note.hidden { parts.append("Hidden here") }
        if note.excludedFromAgent { parts.append("Kept away from AI") }
        if note.trashedAt != nil { parts.append("In Trash") }
        return parts.joined(separator: ", ")
    }
}


private struct LibraryCompiledPane: View {
    let model: LibraryModel
    let draft: LibraryTextDraft

    var body: some View {
        Group {
            if let document = model.compiledDocument(),
               !document.sections.isEmpty {
                CompiledView(
                    html: HTMLRenderer.render(document),
                    onOpenExternalURL: { url in
                        NSWorkspace.shared.open(url)
                    },
                    onOpenNote: { id in
                        draft.commit(to: model)
                        _ = model.revealNote(id)
                    }
                )
            } else {
                ContentUnavailableView(
                    "Nothing to Compile",
                    systemImage: "doc.richtext",
                    description: Text("Choose Inbox, a workspace or a page to compile its notes.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LibraryExportMenu: View {
    let model: LibraryModel
    let exportController: ExportController

    var body: some View {
        Menu {
            if let selection = model.workspaceExportSelection {
                Button("Workspace as Markdown...") {
                    exportController.run(selection: selection, format: .markdown)
                }
                Button("Workspace as HTML...") {
                    exportController.run(selection: selection, format: .html)
                }
                Button("Workspace as JSON...") {
                    exportController.run(selection: selection, format: .json)
                }
                Button("Workspace as JSON with Canonical Source URLs...") {
                    exportController.run(
                        selection: selection,
                        format: .json,
                        includeCanonicalSourceURLs: true
                    )
                }
            }

            if let selection = model.pageExportSelection {
                Divider()
                Button("Page as Markdown...") {
                    exportController.run(selection: selection, format: .markdown)
                }
                Button("Page as HTML...") {
                    exportController.run(selection: selection, format: .html)
                }
                Button("Page as JSON...") {
                    exportController.run(selection: selection, format: .json)
                }
            }

            if let selection = model.selectedNotesExportSelection {
                Divider()
                Button("Selected Notes as Markdown...") {
                    exportController.run(selection: selection, format: .markdown)
                }
                Button("Selected Notes as JSON...") {
                    exportController.run(selection: selection, format: .json)
                }
            }

            Divider()
            Button("All Notes as Markdown...") {
                exportController.run(selection: .all, format: .markdown)
            }
            Button("All Notes as JSON...") {
                exportController.run(selection: .all, format: .json)
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .accessibilityHint("Exports the current workspace, page, selected notes or all notes.")
    }
}
