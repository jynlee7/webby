import Foundation

/// Options for a JSON export.
///
/// The default selection is every durable note. Ephemeral notes are never
/// exported, regardless of the selection.
public struct ExportJSONOptions: Equatable, Sendable {
    public enum Selection: Equatable, Sendable {
        /// Every durable note.
        case all
        /// Notes whose workspace resolves to this destination.
        case workspace(WorkspaceDestination)
        /// Exactly these note IDs. Missing and ephemeral IDs are ignored.
        case notes(Set<UUID>)
    }

    /// When false, `source.url` is omitted and `tab.lastURL` is cleared.
    /// When true, both are replaced by a reconstructed canonical HTTPS URL.
    public var includeCanonicalSourceURLs: Bool
    public var selection: Selection

    public init(
        includeCanonicalSourceURLs: Bool = false,
        selection: Selection = .all
    ) {
        self.includeCanonicalSourceURLs = includeCanonicalSourceURLs
        self.selection = selection
    }
}

/// Deterministic, privacy-preserving JSON export in the version 2 notes schema.
///
/// Encoding is a pure function of the input values. It never generates a random
/// UUID or a new date, and never reads or writes a file.
public enum ExportJSON {
    public static func encode(
        notes: [Note],
        workspaces: [WorkspaceRecord],
        options: ExportJSONOptions = ExportJSONOptions(),
        queryRules: [QueryRule] = QueryRules.builtIns
    ) throws -> Data {
        let document = try makeDocument(
            notes: notes,
            workspaces: workspaces,
            options: options,
            queryRules: queryRules
        )
        return try NotesDocument.encode(document, version: NotesDocument.currentVersion)
    }

    static func makeDocument(
        notes: [Note],
        workspaces: [WorkspaceRecord],
        options: ExportJSONOptions = ExportJSONOptions(),
        queryRules: [QueryRule] = QueryRules.builtIns
    ) throws -> NotesDocument {
        let selected = selectedNotes(notes, options: options, workspaces: workspaces)
            .filter { !$0.ephemeral }
            .sorted(by: noteOrder)

        let rules = QueryRules.effective(
            rules: queryRules,
            anchors: selected.compactMap(\.anchor)
        )

        let destinations = selected.map { note in
            WorkspaceResolver.resolve(note, workspaces: workspaces)
        }

        var includedRecords: [UUID: WorkspaceRecord] = [:]
        switch options.selection {
        case .all:
            for record in workspaces {
                includedRecords[record.id] = record
            }
        case .workspace(.record(let id)):
            if let record = workspaces.first(where: { $0.id == id }) {
                includedRecords[id] = record
            }
        case .workspace(.implicit(_)), .workspace(.inbox), .notes:
            break
        }

        for destination in destinations {
            guard case .record(let id) = destination,
                  let record = workspaces.first(where: { $0.id == id })
            else { continue }
            includedRecords[id] = record
        }

        // A note without an anchor loses its derived workspace key when its tab
        // binding and source URL are removed. Give it an export-local record so
        // membership survives the round trip.
        var localKeys = Set<WorkspaceKey>()
        for (note, destination) in zip(selected, destinations) {
            if case .implicit(let key) = destination, note.anchor == nil {
                localKeys.insert(key)
            }
        }

        var usedWorkspaceIDs = Set(workspaces.map(\.id))
        usedWorkspaceIDs.formUnion(includedRecords.keys)
        var localRecordsByKey: [WorkspaceKey: WorkspaceRecord] = [:]
        for key in localKeys.sorted(by: keyOrder) {
            let createdAt = selected
                .filter { note in
                    guard case .implicit(let destinationKey) = WorkspaceResolver.resolve(
                        note,
                        workspaces: workspaces
                    ) else { return false }
                    return note.anchor == nil && destinationKey == key
                }
                .map(\.createdAt)
                .min() ?? Date(timeIntervalSinceReferenceDate: 0)

            let id = deriveUUID(for: key, used: &usedWorkspaceIDs)
            localRecordsByKey[key] = WorkspaceRecord(
                id: id,
                title: nil,
                keys: [key],
                pinned: false,
                skinID: nil,
                createdAt: createdAt
            )
        }

        let exportedNotes = zip(selected, destinations).map { note, destination in
            sanitized(
                note,
                destination: destination,
                localRecordsByKey: localRecordsByKey,
                includeCanonicalSourceURLs: options.includeCanonicalSourceURLs,
                queryRules: rules
            )
        }

        var exportedRecords = includedRecords.values.map { record in
            WorkspaceRecord(
                id: record.id,
                title: record.title,
                keys: WorkspaceKeyOrdering.sorted(record.keys),
                pinned: record.pinned,
                skinID: record.skinID,
                createdAt: record.createdAt
            )
        }
        exportedRecords.append(contentsOf: localRecordsByKey.values)
        exportedRecords.sort(by: recordOrder)

        return NotesDocument(
            notes: exportedNotes.sorted(by: noteOrder),
            workspaces: exportedRecords
        )
    }

