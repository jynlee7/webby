import SwiftUI
import WebbyCore

private enum NewNoteDestination: Hashable {
    case inbox
    case workspace(WorkspaceKey)
    case record(UUID)

    var libraryDestination: LibraryDestination {
        switch self {
        case .inbox:
            return .inbox
        case let .workspace(key):
            return .workspace(key)
        case let .record(id):
            return .record(id)
        }
    }

    static func from(_ destination: WorkspaceDestination) -> NewNoteDestination {
        switch destination {
        case .inbox:
            return .inbox
        case let .implicit(key):
            return .workspace(key)
        case let .record(id):
            return .record(id)
        }
    }
}

struct LibraryNewNoteSheet: View {
    let model: LibraryModel
    let draft: LibraryTextDraft

    @Environment(\.dismiss) private var dismiss
    @State private var destination: NewNoteDestination = .inbox

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Note")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Text("Create an anchorless note in the Inbox or a workspace.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("Place", selection: $destination) {
                Text("Inbox").tag(NewNoteDestination.inbox)
                ForEach(model.libraryResult.workspaces, id: \.destination) { group in
                    Text(model.displayName(for: group))
                        .tag(NewNoteDestination.from(group.destination))
                }
            }
            .accessibilityLabel("Note destination")

            if !model.isWritable {
                Label(
                    model.readOnlyProblem ?? "Notes are read-only.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isWritable)
            }
        }
        .padding(20)
        .frame(width: 430)
    }

    private func create() {
        draft.commit(to: model)
        guard let id = model.createNote(destination: destination.libraryDestination) else { return }
        _ = model.selectNote(id)
        dismiss()
    }
}
