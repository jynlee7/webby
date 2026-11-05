import Foundation

/// One central-directory record after structural validation.
struct SkinArchiveCentralDirectoryEntry {
    let rawPath: String
    let generalPurposeFlags: UInt16
    let compressionMethod: UInt16
    let crc32: UInt32
    let compressedSize: UInt32
    let uncompressedSize: UInt32
    let localHeaderOffset: UInt32
    let isDirectory: Bool
    let storageRange: Range<Int>
}

/// A bounded reader for the ordinary, non-ZIP64 central directory of one archive.
///
/// It parses every central record before returning, checks the matching local
/// headers, and rejects ZIP64 and multi-disk layouts. It accepts no URL and performs
/// no filesystem access.
enum SkinArchiveCentralDirectoryReader {
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let zip64EndOfCentralDirectoryLocatorSignature: UInt32 = 0x0706_4B50
    private static let centralDirectoryEntrySignature: UInt32 = 0x0201_4B50
    private static let localFileHeaderSignature: UInt32 = 0x0403_4B50
    private static let dataDescriptorSignature: UInt32 = 0x0807_4B50
    private static let zip64ExtraFieldID: UInt16 = 0x0001

    static func read(_ data: Data) throws -> [SkinArchiveCentralDirectoryEntry] {
        guard data.count <= SkinArchiveLimits.archiveByteCount else {
            throw SkinArchiveError.archiveTooLarge(
                actual: data.count,
                limit: SkinArchiveLimits.archiveByteCount
            )
        }

        let reader = ByteReader(bytes: [UInt8](data))
        let eocdOffset = try locateEndOfCentralDirectory(reader)

        guard
            let diskNumber = reader.u16(eocdOffset + 4),
            let centralDisk = reader.u16(eocdOffset + 6),
            let entriesOnDisk = reader.u16(eocdOffset + 8),
            let totalEntries = reader.u16(eocdOffset + 10),
            let centralSize = reader.u32(eocdOffset + 12),
            let centralOffset = reader.u32(eocdOffset + 16)
        else {
            throw SkinArchiveError.malformedArchive(reason: "end of central directory is truncated")
        }

        if totalEntries == UInt16.max
            || centralSize == UInt32.max
            || centralOffset == UInt32.max
            || diskNumber == UInt16.max
            || centralDisk == UInt16.max {
            throw SkinArchiveError.zip64Unsupported(path: nil)
        }
        if diskNumber != 0 || centralDisk != 0 || entriesOnDisk != totalEntries {
            throw SkinArchiveError.multiDiskUnsupported
        }
        if eocdOffset >= 20,
           reader.u32(eocdOffset - 20) == zip64EndOfCentralDirectoryLocatorSignature {
            throw SkinArchiveError.zip64Unsupported(path: nil)
        }

        let count = Int(totalEntries)
        guard count <= SkinArchiveLimits.entryCount else {
            throw SkinArchiveError.entryCountExceeded(
                count: count,
                limit: SkinArchiveLimits.entryCount
            )
        }

        let directoryStart = Int(centralOffset)
        let directorySize = Int(centralSize)
        guard directoryStart <= eocdOffset,
              directorySize <= eocdOffset - directoryStart,
              directoryStart + directorySize == eocdOffset
        else {
            throw SkinArchiveError.malformedArchive(
                reason: "central directory does not end at the end of central directory"
            )
        }

        let directoryEnd = directoryStart + directorySize
        var entries: [SkinArchiveCentralDirectoryEntry] = []
        entries.reserveCapacity(count)
        var storageRanges: [(path: String, range: Range<Int>)] = []
        var declaredUncompressedBytes = 0
        var offset = directoryStart

        for _ in 0..<count {
            guard reader.contains(offset, 46),
                  reader.u32(offset) == centralDirectoryEntrySignature
            else {
                throw SkinArchiveError.malformedArchive(
                    reason: "invalid central directory entry at offset \(offset)"
                )
            }

            guard
                let versionMadeBy = reader.u16(offset + 4),
                let flags = reader.u16(offset + 8),
                let method = reader.u16(offset + 10),
                let crc32 = reader.u32(offset + 16),
                let compressedSize = reader.u32(offset + 20),
                let uncompressedSize = reader.u32(offset + 24),
                let nameLength = reader.u16(offset + 28),
                let extraLength = reader.u16(offset + 30),
                let commentLength = reader.u16(offset + 32),
                let diskStart = reader.u16(offset + 34),
                let externalAttributes = reader.u32(offset + 38),
                let localHeaderOffset = reader.u32(offset + 42)
            else {
                throw SkinArchiveError.malformedArchive(
                    reason: "central directory entry is truncated at offset \(offset)"
                )
            }

            let fixedEnd = offset + 46
            guard Int(nameLength) <= directoryEnd - fixedEnd else {
                throw SkinArchiveError.malformedArchive(
                    reason: "central directory entry name crosses the directory boundary"
                )
            }
            let nameEnd = fixedEnd + Int(nameLength)
            guard Int(extraLength) <= directoryEnd - nameEnd else {
                throw SkinArchiveError.malformedArchive(
                    reason: "central directory entry extra data crosses the directory boundary"
                )
            }
            let extraEnd = nameEnd + Int(extraLength)
            guard Int(commentLength) <= directoryEnd - extraEnd else {
                throw SkinArchiveError.malformedArchive(
                    reason: "central directory entry comment crosses the directory boundary"
                )
            }
            let recordEnd = extraEnd + Int(commentLength)

            let nameBytes = Array(reader.bytes[fixedEnd..<nameEnd])
            let rawPath = try decodePath(nameBytes, flags: flags)

            if flags & 0x0001 != 0 || flags & 0x0040 != 0 || flags & 0x2000 != 0 {
                throw SkinArchiveError.encryptedEntry(path: rawPath)
            }
            guard method == 0 || method == 8 else {
                throw SkinArchiveError.unsupportedCompression(method: method, path: rawPath)
            }
            if compressedSize == UInt32.max
                || uncompressedSize == UInt32.max
                || localHeaderOffset == UInt32.max {
                throw SkinArchiveError.zip64Unsupported(path: rawPath)
            }
            if diskStart == UInt16.max {
                throw SkinArchiveError.zip64Unsupported(path: rawPath)
            }
            if diskStart != 0 {
                throw SkinArchiveError.multiDiskUnsupported
            }

            try inspectExtraFields(
                reader.bytes,
                start: nameEnd,
                end: extraEnd,
                path: rawPath
            )

            let isDirectory = try entryIsDirectory(
                rawPath: rawPath,
                versionMadeBy: versionMadeBy,
                externalAttributes: externalAttributes
            )
            try validateRawPath(rawPath, isDirectory: isDirectory)
            let storageRange = try validateLocalHeader(
                reader,
                centralNameBytes: nameBytes,
                flags: flags,
                method: method,
                crc32: crc32,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                path: rawPath,
                localHeaderOffset: localHeaderOffset,
                directoryStart: directoryStart
            )
            if let existing = storageRanges.first(where: { $0.range.overlaps(storageRange) }) {
                throw SkinArchiveError.malformedArchive(
                    reason: "local storage for '\(rawPath)' overlaps '\(existing.path)'"
                )
            }
            storageRanges.append((rawPath, storageRange))

            let (newTotal, totalOverflow) = declaredUncompressedBytes.addingReportingOverflow(
                Int(uncompressedSize)
            )
            guard !totalOverflow,
                  newTotal <= SkinArchiveLimits.uncompressedByteCount
            else {
                throw SkinArchiveError.declaredSizeExceeded(
                    path: nil,
                    declared: totalOverflow ? UInt64.max : UInt64(newTotal),
                    limit: SkinArchiveLimits.uncompressedByteCount
                )
            }
            declaredUncompressedBytes = newTotal

            entries.append(SkinArchiveCentralDirectoryEntry(
                rawPath: rawPath,
                generalPurposeFlags: flags,
                compressionMethod: method,
                crc32: crc32,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset,
                isDirectory: isDirectory,
                storageRange: storageRange
            ))
            offset = recordEnd
        }

        guard offset == directoryEnd else {
            throw SkinArchiveError.malformedArchive(
                reason: "central directory entry count does not match its declared size"
            )
        }

        return entries
    }

