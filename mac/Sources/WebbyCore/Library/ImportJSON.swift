import Foundation

public enum ImportJSONError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case malformedRoot
    case duplicateImportedWorkspaceID(UUID)
    case emptyImportedWorkspaceKeys(UUID)
    case duplicateImportedWorkspaceKey(WorkspaceKey)
    case ambiguousWorkspaceKeys([WorkspaceKey])
    case idAllocationFailed
}

/// A decoded import document. Decoding is side-effect-free: it does not use the
/// persisted-file loader, recovery, backups or the destination file.
public struct ImportPayload: Equatable, Sendable {
    public let notes: [Note]
    public let workspaces: [WorkspaceRecord]

    public init(notes: [Note], workspaces: [WorkspaceRecord]) {
        self.notes = notes
        self.workspaces = workspaces
    }
}

/// A fully validated, non-mutating import plan.
public struct ImportPlan: Equatable, Sendable {
    public struct Summary: Equatable, Sendable {
        public let notesAdded: Int
        public let workspacesAdded: Int
        public let workspacesUpdated: Int

        public init(notesAdded: Int, workspacesAdded: Int, workspacesUpdated: Int) {
            self.notesAdded = notesAdded
            self.workspacesAdded = workspacesAdded
            self.workspacesUpdated = workspacesUpdated
        }

        public var reason: String {
            var parts: [String] = []
            if notesAdded > 0 {
                parts.append("\(notesAdded) note\(notesAdded == 1 ? "" : "s")")
            }
            if workspacesAdded > 0 {
                parts.append("\(workspacesAdded) workspace\(workspacesAdded == 1 ? "" : "s")")
            }
            if workspacesUpdated > 0 {
                parts.append(
                    "\(workspacesUpdated) existing workspace\(workspacesUpdated == 1 ? "" : "s") updated"
                )
            }
            return parts.isEmpty ? "Nothing to import" : parts.joined(separator: ", ")
        }
    }

    public let notesToAdd: [Note]
    public let workspacesToAdd: [WorkspaceRecord]
    /// Existing records that gain imported keys. Apply these instead of replacing
    /// the whole workspace list.
    public let workspaceUpdates: [WorkspaceRecord]

    public init(
        notesToAdd: [Note],
        workspacesToAdd: [WorkspaceRecord],
        workspaceUpdates: [WorkspaceRecord]
    ) {
        self.notesToAdd = notesToAdd
        self.workspacesToAdd = workspacesToAdd
        self.workspaceUpdates = workspaceUpdates
    }

    public var summary: Summary {
        Summary(
            notesAdded: notesToAdd.count,
            workspacesAdded: workspacesToAdd.count,
            workspacesUpdated: workspaceUpdates.count
        )
    }
}

/// Side-effect-free JSON import decoding and merge planning.
public enum ImportJSON {
    private struct VersionProbe: Decodable {
        let version: Int
    }

    /// Decode a v1 or v2 export through the frozen `NotesDocument` migration path.
    public static func decode(_ data: Data) throws -> ImportPayload {
        let probe: VersionProbe
        do {
            probe = try JSONDecoder().decode(VersionProbe.self, from: data)
        } catch {
            throw ImportJSONError.malformedRoot
        }

        switch probe.version {
        case 1, 2:
            break
        default:
            throw ImportJSONError.unsupportedVersion(probe.version)
        }

        let document = try NotesDocument.decode(data, version: probe.version)
        return ImportPayload(notes: document.notes, workspaces: document.workspaces)
    }

