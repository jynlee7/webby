import Foundation
import WebbyCore

extension LibraryModel {
    func rename(_ group: LibraryWorkspaceGroup, to title: String) {
        moveSelection(from: group.destination, to: notesController.renameWorkspace(group.destination, to: title))
    }

    func setPinned(_ group: LibraryWorkspaceGroup, pinned: Bool) {
        moveSelection(
            from: group.destination,
            to: notesController.setWorkspacePinned(group.destination, pinned: pinned)
        )
    }

    func merge(_ group: LibraryWorkspaceGroup, into target: LibraryWorkspaceGroup) {
        let result = notesController.mergeWorkspace(group.destination, into: target.destination)
        if selectedWorkspace == group.destination || selectedWorkspace == target.destination {
            if let result { select(workspace: result) }
        }
    }

    func split(_ key: WorkspaceKey, from group: LibraryWorkspaceGroup) {
        guard case .record(let id) = group.destination else { return }
        notesController.splitWorkspace(key: key, from: id)
    }

    /// An implicit workspace becomes a record when edited; keep it selected.
    private func moveSelection(from old: WorkspaceDestination, to new: WorkspaceDestination?) {
        guard let new, new != old, selectedWorkspace == old else { return }
        select(workspace: new)
    }
}
