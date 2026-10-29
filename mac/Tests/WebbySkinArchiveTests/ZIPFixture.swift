import Foundation

struct ZIPFixtureEntry {
    let path: String
    let contents: [UInt8]
    let flags: UInt16
    let method: UInt16
    let versionMadeBy: UInt16
    let externalAttributes: UInt32
    let centralExtra: [UInt8]
    let localExtra: [UInt8]
    let localPath: String?
    let localFlags: UInt16?
    let localMethod: UInt16?
    let crc32: UInt32?
    let compressedSize: UInt32?
    let uncompressedSize: UInt32?
    let localHeaderOffset: UInt32?
    let localSignature: UInt32
    let localCRC32: UInt32?
    let localCompressedSize: UInt32?
    let localUncompressedSize: UInt32?
    let diskStart: UInt16
    let pathBytes: [UInt8]?
    let localPathBytes: [UInt8]?

    init(
        path: String,
        contents: [UInt8] = [],
        flags: UInt16 = 0x0800,
        method: UInt16 = 0,
        versionMadeBy: UInt16 = 0x0314,
        externalAttributes: UInt32 = UInt32(0o100644) << 16,
        centralExtra: [UInt8] = [],
        localExtra: [UInt8] = [],
        localPath: String? = nil,
        localFlags: UInt16? = nil,
        localMethod: UInt16? = nil,
        crc32: UInt32? = nil,
        compressedSize: UInt32? = nil,
        uncompressedSize: UInt32? = nil,
        localHeaderOffset: UInt32? = nil,
        localSignature: UInt32 = 0x0403_4B50,
        localCRC32: UInt32? = nil,
        localCompressedSize: UInt32? = nil,
        localUncompressedSize: UInt32? = nil,
        diskStart: UInt16 = 0,
        pathBytes: [UInt8]? = nil,
        localPathBytes: [UInt8]? = nil
    ) {
        self.path = path
        self.contents = contents
        self.flags = flags
        self.method = method
        self.versionMadeBy = versionMadeBy
        self.externalAttributes = externalAttributes
        self.centralExtra = centralExtra
        self.localExtra = localExtra
        self.localPath = localPath
        self.localFlags = localFlags
        self.localMethod = localMethod
        self.crc32 = crc32
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
        self.localHeaderOffset = localHeaderOffset
        self.localSignature = localSignature
        self.localCRC32 = localCRC32
        self.localCompressedSize = localCompressedSize
        self.localUncompressedSize = localUncompressedSize
        self.diskStart = diskStart
        self.pathBytes = pathBytes
        self.localPathBytes = localPathBytes
    }

    static func directory(_ path: String) -> ZIPFixtureEntry {
        ZIPFixtureEntry(
            path: path,
            versionMadeBy: 0x0314,
            externalAttributes: UInt32(0o040755) << 16
        )
    }
}