    // MARK: - End of central directory

    private static func locateEndOfCentralDirectory(_ reader: ByteReader) throws -> Int {
        let count = reader.bytes.count
        guard count >= 22 else {
            throw SkinArchiveError.malformedArchive(
                reason: "end of central directory is missing or truncated"
            )
        }

        let lowerBound = max(0, count - 22 - Int(UInt16.max))
        var candidates: [Int] = []
        var offset = count - 22
        while offset >= lowerBound {
            if reader.u32(offset) == endOfCentralDirectorySignature,
               let commentLength = reader.u16(offset + 20),
               offset + 22 + Int(commentLength) == count {
                candidates.append(offset)
            }
            offset -= 1
        }

        guard candidates.count == 1, let candidate = candidates.first else {
            let reason = candidates.isEmpty
                ? "end of central directory is missing or truncated"
                : "multiple end of central directory records are plausible"
            throw SkinArchiveError.malformedArchive(reason: reason)
        }
        return candidate
    }

    // MARK: - Entry validation

    private static func decodePath(_ bytes: [UInt8], flags: UInt16) throws -> String {
        let data = Data(bytes)
        if flags & 0x0800 != 0 {
            guard let path = String(data: data, encoding: .utf8) else {
                throw SkinArchiveError.malformedArchive(
                    reason: "entry name is not valid UTF-8"
                )
            }
            return path
        }

        guard bytes.allSatisfy({ $0 < 0x80 }),
              let path = String(data: data, encoding: .ascii)
        else {
            throw SkinArchiveError.malformedArchive(
                reason: "legacy entry name is not ASCII"
            )
        }
        return path
    }

