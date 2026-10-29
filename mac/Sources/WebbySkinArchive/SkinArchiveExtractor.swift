import Foundation
import ZIPFoundation

struct SkinArchiveExtractionEnvironment: @unchecked Sendable {
    let fileManager: FileManager
    let makeStagingDirectory: @Sendable (URL) throws -> URL

    static let live = SkinArchiveExtractionEnvironment(
        fileManager: .default,
        makeStagingDirectory: { appropriateURL in
            try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: appropriateURL,
                create: true
            )
        }
    )
}

/// Bounded extraction of a preflighted `.webbyskin` snapshot.
public enum SkinArchiveExtractor {
    private static let bufferSize = 64 * 1024

    public static func extract(
        _ data: Data,
        stagingNear appropriateURL: URL
    ) throws -> StagedSkinArchive {
        try extract(data, stagingNear: appropriateURL, environment: .live)
    }

    static func extract(
        _ data: Data,
        stagingNear appropriateURL: URL,
        environment: SkinArchiveExtractionEnvironment
    ) throws -> StagedSkinArchive {
        let preflight = try SkinArchivePreflight.check(data)
        let centralEntries = try SkinArchiveCentralDirectoryReader.read(data)

        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw SkinArchiveError.archiveOpenFailed(reason: String(describing: error))
        }

        let zipEntries = Array(archive)
        try reconcile(zipEntries, with: centralEntries)

        var zipEntriesByPath: [Data: Entry] = [:]
        for entry in zipEntries where entry.type == .file {
            let key = Data(entry.path.utf8)
            guard zipEntriesByPath.updateValue(entry, forKey: key) == nil else {
                throw SkinArchiveError.archiveEntryMismatch(
                    path: entry.path,
                    reason: "duplicate ZIPFoundation entry"
                )
            }
        }

        let admitted: [(SkinArchivePreflightEntry, Entry)] = try preflight.entries.map { item in
            guard let entry = zipEntriesByPath[Data(item.rawPath.utf8)] else {
                throw SkinArchiveError.archiveEntryMismatch(
                    path: item.rawPath,
                    reason: "admitted entry is missing from archive reader"
                )
            }
            return (item, entry)
        }

        let stagingRoot: URL
        do {
            stagingRoot = try environment.makeStagingDirectory(appropriateURL)
        } catch {
            throw SkinArchiveError.extractionFailed(
                path: appropriateURL.path,
                reason: "staging directory could not be created: \(error)"
            )
        }

