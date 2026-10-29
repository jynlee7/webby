import Foundation
import WebbyCore

/// An extracted skin that has passed archive preflight and bounded extraction.
///
/// The caller owns the staging directory after this value is returned. Installation
/// and validation through system media decoders belong to later issue #18 slices.
public struct StagedSkinArchive: Sendable {
    public let root: URL
    public let entries: [SkinArchivePreflightEntry]
    public let warnings: [SkinDiagnostic]

    init(
        root: URL,
        entries: [SkinArchivePreflightEntry],
        warnings: [SkinDiagnostic]
    ) {
        self.root = root
        self.entries = entries
        self.warnings = warnings
    }

    /// Removes this staging directory. Calling it after a successful discard is safe.
    public func discard() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: root)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}
