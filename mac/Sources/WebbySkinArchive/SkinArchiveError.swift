/// A structural problem found while preflighting a `.webbyskin` archive snapshot.
///
/// Errors carry entry names or structural reasons, never file contents. The type is
/// deliberately free of ZIPFoundation types so a later importer can surface the same
/// failures without exposing a third-party archive representation.
public enum SkinArchiveError: Error, Equatable, Sendable {
    case archiveTooLarge(actual: Int, limit: Int)
    case malformedArchive(reason: String)
    case zip64Unsupported(path: String?)
    case multiDiskUnsupported
    case entryCountExceeded(count: Int, limit: Int)
    case declaredSizeExceeded(path: String?, declared: UInt64, limit: Int)
    case decompressedSizeExceeded(path: String, actual: Int, limit: Int)
    case unsupportedCompression(method: UInt16, path: String)
    case encryptedEntry(path: String)
    case unsupportedEntryType(path: String, reason: String)
    case unsafeEntryPath(path: String, reason: String)
    case duplicateEntry(path: String)
    case collidingEntry(path: String, existing: String)
    case ambiguousWrapper(candidates: [String])
    case rejectedEntry(path: String, reason: String)
    case archiveOpenFailed(reason: String)
    case archiveEntryMismatch(path: String?, reason: String)
    case destinationExists(path: String)
    case extractionFailed(path: String, reason: String)
    case crcMismatch(path: String, expected: UInt32, actual: UInt32)
    indirect case cleanupFailed(
        path: String,
        reason: String,
        underlying: SkinArchiveError
    )
    case exportSourceRejected(reason: String)
    case exportFailed(path: String, reason: String)
    case manifestMissing
}
