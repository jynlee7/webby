import Foundation
import Testing
import WebbyCore
@testable import WebbySkinArchive

private let bodyPath = "images/note-body.png"
private let retinaBodyPath = "images/note-body@2x.png"
private let soundPath = "sounds/note-create.wav"

private func imageCode(_ check: AssetCheck<ImageAssetMetadata>) -> String? {
    guard case .invalid(let code) = check else {
        return nil
    }
    return code
}

private func validation(
    _ stage: ArchiveMediaStage,
    availableBaseIDs: Set<String> = ["webby.clear"]
) -> SkinArchiveValidation {
    SkinArchiveStaging.validate(stage.staged, availableBaseIDs: availableBaseIDs)
}

private func hasDiagnostic(
    _ result: SkinArchiveValidation,
    code: String,
    severity: SkinDiagnostic.Severity? = nil,
    group: SkinGroup? = nil
) -> Bool {
    result.diagnostics.contains { diagnostic in
        diagnostic.code == code
            && (severity == nil || diagnostic.severity == severity)
            && (group == nil || diagnostic.group == group?.rawValue)
    }
}

// MARK: - Inventory

@Test func inventoryReportsEveryAdmittedFileWithActualBytes() throws {
    let manifest = archiveManifest()
    let sound = makePCMWAV(sampleRate: 8_000, channels: 1, bits: 16, frames: 8_000)
    let stage = try ArchiveMediaStage(files: [
        "skin.json": manifest,
        bodyPath: onePixelPNG,
        soundPath: sound,
    ])

    let checker = SkinAssetChecker(stage.staged)
    #expect(checker.root == stage.root)
    #expect(checker.inventory() == [
        SkinAssetRecord(path: bodyPath, bytes: onePixelPNG.count),
        SkinAssetRecord(path: "skin.json", bytes: manifest.count),
        SkinAssetRecord(path: soundPath, bytes: sound.count),
    ])

    #expect(checker.image("images/unknown.png") == .missing)
    #expect(checker.image("sounds/note-create.wav") == .missing)
    #expect(checker.image("images/note-body.jpg") == .missing)
    #expect(checker.sound("images/note-body.png") == .missing)
    #expect(checker.sound("sounds/unknown.wav") == .missing)
}

// MARK: - Images

@Test func validPNGAndRetinaVariantDecode() throws {
    let stage = try ArchiveMediaStage(files: [
        "skin.json": archiveManifest(),
        bodyPath: onePixelPNG,
        retinaBodyPath: onePixelPNG,
    ])
    let checker = SkinAssetChecker(stage.staged)

    guard case .available(let metadata) = checker.image(bodyPath) else {
        Issue.record("expected the one-pixel PNG to decode")
        return
    }
    #expect(metadata.path == bodyPath)
    #expect(metadata.bytes == onePixelPNG.count)
    #expect(metadata.png.width == 1)
    #expect(metadata.png.height == 1)

    guard case .available(let retina) = checker.image(retinaBodyPath) else {
        Issue.record("expected the Retina-named PNG to decode")
        return
    }
    #expect(retina.bytes == onePixelPNG.count)
    #expect(retina.png.width == 1)
}

@Test func headerOnlyPNGFailsTheDecodeCheck() throws {
    let stage = try ArchiveMediaStage(files: [
        "skin.json": archiveManifest(),
        bodyPath: headerOnlyPNG(width: 1, height: 1),
    ])

    let check = SkinAssetChecker(stage.staged).image(bodyPath)
    #expect(imageCode(check) != nil)
    #expect(check.value == nil)
}

@Test func truncatedImageDataFailsTheDecodeCheck() throws {
    // The IHDR and its CRC stay valid, but the IDAT chunk is cut short. ImageIO
    // must refuse the stream rather than reporting a partial image.
    let truncated = onePixelPNG.prefix(40)
    let stage = try ArchiveMediaStage(files: [
        "skin.json": archiveManifest(),
        bodyPath: Data(truncated),
    ])

    let check = SkinAssetChecker(stage.staged).image(bodyPath)
    #expect(imageCode(check) != nil)
    #expect(check.value == nil)
}

