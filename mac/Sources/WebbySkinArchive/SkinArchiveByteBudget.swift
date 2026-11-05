/// Counts bytes produced by decompression before they are written to staging.
struct SkinArchiveByteBudget {
    private(set) var totalBytes = 0

    mutating func charge(
        _ byteCount: Int,
        path: String,
        fileBytes: Int,
        fileLimit: Int
    ) throws -> Int {
        guard byteCount >= 0, fileBytes >= 0 else {
            throw SkinArchiveError.extractionFailed(
                path: path,
                reason: "negative decompressed byte count"
            )
        }

        let (nextFileBytes, fileOverflow) = fileBytes.addingReportingOverflow(byteCount)
        guard !fileOverflow, nextFileBytes <= fileLimit else {
            throw SkinArchiveError.decompressedSizeExceeded(
                path: path,
                actual: fileOverflow ? Int.max : nextFileBytes,
                limit: fileLimit
            )
        }

        let (nextTotalBytes, totalOverflow) = totalBytes.addingReportingOverflow(byteCount)
        guard !totalOverflow, nextTotalBytes <= SkinArchiveLimits.uncompressedByteCount else {
            throw SkinArchiveError.decompressedSizeExceeded(
                path: path,
                actual: totalOverflow ? Int.max : nextTotalBytes,
                limit: SkinArchiveLimits.uncompressedByteCount
            )
        }

        totalBytes = nextTotalBytes
        return nextFileBytes
    }
}
