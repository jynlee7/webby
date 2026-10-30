import Foundation
import WebbyCore

extension LibraryModel {
    func rename(_ group: LibraryWorkspaceGroup, to title: String) {
        let wasSelected = selectedWorkspace == group.destination
        let result = notesController.renameWorkspace(group.destination, to: title)
        keepSelected(wasSelected, at: result)
    }

    func setPinned(_ group: LibraryWorkspaceGroup, pinned: Bool) {
        let wasSelected = selectedWorkspace == group.destination
        let result = notesController.setWorkspacePinned(group.destination, pinned: pinned)
        keepSelected(wasSelected, at: result)
    }

    func merge(_ group: LibraryWorkspaceGroup, into target: LibraryWorkspaceGroup) {
        // The controller notifies observers before returning, and a removed source clears the selection.
        let wasSelected = selectedWorkspace == group.destination || selectedWorkspace == target.destination
        let result = notesController.mergeWorkspace(group.destination, into: target.destination)
        keepSelected(wasSelected, at: result)
    }

    func split(_ key: WorkspaceKey, from group: LibraryWorkspaceGroup) {
        guard case .record(let id) = group.destination else { return }
        notesController.splitWorkspace(key: key, from: id)
    }

    /// An implicit workspace becomes a record when edited; keep it selected.
    private func keepSelected(_ wasSelected: Bool, at destination: WorkspaceDestination?) {
        guard wasSelected, let destination else { return }
        select(workspace: destination)
    }
}
