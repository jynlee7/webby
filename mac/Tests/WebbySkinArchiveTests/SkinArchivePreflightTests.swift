import Foundation
import Testing
import WebbySkinArchive

private func file(_ path: String, contents: String = "{}") -> ZIPFixtureEntry {
    ZIPFixtureEntry(path: path, contents: Array(contents.utf8))
}

private func archive(_ entries: [ZIPFixtureEntry]) -> Data {
    ZIPFixture.make(entries: entries)
}

private func preflightError(_ data: Data) -> SkinArchiveError? {
    do {
        _ = try SkinArchivePreflight.check(data)
        return nil
    } catch let error as SkinArchiveError {
        return error
    } catch {
        return nil
    }
}

private func malformedReason(_ data: Data) -> String? {
    guard let error = preflightError(data),
          case .malformedArchive(let reason) = error
    else {
        return nil
    }
    return reason
}

@Test func acceptsRootArchiveAndKeepsCentralOrder() throws {
    let manifest = Array("{\"id\":\"test\"}".utf8)
    let image = Array("png".utf8)
    let result = try SkinArchivePreflight.check(archive([
        ZIPFixtureEntry(path: "skin.json", contents: manifest),
        ZIPFixtureEntry(path: "images/note-body.png", contents: image),
    ]))

    #expect(result.entries.map(\.path) == ["skin.json", "images/note-body.png"])
    #expect(result.entries.map(\.rawPath) == ["skin.json", "images/note-body.png"])
    #expect(result.entries[0].compressionMethod == 0)
    #expect(result.entries[0].compressedSize == UInt32(manifest.count))
    #expect(result.entries[0].uncompressedSize == UInt32(manifest.count))
    #expect(result.entries[0].crc32 == ZIPFixture.crc32(manifest))
    #expect(result.entries[0].localHeaderOffset == 0)
    #expect(result.warnings.isEmpty)
}

@Test func acceptsOneWrapperDirectoryAndStripsIt() throws {
    let result = try SkinArchivePreflight.check(archive([
        file("MySkin/skin.json"),
        file("MySkin/images/note-body.png"),
    ]))

    #expect(result.entries.map(\.path) == ["skin.json", "images/note-body.png"])
    #expect(result.entries.map(\.rawPath) == [
        "MySkin/skin.json",
        "MySkin/images/note-body.png",
    ])
    #expect(result.warnings.isEmpty)
}

@Test func rejectsTraversalInTheFinalCentralEntry() {
    let data = archive([
        file("skin.json"),
        file("images/note-body.png"),
        file("../evil.png"),
    ])

    #expect(preflightError(data) == .unsafeEntryPath(
        path: "../evil.png",
        reason: "path traversal"
    ))
}

@Test func rejectsUnsafeRawPathShapes() {
    let cases: [(path: String, reason: String)] = [
        ("/absolute.png", "absolute path"),
        ("C:/drive.png", "drive prefix"),
        ("images\\evil.png", "backslash"),
        ("images/evil\0.png", "NUL byte"),
        ("images/./evil.png", "dot path component"),
        ("images//evil.png", "empty path component"),
        ("images/../evil.png", "path traversal"),
    ]

    for testCase in cases {
        let error = preflightError(archive([
            file("skin.json"),
            file(testCase.path),
        ]))
        #expect(error == .unsafeEntryPath(
            path: testCase.path,
            reason: testCase.reason
        ))
    }
}

@Test func rejectsExactDuplicateRawNames() {
    let error = preflightError(archive([
        file("skin.json"),
        file("images/note-body.png"),
        file("images/note-body.png"),
    ]))

    #expect(error == .duplicateEntry(path: "images/note-body.png"))
}

@Test func rejectsNFCAndCaseCollisions() {
    let nfcError = preflightError(archive([
        file("skin.json"),
        file("images/caf\u{00E9}.png"),
        file("images/cafe\u{0301}.png"),
    ]))
    #expect(nfcError == .collidingEntry(
        path: "images/cafe\u{0301}.png",
        existing: "images/caf\u{00E9}.png"
    ))

    let caseError = preflightError(archive([
        file("skin.json"),
        file("images/note-body.png"),
        file("images/NOTE-BODY.png"),
    ]))
    #expect(caseError == .collidingEntry(
        path: "images/NOTE-BODY.png",
        existing: "images/note-body.png"
    ))
}

