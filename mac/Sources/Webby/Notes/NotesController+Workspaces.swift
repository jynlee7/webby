import Foundation
import WebbyCore

extension NotesController {
    @discardableResult
    func renameWorkspace(_ destination: WorkspaceDestination, to title: String) -> WorkspaceDestination? {
        return applyWorkspaceEdit { records, _, date in
            try WorkspaceEdits.rename(destination, to: title, in: records, now: date)
        }
    }

    @discardableResult
    func setWorkspacePinned(_ destination: WorkspaceDestination, pinned: Bool) -> WorkspaceDestination? {
        return applyWorkspaceEdit { records, _, date in
            try WorkspaceEdits.setPinned(destination, pinned, in: records, now: date)
        }
    }

    @discardableResult
    func mergeWorkspace(
        _ source: WorkspaceDestination,
        into target: WorkspaceDestination
    ) -> WorkspaceDestination? {
        return applyWorkspaceEdit { records, notes, date in
            try WorkspaceEdits.merge(source, into: target, records: records, notes: notes, now: date)
        }
    }

    @discardableResult
    func splitWorkspace(key: WorkspaceKey, from recordID: UUID) -> WorkspaceDestination? {
        applyWorkspaceEdit { records, _, date in
            try WorkspaceEdits.split(key, from: recordID, in: records)
        }
    }
}
