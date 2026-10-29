import SwiftUI
import WebbyCore

struct LibraryView: View {
    let model: LibraryModel
    let actions: LibraryAnchorActions
    let draft: LibraryTextDraft

    @State private var showingNewNote = false

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView(model: model, draft: draft)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            LibraryContentView(
                model: model,
                actions: actions,
                draft: draft,
                showingNewNote: $showingNewNote
            )
            .navigationSplitViewColumnWidth(min: 340, ideal: 460, max: 680)
        } detail: {
            LibraryDetailView(model: model, actions: actions, draft: draft)
        }
        .sheet(isPresented: $showingNewNote) {
            LibraryNewNoteSheet(model: model, draft: draft)
        }
        .frame(minWidth: 860, minHeight: 520)
        .onAppear {
            draft.load(note: model.selectedNote)
        }
        .onChange(of: model.selectedNoteID) { _, _ in
            // A programmatic selection such as #15's showNote must commit first too.
            draft.commit(to: model)
            draft.load(note: model.selectedNote)
        }
        .onChange(of: model.selectedNote) { _, note in
            guard let note, draft.noteID == note.id, !draft.isDirty else { return }
            draft.load(note: note)
        }
    }
}