@Test func rejectsEncryptedEntries() {
    let error = preflightError(archive([
        file("skin.json"),
        ZIPFixtureEntry(path: "encrypted.bin", flags: 0x0801),
    ]))

    #expect(error == .encryptedEntry(path: "encrypted.bin"))
}

@Test func rejectsUnixSymlinksAndUnsupportedTypes() {
    let symlink = ZIPFixtureEntry(
        path: "link",
        versionMadeBy: 0x0314,
        externalAttributes: UInt32(0o120777) << 16
    )
    #expect(preflightError(archive([file("skin.json"), symlink])) == .unsupportedEntryType(
        path: "link",
        reason: "symbolic link"
    ))

    let fifo = ZIPFixtureEntry(
        path: "pipe",
        versionMadeBy: 0x0314,
        externalAttributes: UInt32(0o010644) << 16
    )
    #expect(preflightError(archive([file("skin.json"), fifo])) == .unsupportedEntryType(
        path: "pipe",
        reason: "non-file entry type"
    ))
}

@Test func rejectsUnsupportedCompression() {
    let error = preflightError(archive([
        ZIPFixtureEntry(path: "skin.json", method: 12),
    ]))

    #expect(error == .unsupportedCompression(method: 12, path: "skin.json"))
}

@Test func skipsMacMetadataAndDSStoreSilently() throws {
    let result = try SkinArchivePreflight.check(archive([
        file("skin.json"),
        file("__MACOSX/._skin.json"),
        file(".DS_Store"),
    ]))

    #expect(result.entries.map(\.path) == ["skin.json"])
    #expect(result.warnings.isEmpty)

    let wrapped = try SkinArchivePreflight.check(archive([
        file("__MACOSX/._skin.json"),
        file(".DS_Store"),
        file("MySkin/skin.json"),
    ]))
    #expect(wrapped.entries.map(\.path) == ["skin.json"])
    #expect(wrapped.warnings.isEmpty)
}

@Test func warnsAndSkipsHarmlessUnknownFiles() throws {
    let result = try SkinArchivePreflight.check(archive([
        file("skin.json"),
        file("notes.txt"),
    ]))

    #expect(result.entries.map(\.path) == ["skin.json"])
    #expect(result.warnings.count == 1)
    #expect(result.warnings[0].code == "entry-skipped")
    #expect(result.warnings[0].severity == .warning)
    #expect(result.warnings[0].assetPath == "notes.txt")
}

@Test func countsEveryEntryIncludingDirectories() throws {
    var entries = [file("skin.json")]
    for index in 0..<399 {
        entries.append(.directory(String(format: "d%03d/", index)))
    }
    let result = try SkinArchivePreflight.check(archive(entries))
    #expect(result.entries.map(\.path) == ["skin.json"])

    entries.append(.directory("one-too-many/"))
    #expect(preflightError(archive(entries)) == .entryCountExceeded(
        count: 401,
        limit: 400
    ))
}

@Test func requiresExactlyOneLogicalRootManifest() {
    #expect(preflightError(archive([
        file("readme.txt"),
    ])) == .manifestMissing)

    #expect(preflightError(archive([
        file("wrapper/readme.txt"),
    ])) == .manifestMissing)
}

@Test func rejectsAmbiguousWrapperDirectories() {
    let error = preflightError(archive([
        file("A/skin.json"),
        file("B/preview.png"),
    ]))

    #expect(error == .ambiguousWrapper(candidates: ["A", "B"]))
}

