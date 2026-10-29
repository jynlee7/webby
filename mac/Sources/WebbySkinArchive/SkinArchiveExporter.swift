import Foundation
import WebbyCore
import ZIPFoundation

/// Deterministic export of one installed skin folder to a `.webbyskin` archive.
///
/// The admitted files are first copied into a private snapshot with bounded reads.
/// That snapshot is what gets loaded, validated, decoded and finally archived, so an
/// editor saving a file mid-export can never produce an archive whose bytes differ
/// from the bytes that were checked. Entries are stored in UTF-8 byte order with a
/// fixed timestamp, fixed permissions, no comments and no extra fields, so exporting
/// the same skin twice produces identical bytes.
public enum SkinArchiveExporter {
    /// The earliest timestamp a ZIP entry can represent.
    private static let fixedModificationDate = Date(timeIntervalSince1970: 315_532_800)

    public static func export(
        folder: URL,
        to destination: URL,
        availableBaseIDs: Set<String>
    ) throws {
        let fileManager = FileManager.default
        let destinationDirectory = destination.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: destinationDirectory.path) else {
            throw SkinArchiveError.exportFailed(
                path: destination.path,
                reason: "the destination folder does not exist"
            )
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw SkinArchiveError.destinationExists(path: destination.lastPathComponent)
        }

