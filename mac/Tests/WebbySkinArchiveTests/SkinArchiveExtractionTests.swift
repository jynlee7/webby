import Foundation
import Testing
@testable import WebbySkinArchive

private func entry(_ path: String, contents: [UInt8]) -> ZIPFixtureEntry {
    ZIPFixtureEntry(path: path, contents: contents)
}

private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func extractionError(
    _ data: Data,
    harness: StagedExtractionHarness
) -> SkinArchiveError? {
    do {
        _ = try harness.extract(data)
        return nil
    } catch let error as SkinArchiveError {
        return error
    } catch {
        Issue.record("unexpected error type: \(error)")
        return nil
    }
}

@Test func byteBudgetAcceptsExactFileAndTotalBoundaries() throws {
    var budget = SkinArchiveByteBudget()

    let manifestBytes = try budget.charge(
        300,
        path: "skin.json",
        fileBytes: 0,
        fileLimit: 300
    )
    #expect(manifestBytes == 300)
    #expect(budget.totalBytes == 300)

    let imageBytes = try budget.charge(
        64_000_000 - 300,
        path: "images/note-body.png",
        fileBytes: 0,
        fileLimit: 64_000_000
    )
    #expect(imageBytes == 64_000_000 - 300)
    #expect(budget.totalBytes == 64_000_000)
}

@Test func byteBudgetRejectsOneBytePastFileAndTotalLimits() throws {
    var budget = SkinArchiveByteBudget()
    _ = try budget.charge(
        64_000_000,
        path: "images/note-body.png",
        fileBytes: 0,
        fileLimit: 64_000_000
    )

    do {
        _ = try budget.charge(
            1,
            path: "images/note-body.png",
            fileBytes: 64_000_000,
            fileLimit: 64_000_000
        )
        Issue.record("expected the per-file limit to reject one extra byte")
    } catch let error as SkinArchiveError {
        #expect(error == .decompressedSizeExceeded(
            path: "images/note-body.png",
            actual: 64_000_001,
            limit: 64_000_000
        ))
    }

    do {
        _ = try budget.charge(
            1,
            path: "images/other.png",
            fileBytes: 0,
            fileLimit: 64_000_000
        )
        Issue.record("expected the total limit to reject one extra byte")
    } catch let error as SkinArchiveError {
        #expect(error == .decompressedSizeExceeded(
            path: "images/other.png",
            actual: 64_000_001,
            limit: 64_000_000
        ))
    }
}

@Test func byteBudgetRejectsArithmeticOverflowAndNegativeCounts() {
    var overflowingFile = SkinArchiveByteBudget()
    do {
        _ = try overflowingFile.charge(
            Int.max,
            path: "images/note-body.png",
            fileBytes: 1,
            fileLimit: Int.max
        )
        Issue.record("expected per-file byte overflow to be rejected")
    } catch let error as SkinArchiveError {
        #expect(error == .decompressedSizeExceeded(
            path: "images/note-body.png",
            actual: Int.max,
            limit: Int.max
        ))
    }

    var overflowingTotal = SkinArchiveByteBudget()
    _ = try? overflowingTotal.charge(
        64_000_000,
        path: "skin.json",
        fileBytes: 0,
        fileLimit: 64_000_000
    )
    do {
        _ = try overflowingTotal.charge(
            1,
            path: "images/note-body.png",
            fileBytes: 0,
            fileLimit: 64_000_000
        )
        Issue.record("expected total byte overflow to be rejected")
    } catch let error as SkinArchiveError {
        #expect(error == .decompressedSizeExceeded(
            path: "images/note-body.png",
            actual: 64_000_001,
            limit: 64_000_000
        ))
    }

    var negative = SkinArchiveByteBudget()
    do {
        _ = try negative.charge(
            -1,
            path: "skin.json",
            fileBytes: 0,
            fileLimit: 300
        )
        Issue.record("expected a negative chunk to be rejected")
    } catch let error as SkinArchiveError {
        #expect(error == .extractionFailed(
            path: "skin.json",
            reason: "negative decompressed byte count"
        ))
    }
}

@Test func preflightRejectionNeverCreatesStaging() throws {
    let harness = try StagedExtractionHarness()
    defer { harness.cleanup() }

    let data = ZIPFixture.make(entries: [
        entry("notes.txt", contents: Array("not a skin".utf8)),
    ])

    #expect(extractionError(data, harness: harness) == .manifestMissing)
    #expect(harness.factoryCalls == 0)
    #expect(harness.createdRoots.isEmpty)
}