@Test func rejectsMalformedAndTruncatedCentralDirectory() {
    let valid = archive([file("skin.json")])
    let central = ZIPFixture.findSignature(0x0201_4B50, in: valid)
    #expect(central != nil)

    if let central {
        let malformed = ZIPFixture.patch(valid, at: central, with: [0, 0, 0, 0])
        guard let error = preflightError(malformed) else {
            Issue.record("expected a malformed archive error")
            return
        }
        guard case .malformedArchive = error else {
            Issue.record("expected malformedArchive, got \(error)")
            return
        }
    }

    let eocd = ZIPFixture.findSignature(0x0605_4B50, in: valid)
    #expect(eocd != nil)
    if let eocd {
        let truncated = ZIPFixture.patch(
            valid,
            at: eocd + 12,
            with: ZIPFixture.u32Bytes(10)
        )
        guard let error = preflightError(truncated) else {
            Issue.record("expected a malformed archive error")
            return
        }
        guard case .malformedArchive = error else {
            Issue.record("expected malformedArchive, got \(error)")
            return
        }
    }

    guard let truncatedEnd = preflightError(Data(valid.dropLast(5))) else {
        Issue.record("expected a malformed archive error")
        return
    }
    guard case .malformedArchive = truncatedEnd else {
        Issue.record("expected malformedArchive, got \(truncatedEnd)")
        return
    }
}

@Test func rejectsLocalHeaderDisagreement() {
    let pathMismatch = preflightError(archive([
        ZIPFixtureEntry(path: "skin.json", localPath: "other.json"),
    ]))
    guard let pathError = pathMismatch else {
        Issue.record("expected a malformed archive error")
        return
    }
    guard case .malformedArchive = pathError else {
        Issue.record("expected malformedArchive, got \(pathError)")
        return
    }

    let flagMismatch = preflightError(archive([
        ZIPFixtureEntry(path: "skin.json", flags: 0x0000, localFlags: 0x0800),
    ]))
    guard let flagError = flagMismatch else {
        Issue.record("expected a malformed archive error")
        return
    }
    guard case .malformedArchive = flagError else {
        Issue.record("expected malformedArchive, got \(flagError)")
        return
    }
}

@Test func rejectsZIP64AndMultiDiskArchives() {
    let valid = archive([file("skin.json")])
    let eocd = ZIPFixture.findSignature(0x0605_4B50, in: valid)
    #expect(eocd != nil)
    if let eocd {
        let sentinel = ZIPFixture.patch(
            valid,
            at: eocd + 12,
            with: ZIPFixture.u32Bytes(UInt32.max)
        )
        #expect(preflightError(sentinel) == .zip64Unsupported(path: nil))
    }

    #expect(preflightError(archive([
        ZIPFixtureEntry(path: "skin.json", centralExtra: [1, 0, 0, 0]),
    ])) == .zip64Unsupported(path: "skin.json"))

    let multiDisk = ZIPFixture.make(entries: [file("skin.json")], diskNumber: 1)
    #expect(preflightError(multiDisk) == .multiDiskUnsupported)
}

@Test func preflightSliceHasNoStagingOrWriteSurface() throws {
    let macDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceDirectory = macDirectory
        .appendingPathComponent("Sources")
        .appendingPathComponent("WebbySkinArchive")

    for fileName in [
        "SkinArchivePreflight.swift",
        "SkinArchiveCentralDirectoryReader.swift",
    ] {
        let source = try String(
            contentsOf: sourceDirectory.appendingPathComponent(fileName),
            encoding: .utf8
        )
        #expect(!source.contains("FileManager"))
        #expect(!source.contains("itemReplacementDirectory"))
        #expect(!source.contains("createDirectory"))
        #expect(!source.contains(".write("))
        #expect(!source.contains("func extract"))
    }
}

@Test func rejectsCompressedDataPastTheCentralDirectory() {
    let data = archive([
        ZIPFixtureEntry(
            path: "skin.json",
            contents: [0x41],
            compressedSize: 200,
            uncompressedSize: 1,
            localCompressedSize: 200,
            localUncompressedSize: 1
        ),
    ])

    #expect(malformedReason(data)?.contains("crosses the central directory") == true)
}

@Test func rejectsOverlappingLocalRanges() {
    // The first local header ends at 30 + "a.bin".count = 35. Its declared
    // 42-byte payload ends at 77 and covers the second local header at 39, which
    // itself ends at 78 before its two-byte payload.
    let first = ZIPFixtureEntry(
        path: "a.bin",
        contents: [1, 2, 3, 4],
        compressedSize: 42,
        uncompressedSize: 4,
        localCompressedSize: 42,
        localUncompressedSize: 4
    )
    let data = archive([first, file("skin.json")])

    #expect(malformedReason(data)?.contains("overlaps") == true)
}

