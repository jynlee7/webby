import Foundation
import WebbyCore

extension AgentScope: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let scope = AgentScope(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown agent scope: \(value)"
            )
        }
        self = scope
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension ClaudeUsage: Codable {
    private enum CodingKeys: String, CodingKey {
        case inputTokens
        case outputTokens
        case cacheCreationInputTokens
        case cacheReadInputTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            inputTokens: try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0,
            outputTokens: try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0,
            cacheCreationInputTokens: try container.decodeIfPresent(
                Int.self,
                forKey: .cacheCreationInputTokens
            ) ?? 0,
            cacheReadInputTokens: try container.decodeIfPresent(
                Int.self,
                forKey: .cacheReadInputTokens
            ) ?? 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inputTokens, forKey: .inputTokens)
        try container.encode(outputTokens, forKey: .outputTokens)
        try container.encode(cacheCreationInputTokens, forKey: .cacheCreationInputTokens)
        try container.encode(cacheReadInputTokens, forKey: .cacheReadInputTokens)
    }
}

extension ContextManifest.Status: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let status = ContextManifest.Status(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown manifest status: \(value)"
            )
        }
        self = status
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension ContextManifest.Entry: Codable {
    private enum CodingKeys: String, CodingKey {
        case alias
        case noteID
        case status
        case revision
        case page
        case updated
        case summary
        case omittedCharacters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            alias: try container.decode(String.self, forKey: .alias),
            noteID: try container.decode(UUID.self, forKey: .noteID),
            status: try container.decode(ContextManifest.Status.self, forKey: .status),
            revision: try container.decode(Int.self, forKey: .revision),
            page: try container.decode(String.self, forKey: .page),
            updated: try container.decode(String.self, forKey: .updated),
            summary: try container.decode(String.self, forKey: .summary),
            omittedCharacters: try container.decodeIfPresent(Int.self, forKey: .omittedCharacters) ?? 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(alias, forKey: .alias)
        try container.encode(noteID, forKey: .noteID)
        try container.encode(status, forKey: .status)
        try container.encode(revision, forKey: .revision)
        try container.encode(page, forKey: .page)
        try container.encode(updated, forKey: .updated)
        try container.encode(summary, forKey: .summary)
        try container.encode(omittedCharacters, forKey: .omittedCharacters)
    }
}

extension ContextManifest.ScreenStatus: Codable {
    private enum CodingKeys: String, CodingKey {
        case captured
        case label
        case capturedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            captured: try container.decodeIfPresent(Bool.self, forKey: .captured) ?? false,
            label: try container.decodeIfPresent(String.self, forKey: .label),
            capturedAt: try container.decodeIfPresent(String.self, forKey: .capturedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(captured, forKey: .captured)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(capturedAt, forKey: .capturedAt)
    }
}

extension ContextManifest: Codable {
    private enum CodingKeys: String, CodingKey {
        case entries
        case omittedLines
        case screen
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            entries: try container.decode([ContextManifest.Entry].self, forKey: .entries),
            omittedLines: try container.decodeIfPresent([String].self, forKey: .omittedLines) ?? [],
            screen: try container.decodeIfPresent(
                ContextManifest.ScreenStatus.self,
                forKey: .screen
            ) ?? .notCaptured
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encode(omittedLines, forKey: .omittedLines)
        try container.encode(screen, forKey: .screen)
    }
}

/// The fixed request configuration stored with a conversation.
///
/// `Context` is not persisted. Only a sanitized tiering label is stored, so a raw
/// page URL or local path can never enter the conversation file through config.
public struct StoredConversationConfiguration: Codable, Equatable, Sendable {
    public var model: String
    public var apiVersion: String
    public var effort: String
    public var maxOutputTokens: Int
    public var notesBudget: Int
    public var tieringLabel: String

