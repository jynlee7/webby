import Foundation
import WebbyCore

/// A validated, extracted archive waiting for the user's decision in the preview sheet.
///
/// The caller owns the staging directory: install `root` with
/// `SkinLibraryFolder.install(stagedFolder:id:)` or call `discard()`.
public struct StagedSkinPreview: Sendable {
    public let root: URL
    public let manifest: SkinManifest?
    /// Archive warnings plus validation diagnostics, most severe first.
    public let diagnostics: [SkinDiagnostic]
    public let isAccepted: Bool
    public let groups: [SkinGroup: SkinGroupStatus]
    /// Total size of the admitted files, in bytes.
    public let payloadBytes: Int
    public let validation: SkinArchiveValidation
    let staged: StagedSkinArchive

    /// Removes the staging directory. Safe to call after the folder was installed.
    public func discard() throws {
        try staged.discard()
    }
}

public enum SkinArchiveImporter {
    /// Reads, extracts and validates a `.webbyskin` file into a staging directory
    /// created near `stagingNear`. Any failure leaves no staging directory behind.
    public static func stage(
        archiveAt url: URL,
        stagingNear: URL,
        availableBaseIDs: Set<String>
    ) throws -> StagedSkinPreview {
        let data = try readArchive(at: url)
        let staged = try SkinArchiveExtractor.extract(data, stagingNear: stagingNear)
        let validation = SkinArchiveStaging.validate(staged, availableBaseIDs: availableBaseIDs)
        return StagedSkinPreview(
            root: staged.root,
            manifest: validation.manifest,
            diagnostics: validation.diagnostics,
            isAccepted: validation.isAccepted,
            groups: validation.groups,
            payloadBytes: validation.checker.inventory().reduce(0) { $0 + $1.bytes },
            validation: validation,
            staged: staged
        )
    }

    private static func readArchive(at url: URL) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        if let size, size > SkinArchiveLimits.archiveByteCount {
            throw SkinArchiveError.archiveTooLarge(actual: size, limit: SkinArchiveLimits.archiveByteCount)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SkinArchiveError.archiveOpenFailed(reason: "The file could not be read.")
        }
        // The size may have changed between the check and the read.
        if data.count > SkinArchiveLimits.archiveByteCount {
            throw SkinArchiveError.archiveTooLarge(actual: data.count, limit: SkinArchiveLimits.archiveByteCount)
        }
        return data
    }
}
