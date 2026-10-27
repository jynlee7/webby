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
/// The gate owns the single canonical `VersionedJSONFile`, because that type carries
/// migration source bytes and backup identity that must not be copied per snapshot.
/// The background writer, explicit saves and the synchronous quit fallback all call
/// `commit`, so they cannot interleave or duplicate migration work.
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

    // `NSLock` guards every mutable field below; `Content: Sendable` covers the payload.
    private let lock = NSLock()
    private var file: VersionedJSONFile<Content>
    private var committedGeneration: UInt64

    public init(file: VersionedJSONFile<Content>, committedGeneration: UInt64) {
        self.file = file
        self.committedGeneration = committedGeneration
    }

    public var fileURL: URL {
        lock.lock()
        defer { lock.unlock() }
        return file.fileURL
    }

    public var isReadOnly: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .readOnly = file.mode { return true }
        return false
    }

    public var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return committedGeneration
    }

    public var migrationBackupURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return file.migrationBackupURL
    }

    /// Writes `snapshot` unless a generation at least this new is already committed.
    ///
    /// The lock is held across the generation check, encoding, migration and atomic
    /// replacement. A newer generation arriving mid-write therefore waits and then
    /// writes after this one, rather than racing it.
    public func commit(_ snapshot: Snapshot) throws -> Acknowledgement {
        lock.lock()
        defer { lock.unlock() }

        guard snapshot.generation > committedGeneration else {
            return Acknowledgement(generation: committedGeneration, migrationBackupURL: file.migrationBackupURL)
        }

        var candidate = file
        candidate.updateContent(snapshot.content)
        try candidate.save()
        file = candidate
        committedGeneration = snapshot.generation
        return Acknowledgement(generation: snapshot.generation, migrationBackupURL: candidate.migrationBackupURL)
    }
}