        // The snapshot must live outside the source tree: a caller may export into
        // the folder itself, and a new entry there could push a valid skin over the
        // 400-entry cap before it is read.
        let snapshot: URL
        do {
            snapshot = try fileManager.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: destinationDirectory,
                create: true
            )
        } catch {
            throw SkinArchiveError.exportFailed(
                path: destination.path,
                reason: "the export snapshot could not be created"
            )
        }
        defer { try? fileManager.removeItem(at: snapshot) }

        do {
            let captured = try capture(
                folder: folder,
                into: snapshot,
                availableBaseIDs: availableBaseIDs,
                fileManager: fileManager
            )
            let validator = try validatedSnapshot(
                snapshot,
                paths: captured,
                availableBaseIDs: availableBaseIDs
            )
            try writeArchive(
                from: snapshot,
                paths: validator.paths,
                to: destination,
                fileManager: fileManager
            )
        } catch {
            if let archiveError = error as? SkinArchiveError {
                throw archiveError
            }
            throw SkinArchiveError.exportFailed(
                path: destination.path,
                reason: String(describing: error)
            )
        }
    }

    /// Copies exactly the admitted folder entries into a private snapshot, enforcing
    /// the per-file caps on the bytes it actually reads.
    private static func capture(
        folder: URL,
        into snapshot: URL,
        availableBaseIDs: Set<String>,
        fileManager: FileManager
    ) throws -> [String] {
        let loaded = SkinFolderLoader.load(
            folder: folder,
            origin: .installed,
            availableBaseIDs: availableBaseIDs
        )
        guard loaded.document != nil,
              !loaded.diagnostics.contains(where: { $0.severity == .fatal })
        else {
            let code = loaded.diagnostics.first { $0.severity == .fatal }?.code
            throw SkinArchiveError.exportSourceRejected(
                reason: "the skin folder did not load: \(code ?? "unknown")"
            )
        }

        var captured: [String] = []
        var totalBytes = 0
        for entry in loaded.entries {
            let data = try boundedData(
                at: folder.appendingPathComponent(entry.path),
                path: entry.path
            )
            let (total, overflow) = totalBytes.addingReportingOverflow(data.count)
            guard !overflow, total <= SkinArchiveLimits.uncompressedByteCount else {
                throw SkinArchiveError.declaredSizeExceeded(
                    path: entry.path,
                    declared: UInt64(overflow ? Int.max : total),
                    limit: SkinArchiveLimits.uncompressedByteCount
                )
            }
            totalBytes = total

            let destination = snapshot.appendingPathComponent(entry.path)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard fileManager.createFile(
                atPath: destination.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw SkinArchiveError.exportFailed(
                    path: entry.path,
                    reason: "the snapshot file could not be written"
                )
            }
            captured.append(entry.path)
        }
        return captured
    }

    /// Loads the snapshot, decodes its media, and returns the paths to archive.
    private static func validatedSnapshot(
        _ snapshot: URL,
        paths: [String],
        availableBaseIDs: Set<String>
    ) throws -> (paths: [String], document: SkinManifestDocument) {
        let loaded = SkinFolderLoader.load(
            folder: snapshot,
            origin: .installed,
            availableBaseIDs: availableBaseIDs
        )
        guard let document = loaded.document,
              !loaded.diagnostics.contains(where: { $0.severity == .fatal })
        else {
            let code = loaded.diagnostics.first { $0.severity == .fatal }?.code
            throw SkinArchiveError.exportSourceRejected(
                reason: "the captured skin did not load: \(code ?? "unknown")"
            )
        }

        let checker = SkinAssetChecker(root: snapshot, paths: paths)
        guard !checker.pixelBudgetExceeded else {
            throw SkinArchiveError.exportSourceRejected(
                reason: "the skin exceeds the decoded pixel budget"
            )
        }

        let validation = SkinValidator.validate(
            document: document,
            assets: checker,
            context: SkinValidationContext(
                isBuiltIn: false,
                availableBaseIDs: availableBaseIDs
            )
        )
        guard !validation.diagnostics.contains(where: { $0.severity == .fatal }) else {
            throw SkinArchiveError.exportSourceRejected(
                reason: "the skin manifest is not acceptable"
            )
        }
        for path in paths {
            if case .invalid = checker.image(path) {
                throw SkinArchiveError.exportSourceRejected(
                    reason: "image '\(path)' did not decode"
                )
            }
            if case .invalid = checker.sound(path) {
                throw SkinArchiveError.exportSourceRejected(
                    reason: "sound '\(path)' did not decode"
                )
            }
        }

        return (
            loaded.entries.map(\.path).sorted {
                Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8))
            },
            document
        )
    }

    private static func writeArchive(
        from snapshot: URL,
        paths: [String],
        to destination: URL,
        fileManager: FileManager
    ) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            let archive = try Archive(url: temporary, accessMode: .create)
            for path in paths {
                let data = try Data(contentsOf: snapshot.appendingPathComponent(path))
                try archive.addEntry(
                    with: path,
                    type: .file,
                    uncompressedSize: Int64(data.count),
                    modificationDate: fixedModificationDate,
                    permissions: 0o644,
                    compressionMethod: .deflate,
                    bufferSize: 64 * 1024
                ) { position, size in
                    let start = Int(position)
                    let end = min(start + size, data.count)
                    guard start <= end else {
                        return Data()
                    }
                    return data.subdata(in: start..<end)
                }
            }

            let exported = try Data(contentsOf: temporary)
            guard exported.count <= SkinArchiveLimits.archiveByteCount else {
                throw SkinArchiveError.archiveTooLarge(
                    actual: exported.count,
                    limit: SkinArchiveLimits.archiveByteCount
                )
            }
            // The written archive must pass the same preflight as an imported one.
            _ = try SkinArchivePreflight.check(exported)

            guard !fileManager.fileExists(atPath: destination.path) else {
                throw SkinArchiveError.destinationExists(path: destination.lastPathComponent)
            }
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static func boundedData(at url: URL, path: String) throws -> Data {
        let limit: Int
        switch path {
        case "skin.json":
            limit = SkinArchiveLimits.manifestByteCount
        case "preview.png", "preview@2x.png":
            limit = SkinArchiveLimits.imageByteCount
        default:
            if path.hasPrefix("images/") {
                limit = SkinArchiveLimits.imageByteCount
            } else if path.hasPrefix("sounds/") {
                limit = SkinArchiveLimits.soundByteCount
            } else {
                limit = SkinArchiveLimits.uncompressedByteCount
            }
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = (attributes[.size] as? NSNumber)?.intValue, size > limit {
            throw SkinArchiveError.declaredSizeExceeded(
                path: path,
                declared: UInt64(size),
                limit: limit
            )
        }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else {
            throw SkinArchiveError.declaredSizeExceeded(
                path: path,
                declared: UInt64(data.count),
                limit: limit
            )
        }
        return data
    }
}