    public init(
        model: String,
        apiVersion: String,
        effort: String,
        maxOutputTokens: Int,
        notesBudget: Int,
        tieringLabel: String
    ) {
        self.model = model
        self.apiVersion = apiVersion
        self.effort = effort
        self.maxOutputTokens = maxOutputTokens
        self.notesBudget = notesBudget
        self.tieringLabel = tieringLabel
    }

    public init(
        configuration: ClaudeConfiguration,
        context: Context,
        workspaces: [WorkspaceRecord] = []
    ) {
        self.init(
            model: configuration.model,
            apiVersion: configuration.apiVersion,
            effort: configuration.effort.rawValue,
            maxOutputTokens: configuration.maxOutputTokens,
            notesBudget: configuration.notesBudget,
            tieringLabel: AgentContextLabel.label(for: context, workspaces: workspaces)
        )
    }
}

public enum ConversationTurnStatus: Codable, Equatable, Sendable {
    case complete
    case truncated
    case refused
    case interrupted(heardUpTo: String?)
    case failed(reason: String)
}

/// One stored question and answer. Completed turns never contain thinking blocks,
/// signatures, credentials or tool-call payloads.
public struct ConversationTurn: Codable, Equatable, Sendable {
    public var question: String
    public var askedAt: String
    public var manifest: ContextManifest
    public var answerText: String
    public var citations: [CitationValidator.Citation]
    public var usage: ClaudeUsage
    public var status: ConversationTurnStatus

    public init(
        question: String,
        askedAt: String,
        manifest: ContextManifest,
        answerText: String,
        citations: [CitationValidator.Citation] = [],
        usage: ClaudeUsage = .zero,
        status: ConversationTurnStatus = .complete
    ) {
        self.question = question
        self.askedAt = askedAt
        self.manifest = manifest
        self.answerText = answerText
        self.citations = citations
        self.usage = usage
        self.status = status
    }
}

/// The versioned content of `conversations/<uuid>.json`.
public struct ConversationDocument: Codable, Equatable, Sendable {
    public var id: UUID
    public var scope: AgentScope
    public var startLabel: String
    public var configuration: StoredConversationConfiguration
    public var aliases: AgentAliasLedger
    public var createdAt: String
    public var updatedAt: String
    public var turns: [ConversationTurn]
    /// Notes explicitly redacted after a purge. Alias retirement alone is not a
    /// deletion: aliases also retire when a note leaves scope or is excluded.
    public var redactedNoteIDs: Set<UUID>?

    public init(
        id: UUID,
        scope: AgentScope,
        startLabel: String,
        configuration: StoredConversationConfiguration,
        aliases: AgentAliasLedger = AgentAliasLedger(),
        createdAt: String,
        updatedAt: String,
        turns: [ConversationTurn] = [],
        redactedNoteIDs: Set<UUID>? = nil
    ) {
        self.id = id
        self.scope = scope
        self.startLabel = startLabel
        self.configuration = configuration
        self.aliases = aliases
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.turns = turns
        self.redactedNoteIDs = redactedNoteIDs
    }

    public init(
        id: UUID = UUID(),
        scope: AgentScope,
        context: Context,
        configuration: ClaudeConfiguration,
        workspaces: [WorkspaceRecord] = [],
        createdAt: Date,
        turns: [ConversationTurn] = []
    ) {
        let timestamp = AgentTimestamp.rfc3339(createdAt)
        self.init(
            id: id,
            scope: scope,
            startLabel: AgentContextLabel.label(for: context, workspaces: workspaces),
            configuration: StoredConversationConfiguration(
                configuration: configuration,
                context: context,
                workspaces: workspaces
            ),
            createdAt: timestamp,
            updatedAt: timestamp,
            turns: turns
        )
    }