    private static func selectedNotes(
        _ notes: [Note],
        options: ExportJSONOptions,
        workspaces: [WorkspaceRecord]
    ) -> [Note] {
        switch options.selection {
        case .all:
            return notes
        case .workspace(let destination):
            return notes.filter {
                WorkspaceResolver.resolve($0, workspaces: workspaces) == destination
            }
        case .notes(let ids):
            return notes.filter { ids.contains($0.id) }
        }
    }

    private static func sanitized(
        _ note: Note,
        destination: WorkspaceDestination,
        localRecordsByKey: [WorkspaceKey: WorkspaceRecord],
        includeCanonicalSourceURLs: Bool,
        queryRules: [QueryRule]
    ) -> Note {
        let canonicalURL = canonicalURL(
            for: note,
            include: includeCanonicalSourceURLs,
            queryRules: queryRules
        )

        let source: NoteSource?
        if let existing = note.source {
            let title = existing.title
            if existing.url != nil, let canonicalURL {
                source = NoteSource(url: canonicalURL, title: title)
            } else if let title {
                source = NoteSource(url: nil, title: title)
            } else {
                source = nil
            }
        } else {
            source = nil
        }

        let tab = note.tab.map { binding -> TabBinding in
            var copy = binding
            copy.lastURL = canonicalURL ?? ""
            return copy
        }

        let workspaceOverride: UUID?
        switch destination {
        case .record(let id):
            workspaceOverride = id
        case .implicit(let key):
            workspaceOverride = note.anchor == nil
                ? localRecordsByKey[key]?.id
                : nil
        case .inbox:
            workspaceOverride = nil
        }

        return Note(
            id: note.id,
            anchor: note.anchor,
            tab: tab,
            workspaceOverride: workspaceOverride,
            text: note.text,
            revision: note.revision,
            source: source,
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
    }

    private static func canonicalURL(
        for note: Note,
        include: Bool,
        queryRules: [QueryRule]
    ) -> String? {
        guard include else { return nil }

        let page: PageURL?
        if let rawURL = note.source?.url {
            page = PageURL(string: rawURL, queryRules: queryRules)
        } else if let rawURL = note.tab?.lastURL {
            page = PageURL(string: rawURL, queryRules: queryRules)
        } else if case .web(let anchorPage, _) = note.anchor {
            page = anchorPage
        } else {
            page = nil
        }

        guard let page else { return nil }
        return CanonicalExportURL.make(for: page, queryRules: queryRules)
    }

    private static func noteOrder(_ lhs: Note, _ rhs: Note) -> Bool {
        lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }

    private static func recordOrder(_ lhs: WorkspaceRecord, _ rhs: WorkspaceRecord) -> Bool {
        lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }

    private static func keyOrder(_ lhs: WorkspaceKey, _ rhs: WorkspaceKey) -> Bool {
        WorkspaceKeyOrdering.identifier(lhs) < WorkspaceKeyOrdering.identifier(rhs)
    }

    /// A stable, non-random UUID derived from the workspace key. Existing IDs are
    /// skipped, so two calls with the same inputs produce the same value.
    private static func deriveUUID(for key: WorkspaceKey, used: inout Set<UUID>) -> UUID {
        let base = WorkspaceKeyOrdering.identifier(key)
        var attempt = 0
        while true {
            let token = attempt == 0 ? base : "\(base)#\(attempt)"
            let candidate = hashUUID(token)
            if used.insert(candidate).inserted {
                return candidate
            }
            attempt += 1
        }
    }

    private static func hashUUID(_ token: String) -> UUID {
        var first: UInt64 = 14_695_981_039_346_656_037
        var second: UInt64 = 10_995_116_282_111
        for byte in token.utf8 {
            first = (first ^ UInt64(byte)) &* 1_099_511_628_211
            second = (second &+ UInt64(byte)) &* 1_099_511_628_211
        }

        let bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
            UInt8((first >> 56) & 0xff),
            UInt8((first >> 48) & 0xff),
            UInt8((first >> 40) & 0xff),
            UInt8((first >> 32) & 0xff),
            UInt8((first >> 24) & 0xff),
            UInt8((first >> 16) & 0xff),
            (UInt8((first >> 8) & 0x0f) | 0x80),
            UInt8(first & 0xff),
            (UInt8((second >> 56) & 0x3f) | 0x80),
            UInt8((second >> 48) & 0xff),
            UInt8((second >> 40) & 0xff),
            UInt8((second >> 32) & 0xff),
            UInt8((second >> 24) & 0xff),
            UInt8((second >> 16) & 0xff),
            UInt8((second >> 8) & 0xff),
            UInt8(second & 0xff)
        )
        return UUID(uuid: bytes)
    }
}

enum WorkspaceKeyOrdering {
    static func identifier(_ key: WorkspaceKey) -> String {
        switch key {
        case .host(let name):
            return "host:\(name)"
        case .app(let bundleID):
            return "app:\(bundleID)"
        case .localFiles:
            return "localFiles"
        case .tabsWithoutPage:
            return "tabsWithoutPage"
        }
    }

    static func sorted(_ keys: [WorkspaceKey]) -> [WorkspaceKey] {
        keys.sorted { identifier($0) < identifier($1) }
    }
}