@Test func rejectsLocalCRCAndSizeMismatchesWhenBitThreeIsClear() {
    let crcMismatch = archive([
        ZIPFixtureEntry(path: "skin.json", contents: [1, 2], localCRC32: 0),
    ])
    #expect(malformedReason(crcMismatch)?.contains("CRC or sizes") == true)

    let compressedMismatch = archive([
        ZIPFixtureEntry(path: "skin.json", contents: [1, 2], localCompressedSize: 1),
    ])
    #expect(malformedReason(compressedMismatch)?.contains("CRC or sizes") == true)

    let uncompressedMismatch = archive([
        ZIPFixtureEntry(path: "skin.json", contents: [1, 2], localUncompressedSize: 3),
    ])
    #expect(malformedReason(uncompressedMismatch)?.contains("CRC or sizes") == true)
}

@Test func acceptsZeroSizeLocalPlaceholdersWhenBitThreeIsSet() throws {
    let contents = Array("{\"ok\":true}".utf8)
    let result = try SkinArchivePreflight.check(archive([
        ZIPFixtureEntry(
            path: "skin.json",
            contents: contents,
            flags: 0x0808,
            localCRC32: 0,
            localCompressedSize: 0,
            localUncompressedSize: 0
        ),
    ]))

    #expect(result.entries.map(\.path) == ["skin.json"])
    #expect(result.entries[0].compressedSize == UInt32(contents.count))
}

@Test func rejectsDataDescriptorDisagreement() {
    let valid = archive([
        ZIPFixtureEntry(
            path: "skin.json",
            contents: [1, 2, 3],
            flags: 0x0808,
            localCRC32: 0,
            localCompressedSize: 0,
            localUncompressedSize: 0
        ),
    ])
    guard let descriptor = ZIPFixture.findSignature(0x0807_4B50, in: valid) else {
        Issue.record("fixture has no data descriptor")
        return
    }
    let corrupted = ZIPFixture.patch(
        valid,
        at: descriptor + 4,
        with: ZIPFixture.u32Bytes(0)
    )
    #expect(malformedReason(corrupted)?.contains("data descriptor differs") == true)
}

@Test func boundsDeclaredUncompressedTotalsWithoutAllocatingThem() throws {
    func entry(declared: UInt32) -> ZIPFixtureEntry {
        ZIPFixtureEntry(
            path: "skin.json",
            contents: [0x78],
            compressedSize: 1,
            uncompressedSize: declared,
            localCompressedSize: 1,
            localUncompressedSize: declared
        )
    }

    let exact = try SkinArchivePreflight.check(archive([entry(declared: 64_000_000)]))
    #expect(exact.entries.count == 1)

    #expect(preflightError(archive([entry(declared: 64_000_001)])) == .declaredSizeExceeded(
        path: nil,
        declared: 64_000_001,
        limit: 64_000_000
    ))
}

@Test func rejectsAForgedSecondEndOfCentralDirectoryInTheComment() {
    // A comment can hold a candidate whose own 16-bit comment length reaches the
    // end of the file, which is exactly the plausibility test the reader applies.
    let comment = ZIPFixture.u32Bytes(0x0605_4B50)
        + [UInt8](repeating: 0, count: 16)
        + ZIPFixture.u16Bytes(0)
    let data = ZIPFixture.make(entries: [file("skin.json")], comment: comment)

    #expect(malformedReason(data)?.contains("multiple end of central directory") == true)
}

@Test func rejectsArchivesPastTheByteLimit() {
    let overLimit = Data(count: 25_000_001)
    #expect(preflightError(overLimit) == .archiveTooLarge(
        actual: 25_000_001,
        limit: 25_000_000
    ))

    let boundary = Data(count: 25_000_000)
    if case .archiveTooLarge? = preflightError(boundary) {
        Issue.record("the exact archive byte limit must not report archiveTooLarge")
    }
}

