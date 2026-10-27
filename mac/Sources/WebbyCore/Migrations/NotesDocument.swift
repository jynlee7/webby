import Foundation

enum NotesDocumentError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case versionMismatch(expected: Int, found: Int)
    case emptyWorkspaceKeys(workspaceID: UUID)
    case duplicateWorkspaceID(UUID)
    case duplicateWorkspaceKey(WorkspaceKey)
}

/// The version 2 notes file: notes plus workspace records.
///
/// The frozen version 1 tree is decoded only by `decode(_:version:)` and mapped
/// to live model values. Encoding always writes a version 2 root and never
/// includes ephemeral notes.
struct NotesDocument: Codable, Sendable {
    static let currentVersion = 2

    var notes: [Note]
    var workspaces: [WorkspaceRecord]

    init(notes: [Note] = [], workspaces: [WorkspaceRecord] = []) {
        self.notes = notes
        self.workspaces = workspaces
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case notes
        case workspaces
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw NotesDocumentError.unsupportedVersion(version)
        }
        notes = try container.decode([Note].self, forKey: .notes)
        workspaces = try container.decode([WorkspaceRecord].self, forKey: .workspaces)
        try Self.validateWorkspaces(workspaces)
    }

    func encode(to encoder: Encoder) throws {
        try Self.validateWorkspaces(workspaces)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(notes.filter { !$0.ephemeral }, forKey: .notes)
        try container.encode(workspaces, forKey: .workspaces)
    }

    static func decode(_ data: Data, version: Int) throws -> NotesDocument {
        let decoder = makeDecoder()

        switch version {
        case 1:
            let file = try decoder.decode(NotesFileV1.self, from: data)
            guard file.version == version else {
                throw NotesDocumentError.versionMismatch(expected: version, found: file.version)
            }
            return migrate(file)
        case 2:
            return try decoder.decode(NotesDocument.self, from: data)
        default:
            throw NotesDocumentError.unsupportedVersion(version)
        }
    }

    static func encode(_ document: NotesDocument, version: Int) throws -> Data {
        guard version == currentVersion else {
            throw NotesDocumentError.unsupportedVersion(version)
        }
        try validateWorkspaces(document.workspaces)
        return try makeEncoder().encode(document)
    }

    static func validateWorkspaces(_ records: [WorkspaceRecord]) throws {
        var seenIDs = Set<UUID>()
        var seenKeys = Set<WorkspaceKey>()
        for record in records {
            guard seenIDs.insert(record.id).inserted else {
                throw NotesDocumentError.duplicateWorkspaceID(record.id)
            }
            guard !record.keys.isEmpty else {
                throw NotesDocumentError.emptyWorkspaceKeys(workspaceID: record.id)
            }
            for key in record.keys {
                guard seenKeys.insert(key).inserted else {
                    throw NotesDocumentError.duplicateWorkspaceKey(key)
                }
            }
        }
    }

    private static func migrate(_ file: NotesFileV1) -> NotesDocument {
        let notes = file.notes.map { old in
            Note(
                id: old.id,
                anchor: liveAnchor(old.anchor),
                tab: nil,
                workspaceOverride: nil,
                text: old.text,
                revision: 1,
                source: nil,
                frame: NoteFrame(
                    x: old.frame.x,
                    y: old.frame.y,
                    width: old.frame.width,
                    height: old.frame.height
                ),
                placement: livePlacement(old.placement),
                collapsed: old.collapsed,
                hidden: false,
                pinnedAt: nil,
                trashedAt: nil,
                excludedFromAgent: false,
                appearance: nil,
                createdAt: old.createdAt,
                updatedAt: old.updatedAt,
                ephemeral: false
            )
        }
        return NotesDocument(notes: notes, workspaces: [])
    }

    private static func liveAnchor(_ anchor: AnchorV1) -> Anchor {
        switch anchor {
        case .app(let bundleID):
            return .app(bundleID: bundleID)
        case .web(let page, let scope):
            return .web(
                page: PageURL(host: page.host, path: page.path, query: nil),
                scope: liveScope(scope)
            )
        }
    }

    private static func liveScope(_ scope: WebScopeV1) -> WebScope {
        switch scope {
        case .page:
            return .page
        case .prefix(let path):
            return .prefix(path: path)
        case .site:
            return .site
        }
    }

    private static func livePlacement(_ placement: PlacementV1) -> Placement {
        switch placement {
        case .window:
            return .window
        case .screen:
            return .screen
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }
}
