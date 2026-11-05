import Foundation

/// Failures when changing settings. Read-only is the only failure the loader can
/// produce here, so the generic loader error type stays internal to this file.
public enum SettingsError: Error, LocalizedError, Equatable {
    case readOnly(FileLoadProblem)

    public var errorDescription: String? {
        switch self {
        case .readOnly(.newerVersion(let found, let supported)):
            return "This settings file was created by a newer version of Webby (format \(found), supported \(supported)). Saving is disabled; update Webby to change settings."
        case .readOnly(.unreadable(let reason)):
            return "This settings file could not be read, so saving is disabled: \(reason)"
        }
    }
}

/// In-memory settings persisted to `settings.json` v2 (v1 files load with no removed built-in rules). Use from one actor; saves
/// are explicit.
///
/// The file follows the same load outcomes as notes: a missing file is writable
/// with defaults, a newer version or a read error is read-only with defaults in
/// memory and the file left untouched, and a corrupt file is moved aside before
/// defaults become writable.
public final class SettingsStore {
    public static let currentVersion = 2

    public let fileURL: URL
    public private(set) var settings: Settings

    public var mode: FileLoadMode { file.mode }
    public var outcome: FileLoadOutcome { file.outcome }
    /// The outcome under the name used by the storage plan.
    public var migrations: FileLoadOutcome { file.outcome }

    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Webby", isDirectory: true).appendingPathComponent("settings.json")
    }

    private var file: VersionedJSONFile<Settings>

    public init(fileURL: URL = SettingsStore.defaultFileURL, now: Date = Date()) {
        let file = VersionedJSONFile<Settings>(
            fileURL: fileURL,
            defaultContent: Settings.default,
            supportedVersion: Self.currentVersion,
            decode: { try SettingsDocument.decode($0, version: $1) },
            encode: { try SettingsDocument.encode($0, version: $1) },
            now: { now }
        )
        self.fileURL = fileURL
        self.settings = file.content
        self.file = file
    }

    /// Replaces settings in memory and persists them. A failed save restores the
    /// previous value so memory never claims more than the file holds.
    public func replace(_ settings: Settings) throws {
        let previous = self.settings
        self.settings = settings
        do {
            try save()
        } catch {
            self.settings = previous
            throw error
        }
    }

    public func save() throws {
        if case .readOnly(let problem) = mode {
            throw SettingsError.readOnly(problem)
        }
        file.updateContent(settings)
        do {
            try file.save()
        } catch VersionedJSONFile<Settings>.SaveError.readOnly(let problem) {
            throw SettingsError.readOnly(problem)
        }
        // The remaining loader save failures belong to migration backups, which
        // this store never creates, so they cannot occur here.
    }
}