@Test func rejectsBadLocalSignaturesAndOffsets() {
    let badSignature = archive([
        ZIPFixtureEntry(path: "skin.json", localSignature: 0xDEAD_BEEF),
    ])
    #expect(malformedReason(badSignature)?.contains("local file header") == true)

    let badOffset = archive([
        ZIPFixtureEntry(path: "skin.json", localHeaderOffset: 1_000_000),
    ])
    #expect(malformedReason(badOffset)?.contains("local file header") == true)
}

@Test func rejectsEntriesOnDiskMismatch() {
    let data = ZIPFixture.make(entries: [file("skin.json")], entriesOnDisk: 2)

    #expect(preflightError(data) == .multiDiskUnsupported)
}

@Test func rejectsPerEntryDiskStart() {
    #expect(preflightError(archive([
        ZIPFixtureEntry(path: "skin.json", diskStart: 1),
    ])) == .multiDiskUnsupported)

    #expect(preflightError(archive([
        ZIPFixtureEntry(path: "skin.json", diskStart: UInt16.max),
    ])) == .zip64Unsupported(path: "skin.json"))
}

@Test func rejectsZIP64LocatorAndLocalZIP64ExtraField() {
    let valid = archive([file("skin.json")])
    guard let eocd = ZIPFixture.findSignature(0x0605_4B50, in: valid), eocd >= 20 else {
        Issue.record("fixture archive has no usable end of central directory")
        return
    }
    let withLocator = ZIPFixture.patch(
        valid,
        at: eocd - 20,
        with: ZIPFixture.u32Bytes(0x0706_4B50)
    )
    #expect(preflightError(withLocator) == .zip64Unsupported(path: nil))

    #expect(preflightError(archive([
        ZIPFixtureEntry(path: "skin.json", localExtra: [1, 0, 0, 0]),
    ])) == .zip64Unsupported(path: "skin.json"))
}

@Test func acceptsLegacyASCIIAndRejectsInvalidLegacyOrUTF8Names() throws {
    let legacy = try SkinArchivePreflight.check(archive([
        ZIPFixtureEntry(path: "skin.json", flags: 0x0000),
    ]))
    #expect(legacy.entries.map(\.path) == ["skin.json"])

    let nonASCII = archive([
        ZIPFixtureEntry(path: "skin.json", flags: 0x0000, pathBytes: [0xFF]),
    ])
    #expect(malformedReason(nonASCII)?.contains("ASCII") == true)

    let invalidUTF8 = archive([
        ZIPFixtureEntry(path: "skin.json", flags: 0x0800, pathBytes: [0xC3, 0x28]),
    ])
    #expect(malformedReason(invalidUTF8)?.contains("UTF-8") == true)
}

@Test func acceptsBoundedDeflateMethod() throws {
    // Fake deflate bytes are bounded by the declared compressed size; preflight
    // admits the method without decompressing the payload.
    let payload: [UInt8] = [0x03, 0x00, 0x00, 0x00, 0x00]
    let result = try SkinArchivePreflight.check(archive([
        ZIPFixtureEntry(path: "skin.json", contents: payload, method: 8),
    ]))

    #expect(result.entries.map(\.path) == ["skin.json"])
    #expect(result.entries[0].compressionMethod == 8)
    #expect(result.entries[0].compressedSize == UInt32(payload.count))
}

@Test func countsMetadataAndDirectoriesTowardTheEntryCap() throws {
    var entries = [file("skin.json"), file("__MACOSX/._skin.json")]
    for index in 0..<398 {
        entries.append(.directory(String(format: "d%03d/", index)))
    }
    let result = try SkinArchivePreflight.check(archive(entries))
    #expect(result.entries.count == 1)
    #expect(result.warnings.isEmpty)

    entries.append(.directory("overflow/"))
    #expect(preflightError(archive(entries)) == .entryCountExceeded(
        count: 401,
        limit: 400
    ))
}

@Test func rejectsUnicodeControlAndBidiNames() {
    let names = [
        "images/\u{0007}.png",
        "images/\u{200F}evil.png",
        "images/\u{202E}evil.png",
        "images/\u{2066}evil.png",
    ]

    for name in names {
        #expect(preflightError(archive([file("skin.json"), file(name)])) == .unsafeEntryPath(
            path: name,
            reason: "control character"
        ))
    }
}
