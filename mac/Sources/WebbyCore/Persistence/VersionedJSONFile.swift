import Foundation

public enum FileLoadMode: Equatable, Sendable {
    case writable
    case readOnly(FileLoadProblem)
}

public enum FileLoadProblem: Equatable, Sendable {
    case newerVersion(found: Int, supported: Int)
    case unreadable(reason: String)
}

public enum FileLoadOutcome: Equatable, Sendable {
    case missing
    case loaded
    case recovered(at: URL)
    case unreadable
    case newer(version: Int)
}

public struct VersionedJSONFile<Content: Codable & Sendable>: Sendable {
    public enum SaveError: Error, LocalizedError, Equatable {
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

    public static var currentVersion: Int { 1 }

    public let fileURL: URL
    public let supportedVersion: Int
    public private(set) var mode: FileLoadMode
    public private(set) var content: Content
    public private(set) var outcome: FileLoadOutcome
    /// Set once a migration backup has been created, so callers can locate it.
    public private(set) var migrationBackupURL: URL?

    /// The path reads and writes actually use. A leading symlink is resolved so
    /// Darwin's `lstat`-based attributes see the target, and atomic writes do not
    /// replace the user's link with a regular file.
    private let resolvedFileURL: URL
    private let now: @Sendable () -> Date
    private let randomSuffix: @Sendable (Int) -> String
    private let decodeContent: @Sendable (Data, Int) throws -> Content
    private let encodeContent: @Sendable (Content, Int) throws -> Data
    private let atomicWrite: @Sendable (Data, URL) throws -> Void
    private let backupBeforeUpgrade: Bool
    /// Retained after loading an older file until the first migrated write succeeds.
    private var pendingUpgrade: PendingUpgrade?

    private struct PendingUpgrade {
        let sourceVersion: Int
        let sourceData: Data
        var backupURL: URL?
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }

    public init(
        fileURL: URL,
        defaultContent: Content,
        contentKey: String = "content",
        now: @escaping @Sendable () -> Date = { Date() },
        randomSuffix: @escaping @Sendable (Int) -> String = { _ in
            String(UUID().uuidString.lowercased().prefix(8))
        }
    ) {
        self.init(
            fileURL: fileURL,
            defaultContent: defaultContent,
            supportedVersion: Self.currentVersion,
            decode: { data, _ in try Self.decodedContent(from: data, contentKey: contentKey) },
            encode: { content, version in
                try Self.encodedEnvelope(version: version, content: content, contentKey: contentKey)
            },
            now: now,
            randomSuffix: randomSuffix
        )
    }

    public init(
        fileURL: URL,
        defaultContent: Content,
        supportedVersion: Int,
        decode: @escaping @Sendable (Data, Int) throws -> Content,
        encode: @escaping @Sendable (Content, Int) throws -> Data,
        backupBeforeUpgrade: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() },
        randomSuffix: @escaping @Sendable (Int) -> String = { _ in
            String(UUID().uuidString.lowercased().prefix(8))
        },
        atomicWrite: @escaping @Sendable (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        }
    ) {
        self.fileURL = fileURL
        self.supportedVersion = supportedVersion
        self.resolvedFileURL = Self.resolveLeadingSymlink(fileURL)
        self.mode = .writable
        self.content = defaultContent
        self.outcome = .missing
        self.now = now
        self.randomSuffix = randomSuffix
        self.decodeContent = decode
        self.encodeContent = encode
        self.atomicWrite = atomicWrite
        self.backupBeforeUpgrade = backupBeforeUpgrade
        self.migrationBackupURL = nil
        self.pendingUpgrade = nil

        load()
    }

    public mutating func updateContent(_ newContent: Content) {
        content = newContent
    }

