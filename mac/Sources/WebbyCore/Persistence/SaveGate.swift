import Foundation

public enum SaveFailure: Error, LocalizedError, Equatable {
    case readOnly(FileLoadProblem)
    case sourceChanged
    case backupChanged
    case backupNameUnavailable

    public var errorDescription: String? {
        switch self {
        case .readOnly(.newerVersion(let found, let supported)):
            return "This file uses format \(found), but this version of Webby supports \(supported). Saving is disabled."
        case .readOnly(.unreadable(let reason)):
            return "This file could not be read, so saving is disabled: \(reason)"
        case .sourceChanged:
            return "The file changed on disk after it was loaded, so it was not overwritten."
        case .backupChanged:
            return "The migration backup is missing or changed, so the original file was not overwritten."
        case .backupNameUnavailable:
            return "No unused name was available for the migration backup."
        }
    }
}

/// Serializes every write for one file so an older generation can never replace a newer one.
///
/// Two separate mechanisms, on purpose:
/// - a private serial queue serializes the encode-and-write work, keeping blocking file
///   I/O off both the caller's thread and the Swift concurrency cooperative pool;
/// - a short-lived `NSLock` guards only the small in-memory state, so `mode`,
///   `generation` and `isReadOnly` never wait for a write to finish.
public final class SaveGate<Content: Codable & Sendable>: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let generation: UInt64
        public let content: Content

        public init(generation: UInt64, content: Content) {
            self.generation = generation
            self.content = content
        }
    }

    public struct Acknowledgement: Sendable, Equatable {
        public let generation: UInt64
        public let migrationBackupURL: URL?

        public init(generation: UInt64, migrationBackupURL: URL?) {
            self.generation = generation
            self.migrationBackupURL = migrationBackupURL
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.webby.save-gate", qos: .utility)

    // Guarded by `lock`. Never held across file I/O.
    private var file: VersionedJSONFile<Content>
    private var committedGeneration: UInt64
    private var hasCommitted = false

    public init(file: VersionedJSONFile<Content>, committedGeneration: UInt64) {
        self.file = file
        self.committedGeneration = committedGeneration
    }

    public var fileURL: URL { locked { $0.fileURL } }

    public var mode: FileLoadMode { locked { $0.mode } }

    public var outcome: FileLoadOutcome { locked { $0.outcome } }

    public var isReadOnly: Bool {
        locked {
            if case .readOnly = $0.mode { return true }
            return false
        }
    }

    public var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return committedGeneration
    }

    public var migrationBackupURL: URL? { locked { $0.migrationBackupURL } }

    /// Synchronous write for callers that must block, such as the quit fallback.
    /// The serial queue still orders it against background writes.
    public func commit(_ snapshot: Snapshot) throws -> Acknowledgement {
        try queue.sync { try performCommit(snapshot) }
    }

    /// Write for async callers. The blocking work runs on the gate's queue, so a
    /// committed generation never parks a cooperative-pool thread.
    public func commitAsync(_ snapshot: Snapshot) async throws -> Acknowledgement {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.performCommit(snapshot) })
            }
        }
    }

    private func locked<T>(_ body: (VersionedJSONFile<Content>) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(file)
    }

    private func performCommit(_ snapshot: Snapshot) throws -> Acknowledgement {
        lock.lock()
        let mode = file.mode
        let alreadyCommitted = hasCommitted && snapshot.generation <= committedGeneration
        let currentGeneration = committedGeneration
        let currentBackup = file.migrationBackupURL
        let currentFile = file
        lock.unlock()

        if case .readOnly(let problem) = mode {
            throw SaveFailure.readOnly(problem)
        }
        if alreadyCommitted {
            return Acknowledgement(generation: currentGeneration, migrationBackupURL: currentBackup)
        }

        // The first write must happen even at generation 0, so a loaded older format
        // is actually upgraded and backed up rather than left untouched on disk.
        var candidate = currentFile
        candidate.updateContent(snapshot.content)
        do {
            try candidate.save()
        } catch let error as VersionedJSONFile<Content>.SaveError {
            switch error {
            case .readOnly(let problem): throw SaveFailure.readOnly(problem)
            case .sourceChanged: throw SaveFailure.sourceChanged
            case .backupChanged: throw SaveFailure.backupChanged
            case .backupNameUnavailable: throw SaveFailure.backupNameUnavailable
            }
        }

        lock.lock()
        file = candidate
        committedGeneration = snapshot.generation
        hasCommitted = true
        lock.unlock()

        return Acknowledgement(generation: snapshot.generation, migrationBackupURL: candidate.migrationBackupURL)
    }
}