enum ZIPFixture {
    static func make(
        entries: [ZIPFixtureEntry],
        comment: [UInt8] = [],
        diskNumber: UInt16 = 0,
        centralDisk: UInt16 = 0,
        entriesOnDisk: UInt16? = nil,
        totalEntries: UInt16? = nil,
        centralSize: UInt32? = nil,
        centralOffset: UInt32? = nil,
        commentLength: UInt16? = nil
    ) -> Data {
        var bytes: [UInt8] = []
        var records: [(entry: ZIPFixtureEntry, offset: UInt32)] = []

        for entry in entries {
            let localOffset = UInt32(bytes.count)
            bytes.append(contentsOf: localHeaderBytes(for: entry))
            bytes.append(contentsOf: entry.contents)
            if entry.flags & 0x0008 != 0 {
                appendU32(0x0807_4B50, to: &bytes)
                appendU32(entry.crc32 ?? crc32(entry.contents), to: &bytes)
                appendU32(
                    entry.compressedSize ?? UInt32(entry.contents.count),
                    to: &bytes
                )
                appendU32(
                    entry.uncompressedSize ?? UInt32(entry.contents.count),
                    to: &bytes
                )
            }

            records.append((
                entry: entry,
                offset: entry.localHeaderOffset ?? localOffset
            ))
        }

        let centralStart = UInt32(bytes.count)
        for record in records {
            let entry = record.entry
            let pathBytes = entry.pathBytes ?? Array(entry.path.utf8)
            let crc = entry.crc32 ?? crc32(entry.contents)
            let compressedSize = entry.compressedSize ?? UInt32(entry.contents.count)
            let uncompressedSize = entry.uncompressedSize ?? UInt32(entry.contents.count)

            appendU32(0x0201_4B50, to: &bytes)
            appendU16(entry.versionMadeBy, to: &bytes)
            appendU16(20, to: &bytes)
            appendU16(entry.flags, to: &bytes)
            appendU16(entry.method, to: &bytes)
            appendU16(0, to: &bytes)
            appendU16(0, to: &bytes)
            appendU32(crc, to: &bytes)
            appendU32(compressedSize, to: &bytes)
            appendU32(uncompressedSize, to: &bytes)
            appendU16(UInt16(pathBytes.count), to: &bytes)
            appendU16(UInt16(entry.centralExtra.count), to: &bytes)
            appendU16(0, to: &bytes)
            appendU16(entry.diskStart, to: &bytes)
            appendU16(0, to: &bytes)
            appendU32(entry.externalAttributes, to: &bytes)
            appendU32(record.offset, to: &bytes)
            bytes.append(contentsOf: pathBytes)
            bytes.append(contentsOf: entry.centralExtra)
        }

        let centralEnd = UInt32(bytes.count)
        let directorySize = centralEnd - centralStart

        appendU32(0x0605_4B50, to: &bytes)
        appendU16(diskNumber, to: &bytes)
        appendU16(centralDisk, to: &bytes)
        appendU16(entriesOnDisk ?? UInt16(entries.count), to: &bytes)
        appendU16(totalEntries ?? UInt16(entries.count), to: &bytes)
        appendU32(centralSize ?? directorySize, to: &bytes)
        appendU32(centralOffset ?? centralStart, to: &bytes)
        appendU16(commentLength ?? UInt16(comment.count), to: &bytes)
        bytes.append(contentsOf: comment)

        return Data(bytes)
    }

    /// A local file header with no payload, so a test can place one inside another
    /// entry's declared data range and check overlap detection.
    static func localHeaderBytes(for entry: ZIPFixtureEntry) -> [UInt8] {
        let pathBytes = entry.localPathBytes
            ?? entry.pathBytes
            ?? Array((entry.localPath ?? entry.path).utf8)
        let crc = entry.localCRC32
            ?? entry.crc32
            ?? crc32(entry.contents)
        let compressedSize = entry.localCompressedSize
            ?? entry.compressedSize
            ?? UInt32(entry.contents.count)
        let uncompressedSize = entry.localUncompressedSize
            ?? entry.uncompressedSize
            ?? UInt32(entry.contents.count)

        var bytes: [UInt8] = []
        appendU32(entry.localSignature, to: &bytes)
        appendU16(20, to: &bytes)
        appendU16(entry.localFlags ?? entry.flags, to: &bytes)
        appendU16(entry.localMethod ?? entry.method, to: &bytes)
        appendU16(0, to: &bytes)
        appendU16(0, to: &bytes)
        appendU32(crc, to: &bytes)
        appendU32(compressedSize, to: &bytes)
        appendU32(uncompressedSize, to: &bytes)
        appendU16(UInt16(pathBytes.count), to: &bytes)
        appendU16(UInt16(entry.localExtra.count), to: &bytes)
        bytes.append(contentsOf: pathBytes)
        bytes.append(contentsOf: entry.localExtra)
        return bytes
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func findSignature(
        _ signature: UInt32,
        in data: Data,
        occurrence: Int = 0
    ) -> Int? {
        let haystack = [UInt8](data)
        guard haystack.count >= 4 else {
            return nil
        }
        let needle = u32Bytes(signature)
        var found = 0
        for offset in 0...(haystack.count - 4) {
            if Array(haystack[offset..<(offset + 4)]) == needle {
                if found == occurrence {
                    return offset
                }
                found += 1
            }
        }
        return nil
    }

    static func patch(_ data: Data, at offset: Int, with replacement: [UInt8]) -> Data {
        var bytes = [UInt8](data)
        for (index, byte) in replacement.enumerated() {
            bytes[offset + index] = byte
        }
        return Data(bytes)
    }

    static func u16Bytes(_ value: UInt16) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
        ]
    }

    static func u32Bytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }

    private static func appendU16(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(contentsOf: u16Bytes(value))
    }

    private static func appendU32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(contentsOf: u32Bytes(value))
    }
}