    public mutating func append(_ turn: ConversationTurn) {
        turns.append(turn)
        updatedAt = turn.askedAt
    }
}

public enum ConversationStoreError: Error, LocalizedError, Equatable {
    case unsafePath
    case readOnly(FileLoadProblem)
    case documentIDMismatch
    case writeFailed(String)
    case directoryUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unsafePath:
            return "A conversation path was a symbolic link or otherwise unsafe."
        case .readOnly(.newerVersion(let found, let supported)):
            return "This conversation uses format \(found), but this version supports \(supported)."
        case .readOnly(.unreadable(let reason)):
            return "This conversation could not be read: \(reason)"
        case .documentIDMismatch:
            return "The conversation file belongs to a different identifier."
        case let .writeFailed(reason):
            return "The conversation could not be written: \(reason)"
        case let .directoryUnavailable(reason):
            return "The conversations directory is unavailable: \(reason)"
        }
    }
}

/// Owner-only, versioned conversation storage.
///
/// The store is an actor, so its synchronous file operations are serialized with
/// retention purges and redactions. Paths are always derived from a `UUID`, and a
/// symbolic link is rejected rather than followed. Writes go through
/// `VersionedJSONFile` using the injected atomic writer.
public actor ConversationStore {
    public static let currentVersion = 1
    public static let defaultRetentionDays = 30
    public static let directoryName = "conversations"

    public struct OpenResult: Equatable, Sendable {
        public let document: ConversationDocument?
        public let mode: FileLoadMode
        public let outcome: FileLoadOutcome

        public var isReadOnly: Bool {
            if case .readOnly = mode { return true }
            return false
        }

        public init(
            document: ConversationDocument?,
            mode: FileLoadMode,
            outcome: FileLoadOutcome
        ) {
            self.document = document
            self.mode = mode
            self.outcome = outcome
        }
    }

    public let directory: URL

    private let clock: @Sendable () -> Date
    private let atomicWrite: @Sendable (Data, URL) throws -> Void
    private var files: [UUID: VersionedJSONFile<ConversationDocument>] = [:]

    public init(
        directory: URL,
        clock: @escaping @Sendable () -> Date = { Date() },
        atomicWrite: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: parent.path
            )
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
    ) {
        self.directory = directory
        self.clock = clock
        self.atomicWrite = atomicWrite
        try? Self.prepareDirectory(directory)
    }

    public nonisolated func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(
            id.uuidString.lowercased() + ".json",
            isDirectory: false
        )
    }

    public func open(_ id: UUID) -> OpenResult {
        guard !Self.isSymbolicLink(directory) else {
            return OpenResult(
                document: nil,
                mode: .readOnly(.unreadable(reason: "The conversations directory is a symbolic link.")),
                outcome: .unreadable
            )
        }
        let url = fileURL(for: id)
        guard !Self.isSymbolicLink(url) else {
            return OpenResult(
                document: nil,
                mode: .readOnly(.unreadable(reason: "The conversation file is a symbolic link.")),
                outcome: .unreadable
            )
        }

        let file = existingOrNewFile(id)
        if case .readOnly(let problem) = file.mode {
            return OpenResult(document: nil, mode: .readOnly(problem), outcome: file.outcome)
        }

        switch file.outcome {
        case .missing:
            return OpenResult(document: nil, mode: file.mode, outcome: file.outcome)
        case .loaded, .recovered:
            guard file.content.id == id else {
                return OpenResult(
                    document: nil,
                    mode: .readOnly(.unreadable(reason: "The conversation identifier did not match its file.")),
                    outcome: .unreadable
                )
            }
            return OpenResult(document: file.content, mode: file.mode, outcome: file.outcome)
        case .unreadable, .newer:
            return OpenResult(document: nil, mode: file.mode, outcome: file.outcome)
        }
    }

    public func load(_ id: UUID) -> ConversationDocument? {
        open(id).document
    }

    /// Saves one document with a fresh clock timestamp and returns the stored value.
    @discardableResult
    public func save(
        _ document: ConversationDocument,
        preserveUpdatedAt: Bool = false
    ) throws -> ConversationDocument {
        do {
            try Self.prepareDirectory(directory)
        } catch {
            throw ConversationStoreError.directoryUnavailable(error.localizedDescription)
        }
        guard !Self.isSymbolicLink(directory), !Self.isSymbolicLink(fileURL(for: document.id)) else {
            throw ConversationStoreError.unsafePath
        }

        var file = files[document.id] ?? makeFile(for: document.id)
        if case .readOnly(let problem) = file.mode {
            throw ConversationStoreError.readOnly(problem)
        }
        guard file.content.id == document.id else {
            throw ConversationStoreError.documentIDMismatch
        }

        var updated = document
        // A caller may hold a document loaded before a redaction. Re-apply every
        // note already redacted on disk so a stale save cannot restore it.
        for noteID in Self.redactedNoteIDs(in: file.content) {
            Self.applyRedaction(noteID: noteID, to: &updated)
        }
        if !preserveUpdatedAt {
            updated.updatedAt = AgentTimestamp.rfc3339(clock())
        }
        file.updateContent(updated)
        do {
            try file.save()
        } catch let error as VersionedJSONFile<ConversationDocument>.SaveError {
            throw Self.map(error)
        } catch {
            throw ConversationStoreError.writeFailed(error.localizedDescription)
        }
        // Drop the cache so the next load observes the file that was just written.
        files[document.id] = nil
        return updated
    }

    public func delete(_ id: UUID) throws {
        let url = fileURL(for: id)
        guard !Self.isSymbolicLink(directory), !Self.isSymbolicLink(url) else {
            throw ConversationStoreError.unsafePath
        }
        files[id] = nil
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw ConversationStoreError.writeFailed(error.localizedDescription)
            }
        }
    }

    public func conversationIDs() throws -> [UUID] {
        do {
            try Self.prepareDirectory(directory)
        } catch {
            throw ConversationStoreError.directoryUnavailable(error.localizedDescription)
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> UUID? in
            guard name.hasSuffix(".json") else { return nil }
            return UUID(uuidString: String(name.dropLast(5)))
        }
        .sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
    }

    /// Removes conversations whose last write is older than the retention window.
    @discardableResult
    public func purgeExpired(
        retentionDays: Int = ConversationStore.defaultRetentionDays,
        now: Date? = nil
    ) throws -> [UUID] {
        let cutoff = (now ?? clock()).addingTimeInterval(-Double(max(0, retentionDays)) * 86_400)
        var removed: [UUID] = []
        for id in try conversationIDs() {
            let open = open(id)
            guard let document = open.document, !open.isReadOnly else { continue }
            guard let date = Self.date(from: document.updatedAt) ?? Self.date(from: document.createdAt) else {
                continue
            }
            guard date < cutoff else { continue }
            try delete(id)
            removed.append(id)
        }
        return removed
    }

    /// Replaces a purged note's manifest and citation snippets with "note deleted"
    /// and retires every alias for that note. Answer text is never rewritten.
    @discardableResult
    public func redactNote(_ noteID: UUID) throws -> Int {
        var changedCount = 0
        for id in try conversationIDs() {
            let open = open(id)
            guard var document = open.document, !open.isReadOnly else { continue }
            let changed = Self.applyRedaction(noteID: noteID, to: &document)
            if changed {
                // A redaction must not extend the retention clock.
                _ = try save(document, preserveUpdatedAt: true)
                changedCount += 1
            }
        }
        return changedCount
    }

    /// Applies one note's redaction to a document and reports whether anything changed.
    @discardableResult
    private static func applyRedaction(
        noteID: UUID,
        to document: inout ConversationDocument
    ) -> Bool {
        var changed = false
        let aliasSet = Set(document.aliases.entries
            .filter { $0.noteID == noteID }
            .map(\.alias))
        for index in document.turns.indices {
            var turn = document.turns[index]
            var aliases = aliasSet
            for entry in turn.manifest.entries where entry.noteID == noteID {
                aliases.insert(entry.alias)
            }
            let entries = turn.manifest.entries.map { entry -> ContextManifest.Entry in
                guard entry.noteID == noteID else { return entry }
                changed = true
                return ContextManifest.Entry(
                    alias: entry.alias,
                    noteID: entry.noteID,
                    status: entry.status,
                    revision: entry.revision,
                    page: "note deleted",
                    updated: entry.updated,
                    summary: "note deleted",
                    omittedCharacters: 0
                )
            }
            let omitted = turn.manifest.omittedLines.map { line -> String in
                guard aliases.contains(where: { line.hasPrefix($0 + " ") }) else { return line }
                changed = true
                return "note deleted"
            }
            let citations = turn.citations.map { citation -> CitationValidator.Citation in
                guard citation.noteID == noteID else { return citation }
                changed = true
                return CitationValidator.Citation(
                    alias: citation.alias,
                    noteID: citation.noteID,
                    revision: citation.revision,
                    status: .deleted,
                    snippet: "note deleted"
                )
            }
            turn.manifest = ContextManifest(
                entries: entries,
                omittedLines: omitted,
                screen: turn.manifest.screen
            )
            turn.citations = citations
            document.turns[index] = turn
        }
        if !aliasSet.isEmpty {
            document.aliases.retire(noteID: noteID)
            changed = true
        }
        var tombstones = document.redactedNoteIDs ?? []
        if tombstones.insert(noteID).inserted {
            document.redactedNoteIDs = tombstones
            changed = true
        }
        return changed
    }

    private static func redactedNoteIDs(in document: ConversationDocument) -> Set<UUID> {
        var ids = document.redactedNoteIDs ?? []
        for turn in document.turns {
            for entry in turn.manifest.entries where entry.page == "note deleted" {
                ids.insert(entry.noteID)
            }
            for citation in turn.citations where citation.status == .deleted {
                ids.insert(citation.noteID)
            }
        }
        return ids
    }

    public func mode(for id: UUID) -> FileLoadMode {
        open(id).mode
    }

    // MARK: - File plumbing

    private func existingOrNewFile(_ id: UUID) -> VersionedJSONFile<ConversationDocument> {
        if let file = files[id] {
            return file
        }
        let file = makeFile(for: id)
        files[id] = file
        return file
    }

    private func makeFile(for id: UUID) -> VersionedJSONFile<ConversationDocument> {
        VersionedJSONFile<ConversationDocument>(
            fileURL: fileURL(for: id),
            defaultContent: ConversationDocument(
                id: id,
                scope: .page,
                startLabel: "",
                configuration: StoredConversationConfiguration(
                    model: "",
                    apiVersion: "",
                    effort: "",
                    maxOutputTokens: 0,
                    notesBudget: 0,
                    tieringLabel: ""
                ),
                createdAt: AgentTimestamp.rfc3339(clock()),
                updatedAt: AgentTimestamp.rfc3339(clock())
            ),
            supportedVersion: Self.currentVersion,
            decode: { data, _ in try Self.decode(data) },
            encode: { content, version in try Self.encode(content, version: version) },
            now: clock,
            atomicWrite: atomicWrite
        )
    }

    private struct Envelope: Codable {
        let version: Int
        let content: ConversationDocument
    }

    private static func decode(_ data: Data) throws -> ConversationDocument {
        try JSONDecoder().decode(Envelope.self, from: data).content
    }

    private static func encode(_ content: ConversationDocument, version: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Envelope(version: version, content: content))
    }

    private static func map(
        _ error: VersionedJSONFile<ConversationDocument>.SaveError
    ) -> ConversationStoreError {
        switch error {
        case .readOnly(let problem):
            return .readOnly(problem)
        case .sourceChanged:
            return .writeFailed("The conversation file changed on disk before it could be written.")
        case .backupChanged:
            return .writeFailed("The conversation backup changed before it could be written.")
        case .backupNameUnavailable:
            return .writeFailed("No unused conversation backup name was available.")
        }
    }

    private static func prepareDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ConversationStoreError.directoryUnavailable("The path is not a directory.")
            }
            guard !isSymbolicLink(url) else {
                throw ConversationStoreError.unsafePath
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
        } else {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
        }
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func date(from timestamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }
}