@Test func extractsRootArchiveWithExactBytesAndPermissions() throws {
    let harness = try StagedExtractionHarness()
    defer { harness.cleanup() }

    let manifest = Array("{\"id\":\"root\"}".utf8)
    let image = [UInt8](repeating: 0xAB, count: 32)
    let sound = [UInt8](repeating: 0xCD, count: 16)
    let data = ZIPFixture.make(entries: [
        entry("skin.json", contents: manifest),
        entry("images/note-body.png", contents: image),
        entry("sounds/note-create.wav", contents: sound),
        entry("__MACOSX/._skin.json", contents: [1]),
        entry(".DS_Store", contents: [2]),
    ])

    let staged = try harness.extract(data)
    defer { try? staged.discard() }

    #expect(harness.factoryCalls == 1)
    #expect(harness.createdRoots == [staged.root])
    #expect(staged.entries.map(\.path) == [
        "skin.json",
        "images/note-body.png",
        "sounds/note-create.wav",
    ])
    #expect(staged.warnings.isEmpty)

    let stagedManifest = try Data(
        contentsOf: staged.root.appendingPathComponent("skin.json")
    )
    let stagedImage = try Data(
        contentsOf: staged.root.appendingPathComponent("images/note-body.png")
    )
    let stagedSound = try Data(
        contentsOf: staged.root.appendingPathComponent("sounds/note-create.wav")
    )
    #expect(stagedManifest == Data(manifest))
    #expect(stagedImage == Data(image))
    #expect(stagedSound == Data(sound))

    #expect(!FileManager.default.fileExists(
        atPath: staged.root.appendingPathComponent("__MACOSX").path
    ))
    #expect(!FileManager.default.fileExists(
        atPath: staged.root.appendingPathComponent(".DS_Store").path
    ))

    #expect(try permissions(of: staged.root.appendingPathComponent("skin.json")) == 0o644)
    #expect(try permissions(of: staged.root.appendingPathComponent("images/note-body.png")) == 0o644)
    #expect(try permissions(of: staged.root.appendingPathComponent("sounds/note-create.wav")) == 0o644)
    #expect(try permissions(of: staged.root.appendingPathComponent("images")) == 0o755)
    #expect(try permissions(of: staged.root.appendingPathComponent("sounds")) == 0o755)
}

@Test func extractsWrapperArchiveAndStripsTheWrapperPrefix() throws {
    let harness = try StagedExtractionHarness()
    defer { harness.cleanup() }

    let manifest = Array("{\"id\":\"wrapped\"}".utf8)
    let image = [UInt8](repeating: 0x11, count: 24)
    let data = ZIPFixture.make(entries: [
        entry("MySkin/skin.json", contents: manifest),
        entry("MySkin/images/note-body.png", contents: image),
        entry("__MACOSX/._skin.json", contents: [3]),
        entry(".DS_Store", contents: [4]),
    ])

    let staged = try harness.extract(data)
    defer { try? staged.discard() }

    #expect(staged.entries.map(\.path) == ["skin.json", "images/note-body.png"])
    #expect(staged.warnings.isEmpty)
    let stagedManifest = try Data(
        contentsOf: staged.root.appendingPathComponent("skin.json")
    )
    let stagedImage = try Data(
        contentsOf: staged.root.appendingPathComponent("images/note-body.png")
    )
    #expect(stagedManifest == Data(manifest))
    #expect(stagedImage == Data(image))
    #expect(!FileManager.default.fileExists(
        atPath: staged.root.appendingPathComponent("MySkin").path
    ))
}

@Test func skipsUnknownEntriesAndKeepsThePreflightWarning() throws {
    let harness = try StagedExtractionHarness()
    defer { harness.cleanup() }

    let data = ZIPFixture.make(entries: [
        entry("skin.json", contents: Array("{}".utf8)),
        entry("notes.txt", contents: Array("ignored".utf8)),
    ])

    let staged = try harness.extract(data)
    defer { try? staged.discard() }

    #expect(staged.entries.map(\.path) == ["skin.json"])
    #expect(!FileManager.default.fileExists(
        atPath: staged.root.appendingPathComponent("notes.txt").path
    ))
    #expect(staged.warnings.count == 1)
    #expect(staged.warnings[0].assetPath == "notes.txt")
}