@Test func oversizedHeaderIsRejectedBeforeDecode() throws {
    let oversized = pngWithRewrittenIHDR(width: 3_000, height: 1)
    let stage = try ArchiveMediaStage(files: [
        "skin.json": archiveManifest(),
        bodyPath: oversized,
    ])

    let check = SkinAssetChecker(stage.staged).image(bodyPath)
    #expect(imageCode(check) == "image-dimension-exceeded")
    #expect(check.value == nil)
}

@Test func nonPNGBytesUnderAPNGNameAreRejected() throws {
    let stage = try ArchiveMediaStage(files: [
        "skin.json": archiveManifest(),
        bodyPath: Data(repeating: 0x41, count: 64),
    ])

    let check = SkinAssetChecker(stage.staged).image(bodyPath)
    #expect(imageCode(check) == "not-png")
    #expect(check.value == nil)
}

// MARK: - Sounds

@Test func integerPCMContainersAreAccepted() throws {
    let wav = makePCMWAV(sampleRate: 8_000, channels: 1, bits: 16, frames: 8_000)
    let aiff = makePCMAIFF(sampleRate: 8_000, frames: 8_000)
    let caf = makeCAF(
        sampleRate: 8_000,
        bytesPerPacket: 2,
        framesPerPacket: 1,
        packetCount: 8_000
    )
    let stage = try ArchiveMediaStage(files: [
        "skin.json": archiveManifest(),
        "sounds/note-create.wav": wav,
        "sounds/note-create.aiff": aiff,
        "sounds/note-create.caf": caf,
    ])
    let checker = SkinAssetChecker(stage.staged)

    for (path, expectedBytes) in [
        ("sounds/note-create.wav", wav.count),
        ("sounds/note-create.aiff", aiff.count),
        ("sounds/note-create.caf", caf.count),
    ] {
        guard case .available(let metadata) = checker.sound(path) else {
            Issue.record("expected PCM metadata for \(path)")
            continue
        }
        #expect(metadata.isPCM)
        #expect(metadata.bytes == expectedBytes)
        #expect(abs(metadata.duration - 1.0) < 0.001)
    }
}

@Test func floatingPointPCMCAFIsAccepted() throws {
    let caf = makeCAF(
        sampleRate: 8_000,
        formatFlags: 1,
        bytesPerPacket: 4,
        framesPerPacket: 1,
        packetCount: 8_000,
        bitsPerChannel: 32
    )
    let stage = try ArchiveMediaStage(files: [
        "skin.json": archiveManifest(),
        "sounds/note-create.caf": caf,
    ])

    guard case .available(let metadata) = SkinAssetChecker(stage.staged)
        .sound("sounds/note-create.caf")
    else {
        Issue.record("expected float32 PCM CAF metadata")
        return
    }
    #expect(metadata.isPCM)
    #expect(abs(metadata.duration - 1.0) < 0.001)
}

@Test func compressedCAFReportsNonPCM() throws {
    let caf = makeCAF(
        sampleRate: 8_000,
        formatID: "ima4",
        bytesPerPacket: 34,
        framesPerPacket: 64,
        packetCount: 4,
        bitsPerChannel: 0
    )
    let stage = try ArchiveMediaStage(files: [
        "skin.json": archiveManifest(),
        "sounds/note-create.caf": caf,
    ])

    let check = SkinAssetChecker(stage.staged).sound("sounds/note-create.caf")
    guard case .available(let metadata) = check else {
        Issue.record(
            "AVAudioFile could not open the IMA4 CAF fixture; compressed-audio coverage was not exercised: \(check)"
        )
        return
    }
    #expect(!metadata.isPCM)
}

