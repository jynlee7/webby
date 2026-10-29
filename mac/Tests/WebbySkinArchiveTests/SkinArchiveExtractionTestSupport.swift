import Foundation
import ZIPFoundation
@testable import WebbySkinArchive

/// Owns a unique temporary directory and counts calls to the injected staging factory.
final class StagedExtractionHarness: @unchecked Sendable {
    let parent: URL
    private(set) var factoryCalls = 0
    private(set) var createdRoots: [URL] = []

    init() throws {
        parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WebbySkinArchiveExtractionTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false
        )
    }

    var environment: SkinArchiveExtractionEnvironment {
        SkinArchiveExtractionEnvironment(
            fileManager: .default,
            makeStagingDirectory: { [self] appropriateURL in
                factoryCalls += 1
                let root = parent.appendingPathComponent(
                    String(format: "staging-%03d", factoryCalls),
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: root,
                    withIntermediateDirectories: false
                )
                createdRoots.append(root)
                return root
            }
        )
    }

    func extract(_ data: Data) throws -> StagedSkinArchive {
        try SkinArchiveExtractor.extract(
            data,
            stagingNear: parent,
            environment: environment
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: parent)
    }
}

struct StreamingZIPEntry {
    let path: String
    let actualByteCount: Int
    let declaredByteCount: UInt32
}

enum StreamingZIPFixtureError: Error {
    case archiveDataUnavailable
    case malformedArchive
}

/// Builds a deflated ZIP with an in-memory streaming provider. Only compressed
/// output is retained, so a 100 MB zero stream never materializes as 100 MB of
/// memory. The declared uncompressed sizes are then forged in both the local
/// header and the central directory so preflight admits a highly compressed entry.
enum StreamingZIPFixture {
    static func make(entries: [StreamingZIPEntry]) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        for entry in entries {
            try archive.addEntry(
                with: entry.path,
                type: .file,
                uncompressedSize: Int64(entry.actualByteCount),
                modificationDate: Date(timeIntervalSince1970: 0),
                permissions: 0o644,
                compressionMethod: .deflate,
                bufferSize: 64 * 1024,
                provider: { _, size in Data(count: size) }
            )
        }

        guard let data = archive.data else {
            throw StreamingZIPFixtureError.archiveDataUnavailable
        }

        let bytes = [UInt8](data)
        guard bytes.count >= 22 else {
            throw StreamingZIPFixtureError.malformedArchive
        }
        let eocd = bytes.count - 22
        guard readU32(bytes, eocd) == 0x0605_4B50,
              let count = readU16(bytes, eocd + 10),
              let centralOffset = readU32(bytes, eocd + 16)
        else {
            throw StreamingZIPFixtureError.malformedArchive
        }

        let declaredSizes = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.path, $0.declaredByteCount) }
        )
        var result = data
        var offset = centralOffset

        for _ in 0..<count {
            guard let nameLength = readU16(bytes, offset + 28),
                  let extraLength = readU16(bytes, offset + 30),
                  let commentLength = readU16(bytes, offset + 32),
                  let localOffset = readU32(bytes, offset + 42)
            else {
                throw StreamingZIPFixtureError.malformedArchive
            }

            let nameStart = offset + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= bytes.count, localOffset + 26 <= bytes.count else {
                throw StreamingZIPFixtureError.malformedArchive
            }
            let path = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
            if let declared = declaredSizes[path] {
                // Central directory uncompressed size.
                result = ZIPFixture.patch(
                    result,
                    at: offset + 24,
                    with: ZIPFixture.u32Bytes(declared)
                )
                // Local file header uncompressed size.
                result = ZIPFixture.patch(
                    result,
                    at: localOffset + 22,
                    with: ZIPFixture.u32Bytes(declared)
                )
            }

            offset = nameEnd + extraLength + commentLength
        }

        return result
    }

    private static func readU16(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= bytes.count else {
            return nil
        }
        return Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }

    private static func readU32(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= bytes.count else {
            return nil
        }
        return Int(bytes[offset])
            | (Int(bytes[offset + 1]) << 8)
            | (Int(bytes[offset + 2]) << 16)
            | (Int(bytes[offset + 3]) << 24)
    }
}