        do {
            try environment.fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: stagingRoot.path
            )
            var budget = SkinArchiveByteBudget()
            for (item, entry) in admitted {
                try extract(
                    item,
                    entry: entry,
                    archive: archive,
                    stagingRoot: stagingRoot,
                    budget: &budget,
                    fileManager: environment.fileManager
                )
            }
            return StagedSkinArchive(
                root: stagingRoot,
                entries: preflight.entries,
                warnings: preflight.warnings
            )
        } catch {
            let underlying = (error as? SkinArchiveError) ?? SkinArchiveError.extractionFailed(
                path: stagingRoot.path,
                reason: String(describing: error)
            )
            do {
                if environment.fileManager.fileExists(atPath: stagingRoot.path) {
                    try environment.fileManager.removeItem(at: stagingRoot)
                }
            } catch let cleanupError {
                throw SkinArchiveError.cleanupFailed(
                    path: stagingRoot.path,
                    reason: String(describing: cleanupError),
                    underlying: underlying
                )
            }
            throw underlying
        }
    }

    private static func reconcile(
        _ zipEntries: [Entry],
        with centralEntries: [SkinArchiveCentralDirectoryEntry]
    ) throws {
        guard zipEntries.count == centralEntries.count else {
            throw SkinArchiveError.archiveEntryMismatch(
                path: nil,
                reason: "archive readers disagree on entry count"
            )
        }

        for (entry, central) in zip(zipEntries, centralEntries) {
            guard Data(entry.path.utf8) == Data(central.rawPath.utf8) else {
                throw SkinArchiveError.archiveEntryMismatch(
                    path: central.rawPath,
                    reason: "archive readers disagree on entry path or order"
                )
            }
            let expectedType: Entry.EntryType = central.isDirectory ? .directory : .file
            guard entry.type == expectedType else {
                throw SkinArchiveError.archiveEntryMismatch(
                    path: central.rawPath,
                    reason: "archive readers disagree on entry type"
                )
            }
            let method: UInt16 = entry.isCompressed ? 8 : 0
            guard method == central.compressionMethod,
                  entry.compressedSize == UInt64(central.compressedSize),
                  entry.uncompressedSize == UInt64(central.uncompressedSize),
                  entry.checksum == central.crc32
            else {
                throw SkinArchiveError.archiveEntryMismatch(
                    path: central.rawPath,
                    reason: "archive readers disagree on entry metadata"
                )
            }
        }
    }

    private static func extract(
        _ item: SkinArchivePreflightEntry,
        entry: Entry,
        archive: Archive,
        stagingRoot: URL,
        budget: inout SkinArchiveByteBudget,
        fileManager: FileManager
    ) throws {
        let destination = try destinationURL(for: item.path, under: stagingRoot)
        try createParentDirectories(for: destination, root: stagingRoot, fileManager: fileManager)

        guard !fileManager.fileExists(atPath: destination.path) else {
            throw SkinArchiveError.destinationExists(path: item.path)
        }
        guard fileManager.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw SkinArchiveError.extractionFailed(
                path: item.path,
                reason: "destination file could not be created"
            )
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: destination)
        } catch {
            throw SkinArchiveError.extractionFailed(
                path: item.path,
                reason: "destination file could not be opened"
            )
        }

        var fileBytes = 0
        let checksum: UInt32
        do {
            checksum = try archive.extract(
                entry,
                bufferSize: bufferSize,
                skipCRC32: false
            ) { chunk in
                fileBytes = try budget.charge(
                    chunk.count,
                    path: item.path,
                    fileBytes: fileBytes,
                    fileLimit: fileLimit(for: item.path)
                )
                if !chunk.isEmpty {
                    try handle.write(contentsOf: chunk)
                }
            }
            try handle.close()
        } catch let error as SkinArchiveError {
            try? handle.close()
            throw error
        } catch {
            try? handle.close()
            throw SkinArchiveError.extractionFailed(
                path: item.path,
                reason: String(describing: error)
            )
        }

        guard checksum == item.crc32 else {
            throw SkinArchiveError.crcMismatch(
                path: item.path,
                expected: item.crc32,
                actual: checksum
            )
        }
        guard fileBytes == Int(item.uncompressedSize) else {
            throw SkinArchiveError.extractionFailed(
                path: item.path,
                reason: "decompressed size differs from the central directory"
            )
        }

        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: destination.path
            )
        } catch {
            throw SkinArchiveError.extractionFailed(
                path: item.path,
                reason: "destination permissions could not be set"
            )
        }
    }

    private static func fileLimit(for path: String) -> Int {
        if path == "skin.json" {
            return SkinArchiveLimits.manifestByteCount
        }
        if path == "preview.png" || path == "preview@2x.png" || path.hasPrefix("images/") {
            return SkinArchiveLimits.imageByteCount
        }
        if path.hasPrefix("sounds/") {
            return SkinArchiveLimits.soundByteCount
        }
        return SkinArchiveLimits.uncompressedByteCount
    }

    private static func destinationURL(for path: String, under root: URL) throws -> URL {
        var destination = root
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard !component.isEmpty else {
                throw SkinArchiveError.unsafeEntryPath(path: path, reason: "empty path component")
            }
            destination.appendPathComponent(String(component), isDirectory: false)
        }

        let rootPath = root.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard destinationPath.hasPrefix(prefix) else {
            throw SkinArchiveError.unsafeEntryPath(path: path, reason: "destination escapes staging")
        }
        return destination
    }

    private static func createParentDirectories(
        for destination: URL,
        root: URL,
        fileManager: FileManager
    ) throws {
        let parent = destination.deletingLastPathComponent()
        guard parent.standardizedFileURL != root.standardizedFileURL else {
            return
        }
        if fileManager.fileExists(atPath: parent.path) {
            return
        }
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: parent.path
        )
    }
}