    /// Validate the complete merge before anything is mutated.
    ///
    /// Existing notes are never changed or overwritten. An imported note keeps
    /// its ID unless it clashes with an existing note or an earlier imported note;
    /// in that case `makeID` supplies a fresh ID.
    public static func plan(
        _ payload: ImportPayload,
        against notes: [Note],
        workspaces: [WorkspaceRecord],
        makeID: () -> UUID = { UUID() }
    ) throws -> ImportPlan {
        var keyOwner: [WorkspaceKey: [UUID]] = [:]
        for record in workspaces {
            for key in record.keys {
                keyOwner[key, default: []].append(record.id)
            }
        }

        var importedWorkspaceIDs = Set<UUID>()
        var importedKeys = Set<WorkspaceKey>()
        for record in payload.workspaces {
            guard importedWorkspaceIDs.insert(record.id).inserted else {
                throw ImportJSONError.duplicateImportedWorkspaceID(record.id)
            }
            guard !record.keys.isEmpty else {
                throw ImportJSONError.emptyImportedWorkspaceKeys(record.id)
            }
            for key in record.keys {
                guard importedKeys.insert(key).inserted else {
                    throw ImportJSONError.duplicateImportedWorkspaceKey(key)
                }
            }
        }

        let recordByID = Dictionary(
            workspaces.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var usedWorkspaceIDs = Set(workspaces.map(\.id))
        var workspaceIDMap: [UUID: UUID] = [:]
        var additions: [WorkspaceRecord] = []
        var updates: [UUID: WorkspaceRecord] = [:]

        for record in payload.workspaces.sorted(by: recordOrder) {
            var owners = Set<UUID>()
            var ambiguousKeys: [WorkspaceKey] = []

            for key in record.keys {
                let ids = keyOwner[key] ?? []
                if ids.count > 1 {
                    ambiguousKeys.append(key)
                } else if let id = ids.first {
                    owners.insert(id)
                }
            }

            if !ambiguousKeys.isEmpty {
                throw ImportJSONError.ambiguousWorkspaceKeys(
                    WorkspaceKeyOrdering.sorted(ambiguousKeys)
                )
            }
            if owners.count > 1 {
                throw ImportJSONError.ambiguousWorkspaceKeys(
                    WorkspaceKeyOrdering.sorted(record.keys)
                )
            }

            if let owner = owners.first {
                guard var existing = updates[owner] ?? recordByID[owner] else {
                    throw ImportJSONError.ambiguousWorkspaceKeys(
                        WorkspaceKeyOrdering.sorted(record.keys)
                    )
                }

                var keys = existing.keys
                for key in record.keys where !keys.contains(key) {
                    keys.append(key)
                }
                existing.keys = WorkspaceKeyOrdering.sorted(keys)
                updates[owner] = existing
                workspaceIDMap[record.id] = owner
            } else {
                let newID = try allocateID(used: &usedWorkspaceIDs, makeID: makeID)
                additions.append(
                    WorkspaceRecord(
                        id: newID,
                        title: record.title,
                        keys: WorkspaceKeyOrdering.sorted(record.keys),
                        pinned: record.pinned,
                        skinID: record.skinID,
                        createdAt: record.createdAt
                    )
                )
                workspaceIDMap[record.id] = newID
            }
        }

        var usedNoteIDs = Set(notes.map(\.id))
        var plannedNotes: [Note] = []

        for note in payload.notes.sorted(by: noteOrder) {
            let id: UUID
            if usedNoteIDs.contains(note.id) {
                id = try allocateID(used: &usedNoteIDs, makeID: makeID)
            } else {
                id = note.id
                usedNoteIDs.insert(id)
            }

            let workspaceOverride = note.workspaceOverride.flatMap { workspaceIDMap[$0] }
            plannedNotes.append(
                Note(
                    id: id,
                    anchor: note.anchor,
                    tab: nil,
                    workspaceOverride: workspaceOverride,
                    text: note.text,
                    revision: note.revision,
                    source: note.source,
                    frame: note.frame,
                    placement: note.placement,
                    collapsed: note.collapsed,
                    hidden: note.hidden,
                    pinnedAt: note.pinnedAt,
                    trashedAt: note.trashedAt,
                    excludedFromAgent: note.excludedFromAgent,
                    appearance: note.appearance,
                    createdAt: note.createdAt,
                    updatedAt: note.updatedAt,
                    ephemeral: false
                )
            )
        }

        plannedNotes.sort(by: noteOrder)
        additions.sort(by: recordOrder)

        return ImportPlan(
            notesToAdd: plannedNotes,
            workspacesToAdd: additions,
            workspaceUpdates: updates.values.sorted(by: recordOrder)
        )
    }

    private static func allocateID(used: inout Set<UUID>, makeID: () -> UUID) throws -> UUID {
        for _ in 0..<1_024 {
            let candidate = makeID()
            if used.insert(candidate).inserted {
                return candidate
            }
        }
        throw ImportJSONError.idAllocationFailed
    }

    private static func noteOrder(_ lhs: Note, _ rhs: Note) -> Bool {
        lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }

    private static func recordOrder(_ lhs: WorkspaceRecord, _ rhs: WorkspaceRecord) -> Bool {
        lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }
}