    private static func entryIsDirectory(
        rawPath: String,
        versionMadeBy: UInt16,
        externalAttributes: UInt32
    ) throws -> Bool {
        let creatorSystem = UInt8(truncatingIfNeeded: versionMadeBy >> 8)
        if creatorSystem == 3 {
            let mode = externalAttributes >> 16
            switch mode & 0xF000 {
            case 0xA000:
                throw SkinArchiveError.unsupportedEntryType(
                    path: rawPath,
                    reason: "symbolic link"
                )
            case 0x4000:
                return true
            case 0x8000:
                return false
            case 0:
                return rawPath.hasSuffix("/") || (externalAttributes & 0x10) != 0
            default:
                throw SkinArchiveError.unsupportedEntryType(
                    path: rawPath,
                    reason: "non-file entry type"
                )
            }
        }

        return rawPath.hasSuffix("/") || (externalAttributes & 0x10) != 0
    }

    private static func validateRawPath(_ rawPath: String, isDirectory: Bool) throws {
        guard !rawPath.isEmpty else {
            throw SkinArchiveError.unsafeEntryPath(path: rawPath, reason: "empty path")
        }
        guard !rawPath.contains("\0") else {
            throw SkinArchiveError.unsafeEntryPath(path: rawPath, reason: "NUL byte")
        }
        guard !rawPath.contains("\\") else {
            throw SkinArchiveError.unsafeEntryPath(path: rawPath, reason: "backslash")
        }
        guard !rawPath.unicodeScalars.contains(where: isUnsafeControl) else {
            throw SkinArchiveError.unsafeEntryPath(path: rawPath, reason: "control character")
        }
        guard !rawPath.hasPrefix("/") else {
            throw SkinArchiveError.unsafeEntryPath(path: rawPath, reason: "absolute path")
        }
        guard !hasDrivePrefix(rawPath) else {
            throw SkinArchiveError.unsafeEntryPath(path: rawPath, reason: "drive prefix")
        }

        var path = rawPath
        if isDirectory && path.hasSuffix("/") {
            path.removeLast()
        }
        guard !path.isEmpty else {
            throw SkinArchiveError.unsafeEntryPath(path: rawPath, reason: "empty path")
        }
        if !isDirectory && rawPath.hasSuffix("/") {
            throw SkinArchiveError.unsafeEntryPath(
                path: rawPath,
                reason: "file path ends with a separator"
            )
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains(where: { $0.isEmpty }) {
            throw SkinArchiveError.unsafeEntryPath(
                path: rawPath,
                reason: "empty path component"
            )
        }
        if components.contains(where: { $0 == "." }) {
            throw SkinArchiveError.unsafeEntryPath(
                path: rawPath,
                reason: "dot path component"
            )
        }
        if components.contains(where: { $0 == ".." }) {
            throw SkinArchiveError.unsafeEntryPath(
                path: rawPath,
                reason: "path traversal"
            )
        }
    }

    private static func isUnsafeControl(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.controlCharacters.contains(scalar) {
            return true
        }
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        default:
            return false
        }
    }

    private static func hasDrivePrefix(_ path: String) -> Bool {
        let scalars = Array(path.unicodeScalars)
        guard scalars.count >= 2, scalars[1] == ":" else {
            return false
        }
        let first = scalars[0].value
        return (0x41...0x5A).contains(first) || (0x61...0x7A).contains(first)
    }

    private static func inspectExtraFields(
        _ bytes: [UInt8],
        start: Int,
        end: Int,
        path: String
    ) throws {
        var offset = start
        while offset < end {
            guard end - offset >= 4 else {
                throw SkinArchiveError.malformedArchive(
                    reason: "extra field header is truncated for '\(path)'"
                )
            }

            let fieldID = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            let fieldSize = Int(
                UInt16(bytes[offset + 2]) | (UInt16(bytes[offset + 3]) << 8)
            )
            guard fieldSize <= end - offset - 4 else {
                throw SkinArchiveError.malformedArchive(
                    reason: "extra field payload is truncated for '\(path)'"
                )
            }
            if fieldID == zip64ExtraFieldID {
                throw SkinArchiveError.zip64Unsupported(path: path)
            }
            offset += 4 + fieldSize
        }
    }

