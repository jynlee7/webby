import Foundation

/// In-memory notes and workspace records. Use from one actor; saves are explicit.
public final class NoteStore {
    public static let currentVersion = 2

    public enum Mode: Equatable {
        case writable
        case readOnly(FileLoadProblem)
    }

    public enum StoreError: Error, LocalizedError, Equatable {
        case readOnly(FileLoadProblem)

        public var errorDescription: String? {
            switch self {
            case .readOnly(.newerVersion(let found, let supported)):
                return "This notes file was created by a newer version of Webby (format \(found), supported \(supported)). Saving is disabled; update Webby to edit notes."
            case .readOnly(.unreadable(let reason)):
                return "This notes file could not be read, so saving is disabled: \(reason)"
            }
        }
    }

    /// Only these changes advance the content revision and last-edited time.
    public enum ContentChange: Sendable {
        case text(String)
        case anchor(Anchor?)
        case workspaceOverride(UUID?)
        case attachment(anchor: Anchor?, tab: TabBinding?)
    }

    /// Presentation and settings changes never advance the content revision.
    public enum LayoutChange: Sendable {
        case frame(NoteFrame)
        case placement(Placement)
        case collapsed(Bool)
        case hidden(Bool)
        case appearance(NoteAppearance?)
        case pinnedAt(Date?)
        case excludedFromAgent(Bool)
        case keep
    }

    public let fileURL: URL
    public private(set) var notes: [Note]
    public private(set) var workspaces: [WorkspaceRecord]

    public var mode: Mode {
        switch file.mode {
        case .writable: return .writable
        case .readOnly(let problem): return .readOnly(problem)
        }
    }

    public var outcome: FileLoadOutcome { file.outcome }
    public var migrationBackupURL: URL? { file.migrationBackupURL }

    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Webby", isDirectory: true).appendingPathComponent("notes.json")
    }

    private var file: VersionedJSONFile<NotesDocument>

    public init(fileURL: URL = NoteStore.defaultFileURL, now: Date = Date()) {
        let file = VersionedJSONFile<NotesDocument>(
            fileURL: fileURL,
            defaultContent: NotesDocument(),
            supportedVersion: Self.currentVersion,
            decode: { try NotesDocument.decode($0, version: $1) },
            encode: { try NotesDocument.encode($0, version: $1) },
            backupBeforeUpgrade: true,
            now: { now }
        )
        self.fileURL = fileURL
        self.notes = file.content.notes
        self.workspaces = file.content.workspaces
        self.file = file
    }

    public func note(id: UUID) -> Note? { notes.first { $0.id == id } }

    public func notes(matching context: Context) -> [Note] {
        notes.filter { $0.trashedAt == nil && $0.anchor?.matches(context) == true }
    }

    @discardableResult
    public func add(_ note: Note) -> Bool {
        guard mode == .writable, self.note(id: note.id) == nil else { return false }
        notes.append(note)
        return true
    }

    @discardableResult
    public func updateContent(id: UUID, change: ContentChange, now: Date = Date()) -> Bool {
        guard mode == .writable, let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = notes[index]
        switch change {
        case .text(let text):
            guard candidate.text != text else { return false }
            candidate.text = text
        case .anchor(let anchor):
            guard candidate.anchor != anchor else { return false }
            candidate.anchor = anchor
        case .workspaceOverride(let workspace):
            guard candidate.workspaceOverride != workspace else { return false }
            candidate.workspaceOverride = workspace
        case .attachment(let anchor, let tab):
            guard candidate.anchor != anchor || (candidate.tab == nil) != (tab == nil) else { return false }
            candidate.anchor = anchor
            candidate.tab = tab
        }
        guard candidate.revision < Int.max else { return false }
        candidate.revision += 1
        candidate.updatedAt = now
        notes[index] = candidate
        return true
    }

    @discardableResult
    public func updateLayout(id: UUID, change: LayoutChange) -> Bool {
        guard mode == .writable, let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = notes[index]
        switch change {
        case .frame(let frame): candidate.frame = frame
        case .placement(let placement): candidate.placement = placement
        case .collapsed(let collapsed): candidate.collapsed = collapsed
        case .hidden(let hidden): candidate.hidden = hidden
        case .appearance(let appearance): candidate.appearance = appearance
        case .pinnedAt(let pinnedAt): candidate.pinnedAt = pinnedAt
        case .excludedFromAgent(let excluded): candidate.excludedFromAgent = excluded
        case .keep: candidate.ephemeral = false
        }
        guard candidate != notes[index] else { return false }
        notes[index] = candidate
        return true
    }

    /// Changes an existing binding without attaching/detaching it or editing note content.
    @discardableResult
    public func updateBinding(id: UUID, _ change: (inout TabBinding) -> Void) -> Bool {
        guard mode == .writable,
              let index = notes.firstIndex(where: { $0.id == id }),
              var binding = notes[index].tab else { return false }
        change(&binding)
        guard binding != notes[index].tab else { return false }
        notes[index].tab = binding
        return true
    }

    @discardableResult
    public func trash(id: UUID, now: Date = Date()) -> Bool {
        guard mode == .writable,
              let index = notes.firstIndex(where: { $0.id == id }),
              notes[index].trashedAt == nil else { return false }
        notes[index].trashedAt = now
        return true
    }

    @discardableResult
    public func restore(id: UUID) -> Bool {
        guard mode == .writable,
              let index = notes.firstIndex(where: { $0.id == id }),
              notes[index].trashedAt != nil else { return false }
        notes[index].trashedAt = nil
        return true
    }

    /// Permanently removes only notes trashed before the cutoff. Read-only stores never purge.
    @discardableResult
    public func purgeTrash(olderThan cutoff: Date) -> Int {
        guard mode == .writable else { return 0 }
        let oldCount = notes.count
        notes.removeAll { note in note.trashedAt.map { $0 < cutoff } ?? false }
        return oldCount - notes.count
    }

    public func replaceWorkspaces(_ records: [WorkspaceRecord]) throws {
        if case .readOnly(let reason) = mode { throw StoreError.readOnly(reason) }
        try NotesDocument.validateWorkspaces(records)
        workspaces = records
    }

    public func save() throws {
        file.updateContent(NotesDocument(notes: notes, workspaces: workspaces))
        do {
            try file.save()
        } catch let error as VersionedJSONFile<NotesDocument>.SaveError {
            switch error {
            case .readOnly(let problem): throw StoreError.readOnly(problem)
            default: throw error
            }
        }
    }
}