    public mutating func save() throws {
        if case .readOnly(let problem) = mode {
            throw SaveError.readOnly(problem)
        }

        let data = try encodeContent(content, supportedVersion)

        if var pending = pendingUpgrade {
            guard let current = try? Data(contentsOf: resolvedFileURL), current == pending.sourceData else {
                throw SaveError.sourceChanged
            }
            if let backup = pending.backupURL {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: backup.path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      let bytes = try? Data(contentsOf: backup), bytes == pending.sourceData else {
                    throw SaveError.backupChanged
                }
            } else {
                pending.backupURL = try createMigrationBackup(
                    sourceVersion: pending.sourceVersion,
                    sourceData: pending.sourceData
                )
                pendingUpgrade = pending
                migrationBackupURL = pending.backupURL
            }

            try FileManager.default.createDirectory(
                at: resolvedFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try atomicWrite(data, resolvedFileURL)
            pendingUpgrade = nil
            return
        }

        try FileManager.default.createDirectory(
            at: resolvedFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try atomicWrite(data, resolvedFileURL)
    }

    private mutating func load() {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: resolvedFileURL.path)
        } catch {
            // `fileExists` hides permissions and dangling links, so use the
            // attribute lookup's error to decide whether the path is absent.
            if Self.isNoSuchFileError(error) {
                classifyMissingOrDanglingLink()
            } else {
                markUnreadable(error.localizedDescription)
            }
            return
        }

        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            markUnreadable("The path is not a regular file.")
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: resolvedFileURL)
        } catch {
            markUnreadable(error.localizedDescription)
            return
        }

        let probe: VersionProbe
        do {
            probe = try Self.decoder.decode(VersionProbe.self, from: data)
        } catch {
            recoverFromCorruptFile()
            return
        }

        if probe.version > supportedVersion {
            mode = .readOnly(.newerVersion(found: probe.version, supported: supportedVersion))
            outcome = .newer(version: probe.version)
            return
        }

        do {
            content = try decodeContent(data, probe.version)
            if backupBeforeUpgrade && probe.version < supportedVersion {
                pendingUpgrade = PendingUpgrade(
                    sourceVersion: probe.version,
                    sourceData: data,
                    backupURL: nil
                )
            }
            mode = .writable
            outcome = .loaded
        } catch {
            recoverFromCorruptFile()
        }
    }

    private func createMigrationBackup(sourceVersion: Int, sourceData: Data) throws -> URL {
        let baseName = resolvedFileURL.deletingPathExtension().lastPathComponent
        let fileExtension = resolvedFileURL.pathExtension.isEmpty ? "json" : resolvedFileURL.pathExtension
        let timestamp = Self.timestamp(from: now())
        let directory = resolvedFileURL.deletingLastPathComponent()

        for attempt in 0..<1_024 {
            let destination = directory.appendingPathComponent(
                "\(baseName).v\(sourceVersion)-\(timestamp)-\(randomSuffix(attempt)).\(fileExtension)"
            )

            do {
                try sourceData.write(to: destination, options: [.withoutOverwriting])
                return destination
            } catch {
                if Self.isFileExistsError(error) {
                    continue
                }
                throw error
            }
        }

        throw SaveError.backupNameUnavailable
    }

    /// Writes `version` beside the content at `contentKey`, so existing shapes like `{"version": 1, "notes": []}` are preserved.
    private static func encodedEnvelope(version: Int, content: Content, contentKey: String) throws -> Data {
        let contentObject = try JSONSerialization.jsonObject(
            with: encoder.encode(content),
            options: [.fragmentsAllowed]
        )
        return try JSONSerialization.data(
            withJSONObject: ["version": version, contentKey: contentObject],
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private static func decodedContent(from data: Data, contentKey: String) throws -> Content {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawContent = object[contentKey] else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Missing \"\(contentKey)\" key")
            )
        }
        let contentData = try JSONSerialization.data(withJSONObject: rawContent, options: [.fragmentsAllowed])
        return try decoder.decode(Content.self, from: contentData)
    }

    private mutating func recoverFromCorruptFile() {
        let baseName = resolvedFileURL.deletingPathExtension().lastPathComponent
        let fileExtension = resolvedFileURL.pathExtension.isEmpty ? "json" : resolvedFileURL.pathExtension
        let timestamp = Self.timestamp(from: now())

        for attempt in 0..<1_024 {
            let destination = resolvedFileURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "\(baseName).corrupt-\(timestamp)-\(randomSuffix(attempt)).\(fileExtension)"
                )

            if FileManager.default.fileExists(atPath: destination.path) {
                continue
            }

            do {
                try FileManager.default.moveItem(at: resolvedFileURL, to: destination)
                mode = .writable
                outcome = .recovered(at: destination)
                return
            } catch {
                if Self.isFileExistsError(error) {
                    continue
                }
                markUnreadable(error.localizedDescription)
                return
            }
        }

        markUnreadable("No unused name was available for the corrupt file.")
    }

    /// Resolves a symlink at the path itself. Missing or non-link paths are left
    /// alone so plain-file behavior and its error reporting stay unchanged.
    private static func resolveLeadingSymlink(_ url: URL) -> URL {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil else {
            return url
        }
        return url.resolvingSymlinksInPath()
    }

    /// Called when `attributesOfItem` reports `ENOENT`: the entry is absent, or a
    /// dangling symlink sits in its place and must not be treated as absent.
    private mutating func classifyMissingOrDanglingLink() {
        do {
            _ = try FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)
            markUnreadable("The path is a symbolic link whose target is missing.")
        } catch {
            if Self.isNoSuchFileError(error) {
                outcome = .missing
            } else {
                markUnreadable(error.localizedDescription)
            }
        }
    }

    private mutating func markUnreadable(_ reason: String) {
        mode = .readOnly(.unreadable(reason: reason))
        outcome = .unreadable
    }

    private static func isNoSuchFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain
            && (nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == ENOENT {
            return true
        }
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT
    }

    private static func isFileExistsError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteFileExistsError {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == EEXIST {
            return true
        }
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == EEXIST
    }

    private static func timestamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }
}
