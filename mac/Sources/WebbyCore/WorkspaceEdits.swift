import Foundation

/// A note whose workspace override changes as part of a workspace edit.
public struct WorkspaceOverrideChange: Equatable, Sendable {
    public let noteID: UUID
    public let workspace: UUID?

    public init(noteID: UUID, workspace: UUID?) {
        self.noteID = noteID
        self.workspace = workspace
    }
}

/// The result of one workspace operation: the full new record list plus the notes
/// that must be repointed. `NoteStore.apply(_:)` commits both in one generation.
public struct WorkspaceEdit: Equatable, Sendable {
    public let records: [WorkspaceRecord]
    public let overrideChanges: [WorkspaceOverrideChange]
    /// Where a selection on the edited workspace should move to.
    public let destination: WorkspaceDestination

    public init(
        records: [WorkspaceRecord],
        overrideChanges: [WorkspaceOverrideChange] = [],
        destination: WorkspaceDestination
    ) {
        self.records = records
        self.overrideChanges = overrideChanges
        self.destination = destination
    }
}

public enum WorkspaceEditError: Error, Equatable, Sendable {
    /// The inbox is not a workspace and cannot be edited, merged or split.
    case inboxNotEditable
    case unknownRecord(UUID)
    case mergeIntoSelf
    case keyNotInRecord
    /// A record must keep at least one key; merge it elsewhere or leave it.
    case cannotSplitLastKey
}

/// Pure workspace operations. Implicit workspaces become records only when an
/// operation needs one; nothing here does I/O.
public enum WorkspaceEdits {
    /// A blank or whitespace-only title restores the default name.
    public static func rename(
        _ destination: WorkspaceDestination,
        to title: String,
        in records: [WorkspaceRecord],
        now: Date = Date()
    ) throws -> WorkspaceEdit {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return try update(destination, in: records, now: now) {
            $0.title = trimmed.isEmpty ? nil : trimmed
        }
    }

    public static func setPinned(
        _ destination: WorkspaceDestination,
        _ pinned: Bool,
        in records: [WorkspaceRecord],
        now: Date = Date()
    ) throws -> WorkspaceEdit {
        try update(destination, in: records, now: now) { $0.pinned = pinned }
    }

    /// The target keeps its title, pin and skin and gains the source's keys. The
    /// source record is removed and notes overriding to it move to the target.
    public static func merge(
        _ source: WorkspaceDestination,
        into target: WorkspaceDestination,
        records: [WorkspaceRecord],
        notes: [Note],
        now: Date = Date()
    ) throws -> WorkspaceEdit {
        guard source != target else { throw WorkspaceEditError.mergeIntoSelf }
        var result = records
        let sourceKeys: [WorkspaceKey]
        var sourceID: UUID?
        switch source {
        case .inbox:
            throw WorkspaceEditError.inboxNotEditable
        case .implicit(let key):
            sourceKeys = [key]
        case .record(let id):
            guard let record = records.first(where: { $0.id == id }) else {
                throw WorkspaceEditError.unknownRecord(id)
            }
            sourceKeys = record.keys
            sourceID = id
        }

        let targetID: UUID
        switch target {
        case .inbox:
            throw WorkspaceEditError.inboxNotEditable
        case .implicit(let key):
            let record = WorkspaceRecord(keys: [key], createdAt: now)
            result.append(record)
            targetID = record.id
        case .record(let id):
            guard records.contains(where: { $0.id == id }) else {
                throw WorkspaceEditError.unknownRecord(id)
            }
            targetID = id
        }
        // The source may be the same record as the target only if destinations were
        // equal, which is rejected above; two records can never share a key.
        if let sourceID, sourceID == targetID { throw WorkspaceEditError.mergeIntoSelf }

        let targetIndex = result.firstIndex { $0.id == targetID }!
        result[targetIndex].keys.append(contentsOf: sourceKeys)
        var changes: [WorkspaceOverrideChange] = []
        if let sourceID {
            result.removeAll { $0.id == sourceID }
            changes = notes.filter { $0.workspaceOverride == sourceID }
                .map { WorkspaceOverrideChange(noteID: $0.id, workspace: targetID) }
        }
        return WorkspaceEdit(records: result, overrideChanges: changes, destination: .record(targetID))
    }

    /// Moves one key out of a record; it returns to its implicit workspace. A
    /// record's last key cannot be split out. Notes that override to the record stay
    /// in it, because the override is an explicit choice.
    public static func split(
        _ key: WorkspaceKey,
        from recordID: UUID,
        in records: [WorkspaceRecord]
    ) throws -> WorkspaceEdit {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else {
            throw WorkspaceEditError.unknownRecord(recordID)
        }
        guard records[index].keys.contains(key) else { throw WorkspaceEditError.keyNotInRecord }
        guard records[index].keys.count > 1 else { throw WorkspaceEditError.cannotSplitLastKey }
        var result = records
        result[index].keys.removeAll { $0 == key }
        return WorkspaceEdit(records: result, destination: .record(recordID))
    }

    private static func update(
        _ destination: WorkspaceDestination,
        in records: [WorkspaceRecord],
        now: Date,
        _ change: (inout WorkspaceRecord) -> Void
    ) throws -> WorkspaceEdit {
        var result = records
        let id: UUID
        switch destination {
        case .inbox:
            throw WorkspaceEditError.inboxNotEditable
        case .implicit(let key):
            var record = WorkspaceRecord(keys: [key], createdAt: now)
            change(&record)
            result.append(record)
            id = record.id
        case .record(let recordID):
            guard let index = result.firstIndex(where: { $0.id == recordID }) else {
                throw WorkspaceEditError.unknownRecord(recordID)
            }
            change(&result[index])
            id = recordID
        }
        return WorkspaceEdit(records: result, destination: .record(id))
    }
}
