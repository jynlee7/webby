import Foundation
import WebbyCore
import ZIPFoundation

/// Deterministic export of one installed skin folder to a `.webbyskin` archive.
///
/// The source is validated with the same folder loader, manifest loader and
/// validator as import, and every admitted image and sound must decode before a
/// single byte is written. Entries are stored in UTF-8 byte order with a fixed
/// timestamp, fixed permissions, no comments and no extra fields, so exporting the
/// same skin twice produces identical bytes.
public enum SkinArchiveExporter {
    /// The earliest timestamp a ZIP entry can represent.
    private static let fixedModificationDate = Date(timeIntervalSince1970: 315_532_800)

    public static func export(
        folder: URL,
        to destination: URL,
        availableBaseIDs: Set<String>
    ) throws {
        let loaded = SkinFolderLoader.load(
            folder: folder,
            origin: .installed,
            availableBaseIDs: availableBaseIDs
        )
        guard !loaded.diagnostics.contains(where: { $0.severity == .fatal }),
              let document = loaded.document
        else {
            throw SkinArchiveError.exportSourceRejected(
                reason: "the skin folder did not load"
            )
        }

        let checker = SkinAssetChecker(
            root: folder,
            paths: loaded.entries.map(\.path)
        )
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
        for record in checker.inventory() {
            if case .invalid = checker.image(record.path) {
                throw SkinArchiveError.exportSourceRejected(
                    reason: "image '\(record.path)' did not decode"
                )
            }
            if case .invalid = checker.sound(record.path) {
                throw SkinArchiveError.exportSourceRejected(
                    reason: "sound '\(record.path)' did not decode"
                )
            }
        }

        let payloads = loaded.entries.sorted {
            Data($0.path.utf8).lexicographicallyPrecedes(Data($1.path.utf8))
        }
        let destinationDirectory = destination.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: destinationDirectory.path) else {
            throw SkinArchiveError.exportFailed(
                path: destination.path,
                reason: "the destination folder does not exist"
            )
        }

        let temporary = destinationDirectory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )

        do {
            let archive = try Archive(url: temporary, accessMode: .create)
            for entry in payloads {
                let fileURL = folder.appendingPathComponent(entry.path)
                let data = try Data(contentsOf: fileURL)
                try archive.addEntry(
                    with: entry.path,
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

            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw SkinArchiveError.destinationExists(path: destination.lastPathComponent)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if let archiveError = error as? SkinArchiveError {
                throw archiveError
            }
            throw SkinArchiveError.exportFailed(
                path: destination.path,
                reason: String(describing: error)
            )
        }
    }
}
