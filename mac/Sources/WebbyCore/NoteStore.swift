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
        case sourceChanged
        case backupChanged
        case backupNameUnavailable
        /// A prepared import was built from a state that is no longer current.
        case staleImportGeneration(expected: UInt64, found: UInt64)
        /// The import plan no longer validates against the current notes.
        case invalidImportPlan

        public var errorDescription: String? {
            switch self {
            case .readOnly(.newerVersion(let found, let supported)):
                return "This notes file was created by a newer version of Webby (format \(found), supported \(supported)). Saving is disabled; update Webby to edit notes."
            case .readOnly(.unreadable(let reason)):
                return "This notes file could not be read, so saving is disabled: \(reason)"
            case .sourceChanged:
                return "The notes file changed on disk after loading. Reload it before saving."
            case .backupChanged:
                return "The migration backup is missing or changed. The original notes were not overwritten."
            case .backupNameUnavailable:
                return "No unused name was available for the migration backup. The original notes were not overwritten."
            case .staleImportGeneration:
                return "The notes changed while the import was waiting, so the import was not applied. Try again."
            case .invalidImportPlan:
                return "The import no longer matches the current notes, so nothing was imported."
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
        switch gate.mode {
        case .writable: return .writable
        case .readOnly(let problem): return .readOnly(problem)
        }
    }

    public var outcome: FileLoadOutcome { gate.outcome }
    public var migrationBackupURL: URL? { gate.migrationBackupURL }

    /// Generation of the newest in-memory mutation; 0 means nothing changed since load.
    ///
    /// It lives behind a lock so a prepared import can compare it from the save queue
    /// without touching the (non-Sendable) store.
    public var mutationGeneration: UInt64 { clock.current }
    /// Generation known to be on disk.
    public var committedGeneration: UInt64 { gate.generation }
    public var hasUnsavedChanges: Bool { mutationGeneration > gate.generation }

    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Webby", isDirectory: true).appendingPathComponent("notes.json")
    }

    private let gate: SaveGate<NotesDocument>
    private let writer: DiskWriter<NotesDocument>
    private let clock = MutationClock()
    private let backupNow: @Sendable () -> Date
    private let backupSuffix: @Sendable (Int) -> String

    public init(
        fileURL: URL = NoteStore.defaultFileURL,
        now: Date = Date(),
        backupDate: @escaping @Sendable () -> Date = { Date() },
        backupSuffix: @escaping @Sendable (Int) -> String = { _ in
            String(UUID().uuidString.lowercased().prefix(8))
        },
        atomicWrite: @escaping @Sendable (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        }
    ) {
        let file = VersionedJSONFile<NotesDocument>(
            fileURL: fileURL,
            defaultContent: NotesDocument(),
            supportedVersion: Self.currentVersion,
            decode: { try NotesDocument.decode($0, version: $1) },
            encode: { try NotesDocument.encode($0, version: $1) },
            backupBeforeUpgrade: true,
            now: { now },
            atomicWrite: atomicWrite
        )
        let gate = SaveGate(file: file, committedGeneration: 0)
        self.fileURL = fileURL
        self.notes = file.content.notes
        self.workspaces = file.content.workspaces
        self.gate = gate
        self.writer = DiskWriter(gate: gate)
        self.backupNow = backupDate
        self.backupSuffix = backupSuffix
    }

    private var document: NotesDocument {
        NotesDocument(notes: notes, workspaces: workspaces)
    }

    private func advanceGeneration() {
        clock.advance()
    }


    public func note(id: UUID) -> Note? { notes.first { $0.id == id } }

    public func notes(matching context: Context) -> [Note] {
        notes.filter { NoteVisibility.isAttached($0, to: context) }
    }

    /// Adds a note, optionally materializing one workspace record in the same
    /// generation. The record is validated with the existing workspace rules.
    @discardableResult
    public func add(_ note: Note, workspace: WorkspaceRecord? = nil) -> Bool {
        guard mode == .writable, self.note(id: note.id) == nil else { return false }
        if let workspace {
            var records = workspaces
            records.append(workspace)
            guard (try? NotesDocument.validateWorkspaces(records)) != nil else { return false }
            workspaces = records
        }
        notes.append(note)
        advanceGeneration()
        return true
    }

    @discardableResult
    public func updateContent(id: UUID, change: ContentChange, now: Date = Date()) -> Bool {
        updateContent(id: id, changes: [change], now: now)
    }

    /// Applies several content changes as one revision, for actions that change both
    /// an attachment and its workspace override.
    @discardableResult
    public func updateContent(id: UUID, changes: [ContentChange], now: Date = Date()) -> Bool {
        guard mode == .writable,
              !changes.isEmpty,
              let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = notes[index]
        var changed = false
        for change in changes {
            switch change {
            case .text(let text):
                if candidate.text != text {
                    candidate.text = text
                    changed = true
                }
            case .anchor(let anchor):
                if candidate.anchor != anchor {
                    candidate.anchor = anchor
                    changed = true
                }
            case .workspaceOverride(let workspace):
                if candidate.workspaceOverride != workspace {
                    candidate.workspaceOverride = workspace
                    changed = true
                }
            case .attachment(let anchor, let tab):
                if candidate.anchor != anchor || (candidate.tab == nil) != (tab == nil) {
                    candidate.anchor = anchor
                    candidate.tab = tab
                    changed = true
                }
            }
        }
        guard changed, candidate.revision < Int.max else { return false }
        candidate.revision += 1
        candidate.updatedAt = now
        notes[index] = candidate
        advanceGeneration()
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
        advanceGeneration()
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
        advanceGeneration()
        return true
    }

    @discardableResult
    public func trash(id: UUID, now: Date = Date()) -> Bool {
        guard mode == .writable,
              let index = notes.firstIndex(where: { $0.id == id }),
              notes[index].trashedAt == nil else { return false }
        notes[index].trashedAt = now
        advanceGeneration()
        return true
    }

    @discardableResult
    public func restore(id: UUID) -> Bool {
        guard mode == .writable,
              let index = notes.firstIndex(where: { $0.id == id }),
              notes[index].trashedAt != nil else { return false }
        notes[index].trashedAt = nil
        advanceGeneration()
        return true
    }

    /// Permanently removes only notes trashed before the cutoff. Read-only stores never purge.
    /// Library paths pass `includingEphemeral: false` so in-memory notes stay overlay-only.
    @discardableResult
    public func purgeTrash(olderThan cutoff: Date, includingEphemeral: Bool = true) -> Int {
        guard mode == .writable else { return 0 }
        return purgeTrash(
            where: { note in note.trashedAt.map { $0 < cutoff } ?? false },
            includingEphemeral: includingEphemeral
        )
    }

    /// Permanently removes only the given notes that are still in Trash. A note
    /// trashed after a confirmation was requested is not part of that confirmation.
    @discardableResult
    public func purgeTrash(ids: Set<UUID>, includingEphemeral: Bool = false) -> Int {
        guard mode == .writable else { return 0 }
        return purgeTrash(
            where: { note in ids.contains(note.id) && note.trashedAt != nil },
            includingEphemeral: includingEphemeral
        )
    }

    private func purgeTrash(
        where isIncluded: (Note) -> Bool,
        includingEphemeral: Bool
    ) -> Int {
        let oldCount = notes.count
        notes.removeAll { note in
            guard isIncluded(note) else { return false }
            return includingEphemeral || !note.ephemeral
        }
        let removed = oldCount - notes.count
        if removed > 0 { advanceGeneration() }
        return removed
    }

    public func replaceWorkspaces(_ records: [WorkspaceRecord]) throws {
        if case .readOnly(let reason) = mode { throw StoreError.readOnly(reason) }
        try NotesDocument.validateWorkspaces(records)
        guard records != workspaces else { return }
        workspaces = records
        advanceGeneration()
    }

    /// Writes the current state through the shared gate on the calling thread.
    public func save() throws {
        _ = try saveRequest().commitNow()
    }

    /// Queues the current state for the ordered background writer.
    public func enqueueSave() async {
        await saveRequest().enqueue()
    }

    /// Waits until the newest in-memory state is on disk.
    public func flush() async throws {
        _ = try await saveRequest().flush()
    }

    /// Synchronous quit fallback. Uses the same gate as the background writer, so an
    /// in-flight commit cannot be duplicated or overtaken.
    public func saveSynchronously() throws {
        _ = try saveRequest().commitNow()
    }

    /// Captures the current state so it can be written from any actor.
    ///
    /// The store itself is not `Sendable`, so an actor that owns it cannot pass it to
    /// an async save. A request carries only the snapshot, the ordered writer and the
    /// gate, and writes through the same paths as the store's own save methods.
    public func saveRequest() -> SaveRequest {
        SaveRequest(
            snapshot: SaveGate<NotesDocument>.Snapshot(generation: mutationGeneration, content: document),
            writer: writer,
            gate: gate
        )
    }

    /// Captures an immutable candidate and the generation it expects to replace.
    ///
    /// The plan is applied only to this snapshot; the store itself does not change
    /// until `publishImport(_:)` accepts the acknowledged receipt. The returned value
    /// carries no reference to the store, so it can cross actors.
    public func prepareImport(_ plan: ImportPlan) -> ImportRequest {
        let baseMutation = mutationGeneration
        let expectedGeneration = gate.generation

        var records = workspaces
        for update in plan.workspaceUpdates {
            if let index = records.firstIndex(where: { $0.id == update.id }) {
                records[index] = update
            } else {
                records.append(update)
            }
        }
        records.append(contentsOf: plan.workspacesToAdd)

        var candidateNotes = notes
        candidateNotes.append(contentsOf: plan.notesToAdd)
        let isValid = (try? NotesDocument.validateWorkspaces(records)) != nil

        let backup = PreImportBackup(
            fileURL: fileURL,
            now: backupNow,
            suffix: backupSuffix,
            clock: clock,
            baseMutationGeneration: baseMutation
        )

        return ImportRequest(
            document: NotesDocument(notes: candidateNotes, workspaces: records),
            expectedGeneration: expectedGeneration,
            candidateGeneration: max(baseMutation, expectedGeneration) &+ 1,
            baseMutationGeneration: baseMutation,
            gate: gate,
            isValid: isValid,
            prepare: { try backup.create() }
        )
    }

    /// Applies an acknowledged import to memory. Only a receipt written by this store's
    /// gate for the exact mutation state it was built from is accepted.
    @discardableResult
    public func publishImport(_ receipt: ImportReceipt) -> Bool {
        guard mode == .writable,
              receipt.baseMutationGeneration == mutationGeneration,
              receipt.generation == gate.generation else { return false }
        notes = receipt.document.notes
        workspaces = receipt.document.workspaces
        clock.set(receipt.generation)
        return true
    }

    /// A prepared import: immutable candidate content plus everything needed to write
    /// it through the gate. It never holds the store, so it is safe to send.
    public struct ImportRequest: Sendable {
        fileprivate let document: NotesDocument
        fileprivate let expectedGeneration: UInt64
        fileprivate let candidateGeneration: UInt64
        fileprivate let baseMutationGeneration: UInt64
        fileprivate let gate: SaveGate<NotesDocument>
        fileprivate let isValid: Bool
        fileprivate let prepare: @Sendable () throws -> URL?

        /// The generation the candidate will have once written.
        public var generation: UInt64 { candidateGeneration }
        public var expectedCommittedGeneration: UInt64 { expectedGeneration }

        /// Creates the pre-import backup and writes the candidate on the gate's serial
        /// queue. Throws when the expected generation is stale, the backup fails, or the
        /// write fails; only a returned receipt may be published.
        public func commit() async throws -> ImportReceipt {
            guard isValid else { throw NoteStore.StoreError.invalidImportPlan }
            do {
                let acknowledgement = try await gate.commitPrepared(
                    SaveGate<NotesDocument>.Snapshot(
                        generation: candidateGeneration,
                        content: document
                    ),
                    expectedGeneration: expectedGeneration,
                    prepare: prepare
                )
                guard acknowledgement.generation == candidateGeneration else {
                    throw NoteStore.StoreError.staleImportGeneration(
                        expected: candidateGeneration,
                        found: acknowledgement.generation
                    )
                }
                return ImportReceipt(
                    generation: acknowledgement.generation,
                    backupURL: acknowledgement.preImportBackupURL,
                    document: document,
                    baseMutationGeneration: baseMutationGeneration
                )
            } catch let error as SaveFailure {
                switch error {
                case .readOnly(let problem): throw NoteStore.StoreError.readOnly(problem)
                case .sourceChanged: throw NoteStore.StoreError.sourceChanged
                case .backupChanged: throw NoteStore.StoreError.backupChanged
                case .backupNameUnavailable: throw NoteStore.StoreError.backupNameUnavailable
                case .staleGeneration(let expected, let committed):
                    throw NoteStore.StoreError.staleImportGeneration(expected: expected, found: committed)
                }
            }
        }
    }

    /// An acknowledged write of one prepared import candidate.
    public struct ImportReceipt: Sendable {
        public let generation: UInt64
        /// The pre-import backup, created before the candidate was written.
        public let backupURL: URL?
        fileprivate let document: NotesDocument
        fileprivate let baseMutationGeneration: UInt64
    }

    /// Creates the pre-import backup from the current file and verifies it before the
    /// candidate is allowed to replace it. Runs inside the save gate's queue.
    private struct PreImportBackup: Sendable {
        let fileURL: URL
        let now: @Sendable () -> Date
        let suffix: @Sendable (Int) -> String
        let clock: MutationClock
        let baseMutationGeneration: UInt64

        func create() throws -> URL? {
            // An edit that landed after the candidate was built must abort the write.
            guard clock.current == baseMutationGeneration else {
                throw NoteStore.StoreError.staleImportGeneration(
                    expected: baseMutationGeneration,
                    found: clock.current
                )
            }

            let target = fileURL.resolvingSymlinksInPath()
            let sourceData: Data
            if FileManager.default.fileExists(atPath: target.path) {
                sourceData = try Data(contentsOf: target)
            } else {
                // The first import still gets a restore point: the empty pre-import state.
                sourceData = try NotesDocument.encode(NotesDocument(), version: 2)
            }

            let baseName = target.deletingPathExtension().lastPathComponent
            let fileExtension = target.pathExtension.isEmpty ? "json" : target.pathExtension
            let timestamp = BackupFileNaming.timestamp(from: now())
            let directory = target.deletingLastPathComponent()
            let suffix = self.suffix

            let backup: URL
            do {
                backup = try BackupFileNaming.createExclusiveBackup(sourceData, in: directory) { attempt in
                    "\(baseName).pre-import-\(timestamp)-\(suffix(attempt)).\(fileExtension)"
                }
            } catch BackupFileError.nameUnavailable {
                throw NoteStore.StoreError.backupNameUnavailable
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  try Data(contentsOf: backup) == sourceData else {
                throw NoteStore.StoreError.backupChanged
            }
            return backup
        }
    }

    /// The store's state at one generation, ready to be written.
    public struct SaveRequest: Sendable {
        fileprivate let snapshot: SaveGate<NotesDocument>.Snapshot
        fileprivate let writer: DiskWriter<NotesDocument>
        fileprivate let gate: SaveGate<NotesDocument>

        public var generation: UInt64 { snapshot.generation }

        /// True while the file holds an older generation than this request.
        public var isUnsaved: Bool { snapshot.generation > gate.generation }

        /// Queues the state for the ordered background writer without waiting.
        public func enqueue() async {
            await writer.enqueue(snapshot)
        }

        /// Waits until this state, or a newer one, is on disk. Returns the committed
        /// generation.
        public func flush() async throws -> UInt64 {
            try await writer.flush(snapshot)
            return max(gate.generation, snapshot.generation)
        }

        /// Writes on the calling thread through the shared gate and returns the
        /// committed generation. An older request never replaces a newer commit.
        public func commitNow() throws -> UInt64 {
            do {
                return try gate.commit(snapshot).generation
            } catch let error as SaveFailure {
                switch error {
                case .readOnly(let problem): throw StoreError.readOnly(problem)
                case .sourceChanged: throw StoreError.sourceChanged
                case .backupChanged: throw StoreError.backupChanged
                case .backupNameUnavailable: throw StoreError.backupNameUnavailable
                case .staleGeneration(let expected, let committed):
                    throw StoreError.staleImportGeneration(expected: expected, found: committed)
                }
            }
        }
    }
}

/// A lock-guarded mutation counter so a prepared import can read the store's newest
/// in-memory generation from the save queue without touching the store itself.
private final class MutationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var current: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }

    func set(_ newValue: UInt64) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