    private static func validateLocalHeader(
        _ reader: ByteReader,
        centralNameBytes: [UInt8],
        flags: UInt16,
        method: UInt16,
        crc32: UInt32,
        compressedSize: UInt32,
        uncompressedSize: UInt32,
        path: String,
        localHeaderOffset: UInt32,
        directoryStart: Int
    ) throws -> Range<Int> {
        let start = Int(localHeaderOffset)
        guard start <= directoryStart,
              directoryStart - start >= 30,
              reader.contains(start, 30),
              reader.u32(start) == localFileHeaderSignature
        else {
            throw SkinArchiveError.malformedArchive(
                reason: "local file header is missing or truncated for '\(path)'"
            )
        }

        guard
            let localFlags = reader.u16(start + 6),
            let localMethod = reader.u16(start + 8),
            let localCRC32 = reader.u32(start + 14),
            let localCompressedSize = reader.u32(start + 18),
            let localUncompressedSize = reader.u32(start + 22),
            let nameLength = reader.u16(start + 26),
            let extraLength = reader.u16(start + 28)
        else {
            throw SkinArchiveError.malformedArchive(
                reason: "local file header is truncated for '\(path)'"
            )
        }

        let nameStart = start + 30
        guard Int(nameLength) <= directoryStart - nameStart else {
            throw SkinArchiveError.malformedArchive(
                reason: "local file header name crosses the central directory boundary"
            )
        }
        let nameEnd = nameStart + Int(nameLength)
        guard Int(extraLength) <= directoryStart - nameEnd else {
            throw SkinArchiveError.malformedArchive(
                reason: "local file header extra data crosses the central directory boundary"
            )
        }
        let extraEnd = nameEnd + Int(extraLength)
        guard Int(compressedSize) <= directoryStart - extraEnd else {
            throw SkinArchiveError.malformedArchive(
                reason: "compressed data crosses the central directory boundary for '\(path)'"
            )
        }
        let dataEnd = extraEnd + Int(compressedSize)

        guard Array(reader.bytes[nameStart..<nameEnd]) == centralNameBytes else {
            throw SkinArchiveError.malformedArchive(
                reason: "local header path differs from central directory path for '\(path)'"
            )
        }
        if localFlags != flags || localMethod != method {
            throw SkinArchiveError.malformedArchive(
                reason: "local header flags or method differ from the central directory for '\(path)'"
            )
        }
        let usesDataDescriptor = flags & 0x0008 != 0
        if !usesDataDescriptor,
           (localCRC32 != crc32
            || localCompressedSize != compressedSize
            || localUncompressedSize != uncompressedSize) {
            throw SkinArchiveError.malformedArchive(
                reason: "local header CRC or sizes differ from the central directory for '\(path)'"
            )
        }

        try inspectExtraFields(
            reader.bytes,
            start: nameEnd,
            end: extraEnd,
            path: path
        )

        let storageEnd: Int
        if usesDataDescriptor {
            storageEnd = try validateDataDescriptor(
                reader,
                start: dataEnd,
                crc32: crc32,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                path: path,
                directoryStart: directoryStart
            )
        } else {
            storageEnd = dataEnd
        }
        return start..<storageEnd
    }

    private static func validateDataDescriptor(
        _ reader: ByteReader,
        start: Int,
        crc32: UInt32,
        compressedSize: UInt32,
        uncompressedSize: UInt32,
        path: String,
        directoryStart: Int
    ) throws -> Int {
        guard start <= directoryStart, directoryStart - start >= 12 else {
            throw SkinArchiveError.malformedArchive(
                reason: "data descriptor is missing or truncated for '\(path)'"
            )
        }

        if reader.u32(start) == dataDescriptorSignature,
           directoryStart - start >= 16,
           reader.u32(start + 4) == crc32,
           reader.u32(start + 8) == compressedSize,
           reader.u32(start + 12) == uncompressedSize {
            return start + 16
        }

        guard reader.u32(start) == crc32,
              reader.u32(start + 4) == compressedSize,
              reader.u32(start + 8) == uncompressedSize
        else {
            throw SkinArchiveError.malformedArchive(
                reason: "data descriptor differs from the central directory for '\(path)'"
            )
        }
        return start + 12
    }
}

/// Bounds-checked little-endian reads over one immutable archive snapshot.
private struct ByteReader {
    let bytes: [UInt8]

    func contains(_ offset: Int, _ count: Int) -> Bool {
        offset >= 0 && count >= 0 && offset <= bytes.count && count <= bytes.count - offset
    }

    func u16(_ offset: Int) -> UInt16? {
        guard contains(offset, 2) else {
            return nil
        }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    func u32(_ offset: Int) -> UInt32? {
        guard contains(offset, 4) else {
            return nil
        }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
