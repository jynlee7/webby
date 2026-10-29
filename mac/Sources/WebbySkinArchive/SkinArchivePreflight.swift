import Foundation
import WebbyCore

/// One file admitted by archive preflight.
///
/// The original ZIP metadata is retained so a later extraction step can match the
/// record and verify its local header without reinterpreting the central directory.
/// ZIPFoundation types stay out of the public API.
public struct SkinArchivePreflightEntry: Sendable, Equatable, Hashable {
    public let rawPath: String
    public let path: String
    public let compressionMethod: UInt16
    public let compressedSize: UInt32
    public let uncompressedSize: UInt32
    public let crc32: UInt32
    public let localHeaderOffset: UInt32

    public init(
        rawPath: String,
        path: String,
        compressionMethod: UInt16,
        compressedSize: UInt32,
        uncompressedSize: UInt32,
        crc32: UInt32,
        localHeaderOffset: UInt32
    ) {
        self.rawPath = rawPath
        self.path = path
        self.compressionMethod = compressionMethod
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
        self.crc32 = crc32
        self.localHeaderOffset = localHeaderOffset
    }
}

/// The accepted file list and non-fatal diagnostics from one archive preflight.
public struct SkinArchivePreflightResult: Sendable, Equatable {
    public let entries: [SkinArchivePreflightEntry]
    public let warnings: [SkinDiagnostic]

    public init(entries: [SkinArchivePreflightEntry], warnings: [SkinDiagnostic]) {
        self.entries = entries
        self.warnings = warnings
    }
}

/// Structural preflight for an immutable `.webbyskin` ZIP snapshot.
///
/// The API accepts only `Data`. It does not create directories, stage files, or
/// perform filesystem I/O; extraction belongs to a later slice.
public enum SkinArchivePreflight {
    public static func check(_ data: Data) throws -> SkinArchivePreflightResult {
        let centralEntries = try SkinArchiveCentralDirectoryReader.read(data)
        try validateRawNames(centralEntries)

        let wrapper = try wrapperDirectory(in: centralEntries)
        try validateLogicalNames(centralEntries, wrapper: wrapper)

        var admitted: [SkinArchivePreflightEntry] = []
        var warnings: [SkinDiagnostic] = []

        for entry in centralEntries {
            if entry.isDirectory || isMetadataPath(entry.rawPath) {
                continue
            }

            let logicalPath = logicalPath(for: entry.rawPath, wrapper: wrapper)
            switch SkinEntryRules.classify(logicalPath) {
            case .accepted(let skinEntry):
                admitted.append(SkinArchivePreflightEntry(
                    rawPath: entry.rawPath,
                    path: skinEntry.path,
                    compressionMethod: entry.compressionMethod,
                    compressedSize: entry.compressedSize,
                    uncompressedSize: entry.uncompressedSize,
                    crc32: entry.crc32,
                    localHeaderOffset: entry.localHeaderOffset
                ))
            case .skipped:
                continue
            case .warning(let reason):
                warnings.append(SkinDiagnostic(
                    code: "entry-skipped",
                    severity: .warning,
                    assetPath: logicalPath,
                    message: "Entry '\(logicalPath)' was skipped: \(reason)."
                ))
            case .rejected(let reason):
                throw SkinArchiveError.rejectedEntry(
                    path: logicalPath,
                    reason: reason
                )
            }
        }

        guard admitted.contains(where: { $0.path == "skin.json" }) else {
            throw SkinArchiveError.manifestMissing
        }

        return SkinArchivePreflightResult(entries: admitted, warnings: warnings)
    }

    // MARK: - Names

    private static func validateRawNames(
        _ entries: [SkinArchiveCentralDirectoryEntry]
    ) throws {
        var exactNames: Set<String> = []
        var normalizedNames: [String: String] = [:]

        for entry in entries {
            guard exactNames.insert(entry.rawPath).inserted else {
                throw SkinArchiveError.duplicateEntry(path: entry.rawPath)
            }

            let keyPath = entry.isDirectory
                ? droppingTrailingSlash(entry.rawPath)
                : entry.rawPath
            let key = normalizedName(keyPath)
            if let existing = normalizedNames[key] {
                throw SkinArchiveError.collidingEntry(
                    path: entry.rawPath,
                    existing: existing
                )
            }
            normalizedNames[key] = entry.rawPath
        }
    }

    private static func validateLogicalNames(
        _ entries: [SkinArchiveCentralDirectoryEntry],
        wrapper: String?
    ) throws {
        var exactNames: Set<String> = []
        var normalizedNames: [String: String] = [:]

        for entry in entries {
            if entry.isDirectory || isMetadataPath(entry.rawPath) {
                continue
            }

            let path = logicalPath(for: entry.rawPath, wrapper: wrapper)
            guard !path.isEmpty else {
                throw SkinArchiveError.unsafeEntryPath(path: path, reason: "empty path")
            }
            guard exactNames.insert(path).inserted else {
                throw SkinArchiveError.duplicateEntry(path: path)
            }

            let key = normalizedName(path)
            if let existing = normalizedNames[key] {
                throw SkinArchiveError.collidingEntry(
                    path: path,
                    existing: existing
                )
            }
            normalizedNames[key] = path
        }
    }

    private static func wrapperDirectory(
        in entries: [SkinArchiveCentralDirectoryEntry]
    ) throws -> String? {
        let payload = entries.filter {
            !$0.isDirectory && !isMetadataPath($0.rawPath)
        }
        guard !payload.isEmpty else {
            return nil
        }

        if payload.contains(where: { $0.rawPath.contains("/") == false }) {
            return nil
        }

        var topLevelComponents: Set<String> = []
        for entry in payload {
            let components = entry.rawPath.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            guard let first = components.first, !first.isEmpty else {
                continue
            }
            topLevelComponents.insert(String(first))
        }

        if topLevelComponents.count == 1 {
            return topLevelComponents.first
        }
        if topLevelComponents.count > 1 {
            throw SkinArchiveError.ambiguousWrapper(
                candidates: topLevelComponents.sorted()
            )
        }
        return nil
    }

    private static func logicalPath(for rawPath: String, wrapper: String?) -> String {
        guard let wrapper else {
            return rawPath
        }
        let prefix = wrapper + "/"
        guard rawPath.hasPrefix(prefix) else {
            return rawPath
        }
        return String(rawPath.dropFirst(prefix.count))
    }

    private static func isMetadataPath(_ path: String) -> Bool {
        let candidate = droppingTrailingSlash(path)
        guard !candidate.isEmpty else {
            return false
        }

        let components = candidate.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        if components.contains(where: { $0 == "__MACOSX" }) {
            return true
        }
        return components.last.map { $0 == ".DS_Store" } ?? false
    }

    private static func droppingTrailingSlash(_ path: String) -> String {
        guard path.hasSuffix("/") else {
            return path
        }
        return String(path.dropLast())
    }

    /// The same collision key as `SkinFolderLoader.normalizedName`.
    private static func normalizedName(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .precomposedStringWithCanonicalMapping
    }
}