@Test func refusesOverwriteAndRemovesTheStagingRoot() throws {
    let harness = try StagedExtractionHarness()
    defer { harness.cleanup() }

    let root = harness.parent.appendingPathComponent("occupied", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try Data("existing".utf8).write(to: root.appendingPathComponent("skin.json"))
    let environment = SkinArchiveExtractionEnvironment(
        fileManager: .default,
        makeStagingDirectory: { _ in root }
    )
    let data = ZIPFixture.make(entries: [
        entry("skin.json", contents: Array("{}".utf8)),
    ])

    do {
        _ = try SkinArchiveExtractor.extract(
            data,
            stagingNear: harness.parent,
            environment: environment
        )
        Issue.record("expected an existing destination to be rejected")
    } catch let error as SkinArchiveError {
        #expect(error == .destinationExists(path: "skin.json"))
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test func stagedDiscardIsIdempotent() throws {
    let harness = try StagedExtractionHarness()
    defer { harness.cleanup() }

    let data = ZIPFixture.make(entries: [
        entry("skin.json", contents: Array("{}".utf8)),
    ])
    let staged = try harness.extract(data)

    #expect(FileManager.default.fileExists(atPath: staged.root.path))
    try staged.discard()
    #expect(!FileManager.default.fileExists(atPath: staged.root.path))
    try staged.discard()
    #expect(!FileManager.default.fileExists(atPath: staged.root.path))
}

@Test func crcMismatchRemovesTheWholeInjectedStagingRoot() throws {
    let harness = try StagedExtractionHarness()
    defer { harness.cleanup() }

    let data = ZIPFixture.make(entries: [
        entry("images/note-body.png", contents: Array("png".utf8)),
        ZIPFixtureEntry(
            path: "skin.json",
            contents: Array("{}".utf8),
            crc32: 0xDEAD_BEEF,
            localCRC32: 0xDEAD_BEEF
        ),
    ])

    guard let error = extractionError(data, harness: harness) else {
        Issue.record("expected a CRC mismatch")
        return
    }
    guard case .crcMismatch(let path, let expected, let actual) = error else {
        Issue.record("expected crcMismatch, got \(error)")
        return
    }
    #expect(path == "skin.json")
    #expect(expected == 0xDEAD_BEEF)
    #expect(actual != expected)

    #expect(harness.factoryCalls == 1)
    #expect(harness.createdRoots.count == 1)
    #expect(!FileManager.default.fileExists(atPath: harness.createdRoots[0].path))
}

@Test func compressedStreamCorruptionRemovesTheWholeInjectedStagingRoot() throws {
    let harness = try StagedExtractionHarness()
    defer { harness.cleanup() }

    let data = ZIPFixture.make(entries: [
        entry("images/note-body.png", contents: Array("png".utf8)),
        ZIPFixtureEntry(
            path: "skin.json",
            contents: [0xFF, 0xFF, 0xFF, 0xFF],
            method: 8
        ),
    ])

    guard let error = extractionError(data, harness: harness) else {
        Issue.record("expected corrupt deflate data to fail extraction")
        return
    }
    switch error {
    case .extractionFailed(let path, _):
        #expect(path == "skin.json")
    case .crcMismatch(let path, _, _):
        #expect(path == "skin.json")
    default:
        Issue.record("expected extractionFailed or crcMismatch, got \(error)")
    }

    #expect(harness.factoryCalls == 1)
    #expect(harness.createdRoots.count == 1)
    #expect(!FileManager.default.fileExists(atPath: harness.createdRoots[0].path))
}

@Test func actualManifestCapRejectsAndCleansStaging() throws {
    let harness = try StagedExtractionHarness()
    defer { harness.cleanup() }

    let data = try StreamingZIPFixture.make(entries: [
        StreamingZIPEntry(
            path: "skin.json",
            actualByteCount: SkinArchiveLimits.manifestByteCount + 1,
            declaredByteCount: 1
        ),
    ])

    // Preflight sees only the forged declared size, so it admits the archive.
    #expect(try SkinArchivePreflight.check(data).entries[0].uncompressedSize == 1)

    assertDecompressedCap(
        extractionError(data, harness: harness),
        path: "skin.json",
        limit: SkinArchiveLimits.manifestByteCount,
        harness: harness
    )
}

@Test func actualImageCapRejectsAndCleansStaging() throws {
    let harness = try StagedExtractionHarness()
    defer { harness.cleanup() }

    let data = try StreamingZIPFixture.make(entries: [
        StreamingZIPEntry(
            path: "skin.json",
            actualByteCount: 16,
            declaredByteCount: 16
        ),
        StreamingZIPEntry(
            path: "images/note-body.png",
            actualByteCount: SkinArchiveLimits.imageByteCount + 1,
            declaredByteCount: 1
        ),
    ])

    assertDecompressedCap(
        extractionError(data, harness: harness),
        path: "images/note-body.png",
        limit: SkinArchiveLimits.imageByteCount,
        harness: harness
    )
}

@Test func actualSoundCapRejectsAndCleansStaging() throws {
    let harness = try StagedExtractionHarness()
    defer { harness.cleanup() }

    let data = try StreamingZIPFixture.make(entries: [
        StreamingZIPEntry(
            path: "skin.json",
            actualByteCount: 16,
            declaredByteCount: 16
        ),
        StreamingZIPEntry(
            path: "sounds/note-create.wav",
            actualByteCount: SkinArchiveLimits.soundByteCount + 1,
            declaredByteCount: 1
        ),
    ])

    assertDecompressedCap(
        extractionError(data, harness: harness),
        path: "sounds/note-create.wav",
        limit: SkinArchiveLimits.soundByteCount,
        harness: harness
    )
}

@Test func actualTotalCapRejectsAndCleansStaging() throws {
    let harness = try StagedExtractionHarness()
    defer { harness.cleanup() }

    // Sixteen images of exactly the per-image limit plus the 16-byte manifest
    // exceed the 64 MB total on the sixteenth image. Every declared size is
    // forged below preflight.
    var entries = [
        StreamingZIPEntry(path: "skin.json", actualByteCount: 16, declaredByteCount: 16),
    ]
    for frame in 0..<16 {
        entries.append(StreamingZIPEntry(
            path: "images/orb-idle-\(frame).png",
            actualByteCount: SkinArchiveLimits.imageByteCount,
            declaredByteCount: 1
        ))
    }
    let data = try StreamingZIPFixture.make(entries: entries)

    assertDecompressedCap(
        extractionError(data, harness: harness),
        path: "images/orb-idle-15.png",
        limit: SkinArchiveLimits.uncompressedByteCount,
        harness: harness
    )
}

@Test func forgedHundredMegabyteZeroStreamIsBoundedAndCleansStaging() throws {
    let harness = try StagedExtractionHarness()
    defer { harness.cleanup() }

    let data = try StreamingZIPFixture.make(entries: [
        StreamingZIPEntry(
            path: "skin.json",
            actualByteCount: 16,
            declaredByteCount: 16
        ),
        StreamingZIPEntry(
            path: "images/note-body.png",
            actualByteCount: 100 * 1024 * 1024,
            declaredByteCount: 1_000_000
        ),
    ])

    // Preflight admits the archive because the declared size is under the total
    // and under the image cap, while the compressed stream is tiny.
    let preflight = try SkinArchivePreflight.check(data)
    #expect(preflight.entries[1].uncompressedSize == 1_000_000)
    #expect(data.count < 1024 * 1024)

    // A single admitted entry always hits a per-file cap before the 64 MB total:
    // skin.json is capped at 256 KB, images at 4 MB and sounds at 1 MB. The actual
    // 100 MB stream is still bounded here, and no staging root survives.
    assertDecompressedCap(
        extractionError(data, harness: harness),
        path: "images/note-body.png",
        limit: SkinArchiveLimits.imageByteCount,
        harness: harness
    )
}

private func assertDecompressedCap(
    _ error: SkinArchiveError?,
    path expectedPath: String,
    limit expectedLimit: Int,
    harness: StagedExtractionHarness
) {
    guard let error else {
        Issue.record("expected decompressedSizeExceeded")
        return
    }
    guard case .decompressedSizeExceeded(let path, let actual, let limit) = error else {
        Issue.record("expected decompressedSizeExceeded, got \(error)")
        return
    }
    #expect(path == expectedPath)
    #expect(limit == expectedLimit)
    #expect(actual > limit)
    #expect(actual <= limit + 64 * 1024)

    #expect(harness.factoryCalls == 1)
    #expect(harness.createdRoots.count == 1)
    #expect(!FileManager.default.fileExists(atPath: harness.createdRoots[0].path))
}
