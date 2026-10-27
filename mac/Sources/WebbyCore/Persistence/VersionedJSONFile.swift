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

        public var errorDescription: String? {
            switch self {
            case .readOnly(.newerVersion(let found, let supported)):
                return "This file uses format \(found), but this version of Webby supports \(supported). Saving is disabled."
            case .readOnly(.unreadable(let reason)):
                return "This file could not be read, so saving is disabled: \(reason)"
            }
        }
    }

    public static var currentVersion: Int { 1 }

    public let fileURL: URL
    public private(set) var mode: FileLoadMode
    public private(set) var content: Content
    public private(set) var outcome: FileLoadOutcome

    private let now: @Sendable () -> Date
    private let randomSuffix: @Sendable (Int) -> String
    /// Top-level key holding `content`, so existing file shapes such as `notes` stay unchanged.
    private let contentKey: String

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
        self.fileURL = fileURL
        self.mode = .writable
        self.content = defaultContent
        self.outcome = .missing
        self.now = now
        self.randomSuffix = randomSuffix
        self.contentKey = contentKey

        load()
    }

    public mutating func updateContent(_ newContent: Content) {
        content = newContent
    }

    public func save() throws {
        if case .readOnly(let problem) = mode {
            throw SaveError.readOnly(problem)
        }

        let data = try Self.encodedEnvelope(version: Self.currentVersion, content: content, contentKey: contentKey)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private mutating func load() {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
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
            data = try Data(contentsOf: fileURL)
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

        if probe.version > Self.currentVersion {
            mode = .readOnly(.newerVersion(found: probe.version, supported: Self.currentVersion))
            outcome = .newer(version: probe.version)
            return
        }

        do {
            content = try Self.decodedContent(from: data, contentKey: contentKey)
            mode = .writable
            outcome = .loaded
        } catch {
            recoverFromCorruptFile()
        }
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
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension.isEmpty ? "json" : fileURL.pathExtension
        let timestamp = Self.timestamp(from: now())

        for attempt in 0..<1_024 {
            let destination = fileURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "\(baseName).corrupt-\(timestamp)-\(randomSuffix(attempt)).\(fileExtension)"
                )

            if FileManager.default.fileExists(atPath: destination.path) {
                continue
            }

            do {
                try FileManager.default.moveItem(at: fileURL, to: destination)
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