@Test func soundDurationsUseFramesAndSampleRate() throws {
    let long = makePCMWAV(sampleRate: 8_000, channels: 1, bits: 16, frames: 28_000)
    let exact = makePCMWAV(sampleRate: 8_000, channels: 1, bits: 16, frames: 24_000)

    let longStage = try ArchiveMediaStage(files: [
        "skin.json": archiveManifest(extra: archiveSoundsGroup),
        soundPath: long,
    ])
    guard case .available(let longMetadata) = SkinAssetChecker(longStage.staged)
        .sound(soundPath)
    else {
        Issue.record("expected long PCM metadata")
        return
    }
    #expect(longMetadata.duration > 3.0)
    let longResult = validation(longStage)
    #expect(longResult.groups[.sounds] == .invalid)
    #expect(hasDiagnostic(longResult, code: "sound-duration-exceeded", group: .sounds))

    let exactStage = try ArchiveMediaStage(files: [
        "skin.json": archiveManifest(extra: archiveSoundsGroup),
        soundPath: exact,
    ])
    guard case .available(let exactMetadata) = SkinAssetChecker(exactStage.staged)
        .sound(soundPath)
    else {
        Issue.record("expected exact-duration PCM metadata")
        return
    }
    #expect(exactMetadata.duration <= 3.0 + 0.001)
    let exactResult = validation(exactStage)
    #expect(!hasDiagnostic(exactResult, code: "sound-duration-exceeded"))
    #expect(exactResult.groups[.sounds] == .usable)
}

// MARK: - Integration

@Test func validStagedSkinProducesAcceptedValidationAndInventory() throws {
    let manifest = archiveManifest(extra: archiveSurfaceGroup + archiveSoundsGroup)
    let sound = makePCMWAV(sampleRate: 8_000, channels: 1, bits: 16, frames: 8_000)
    let stage = try ArchiveMediaStage(files: [
        "skin.json": manifest,
        bodyPath: onePixelPNG,
        retinaBodyPath: onePixelPNG,
        soundPath: sound,
    ])

    let result = validation(stage)

    #expect(result.isAccepted)
    #expect(result.diagnostics.isEmpty)
    #expect(result.manifest?.id == "io.example.archive")
    #expect(result.document?.manifest?.id == "io.example.archive")
    #expect(result.groups[.surface] == .usable)
    #expect(result.groups[.sounds] == .usable)
    #expect(result.checker.inventory() == [
        SkinAssetRecord(path: bodyPath, bytes: onePixelPNG.count),
        SkinAssetRecord(path: retinaBodyPath, bytes: onePixelPNG.count),
        SkinAssetRecord(path: "skin.json", bytes: manifest.count),
        SkinAssetRecord(path: soundPath, bytes: sound.count),
    ])

    let manifestValue = try #require(result.manifest)
    let installed = InstalledSkin(
        id: manifestValue.id,
        manifest: manifestValue,
        groups: result.groups,
        availableImagePaths: result.availableImagePaths,
        isAccepted: result.isAccepted
    )
    #expect(installed.isAccepted)
    #expect(installed.availableImagePaths == Set([bodyPath, retinaBodyPath]))
}

@Test func invalidImageIsAGroupErrorAgainstSurfaceOnly() throws {
    let manifest = archiveManifest(extra: archiveSurfaceGroup + #"""
    ,
      "typography": { "size": 14 }
    """#)
    let stage = try ArchiveMediaStage(files: [
        "skin.json": manifest,
        bodyPath: Data(repeating: 0x41, count: 64),
    ])

    let result = validation(stage)

    #expect(result.isAccepted)
    #expect(result.groups[.surface] == .invalid)
    #expect(result.groups[.typography] == .usable)
    #expect(result.groups[.sounds] == .absent)
    #expect(hasDiagnostic(result, code: "invalid-asset", severity: .groupError, group: .surface))
}

@Test func oversizedImageIsRejectedAsImageDimensionExceeded() throws {
    let stage = try ArchiveMediaStage(files: [
        "skin.json": archiveManifest(extra: archiveSurfaceGroup),
        bodyPath: pngWithRewrittenIHDR(width: 3_000, height: 1),
    ])

    let result = validation(stage)

    #expect(result.groups[.surface] == .invalid)
    #expect(result.diagnostics.contains {
        $0.code == "invalid-asset"
            && $0.group == SkinGroup.surface.rawValue
            && $0.message.contains("image-dimension-exceeded")
    })
}

@Test func nonPCMsoundInvalidatesTheSoundsGroup() throws {
    let caf = makeCAF(
        sampleRate: 8_000,
        formatID: "ima4",
        bytesPerPacket: 34,
        framesPerPacket: 64,
        packetCount: 4,
        bitsPerChannel: 0
    )
    let stage = try ArchiveMediaStage(files: [
        "skin.json": archiveManifest(extra: archiveSoundsGroup),
        "sounds/note-create.caf": caf,
    ])

    let result = validation(stage)

    #expect(result.groups[.sounds] == .invalid)
    if hasDiagnostic(result, code: "sound-not-pcm", group: .sounds) {
        return
    }
    Issue.record("AVAudioFile did not report the IMA4 CAF as non-PCM: \(result.diagnostics)")
}

@Test func missingAssetsBehaveAsInFolderLoading() throws {
    let stage = try ArchiveMediaStage(files: [
        "skin.json": archiveManifest(extra: archiveSurfaceGroup),
    ])

    let result = validation(stage)

    #expect(result.isAccepted)
    #expect(result.checker.image(bodyPath) == .missing)
    #expect(hasDiagnostic(result, code: "missing-asset", severity: .warning, group: .surface))
    #expect(result.groups[.surface] == .usable)
}

// MARK: - Staging root isolation

@Test func validationReadsTheStagingRootNotTheSourceArchive() throws {
    let harness = try StagedExtractionHarness()
    defer { harness.cleanup() }

    let manifest = archiveManifest(extra: archiveSurfaceGroup)
    let data = ZIPFixture.make(entries: [
        ZIPFixtureEntry(path: "skin.json", contents: Array(manifest)),
        ZIPFixtureEntry(path: bodyPath, contents: Array(onePixelPNG)),
    ])

    let staged = try harness.extract(data)
    defer { try? staged.discard() }
    #expect(staged.root != harness.parent)

    // The archive data above is still a valid image. Replacing the staged copy
    // must change the result if validation reads only the staging root.
    try Data("not a png".utf8).write(
        to: staged.root.appendingPathComponent(bodyPath)
    )

    let result = SkinArchiveStaging.validate(staged, availableBaseIDs: ["webby.clear"])
    #expect(result.checker.root == staged.root)
    #expect(result.groups[.surface] == .invalid)
    #expect(result.diagnostics.contains {
        $0.code == "invalid-asset" && $0.group == SkinGroup.surface.rawValue
    })
}

@Test func checkerResultsArePrecomputedAndImmutable() throws {
    let stage = try ArchiveMediaStage(files: [
        "skin.json": archiveManifest(),
        bodyPath: onePixelPNG,
    ])

    let checker = SkinAssetChecker(stage.staged)
    guard case .available = checker.image(bodyPath) else {
        Issue.record("expected the initial PNG to decode")
        return
    }

    try Data("not a png".utf8).write(to: stage.root.appendingPathComponent(bodyPath))
    try FileManager.default.removeItem(at: stage.root.appendingPathComponent("skin.json"))

    guard case .available(let metadata) = checker.image(bodyPath) else {
        Issue.record("expected the precomputed image result to survive later file changes")
        return
    }
    #expect(metadata.bytes == onePixelPNG.count)
    #expect(checker.inventory().contains { $0.path == "skin.json" })
}
