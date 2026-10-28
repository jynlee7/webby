import Foundation
import Testing
@testable import WebbyCore

// MARK: - Helpers

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("webby-skin-folder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ string: String, to url: URL) throws {
    try write(Data(string.utf8), to: url)
}

private func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url)
}

private func writeSparseFile(byteCount: Int, to url: URL) throws {
    try write(Data(), to: url)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(byteCount))
}

private func minimalManifest(
    id: String = "webby.example.empty",
    name: String = "Empty",
    version: String = "1.0.0"
) -> String {
    """
    {
      "formatVersion": 1,
      "id": "\(id)",
      "name": "\(name)",
      "author": "Test",
      "version": "\(version)"
    }
    """
}

private func load(
    _ folder: URL,
    origin: SkinOrigin = .builtIn,
    availableBaseIDs: Set<String> = ["webby.clear", "webby.mono"]
) -> SkinFolderLoadResult {
    SkinFolderLoader.load(
        folder: folder,
        origin: origin,
        availableBaseIDs: availableBaseIDs
    )
}

private func hasCode(
    _ result: SkinFolderLoadResult,
    _ code: String,
    severity: SkinDiagnostic.Severity? = nil
) -> Bool {
    result.diagnostics.contains { diagnostic in
        diagnostic.code == code && (severity == nil || diagnostic.severity == severity)
    }
}

private func repositoryRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while url.path != "/" {
        if FileManager.default.fileExists(
            atPath: url.appendingPathComponent("mac/Resources/Skins/webby.clear/skin.json").path
        ) {
            return url
        }
        url.deleteLastPathComponent()
    }
    return url
}

private let onePixelPNG = Data(base64Encoded: """
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==
""")!

// MARK: - Manifest-only folders

@Test func manifestOnlyFolderIsAcceptedWithoutDiagnostics() throws {
    let folder = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    let manifestData = Data(minimalManifest().utf8)
    try write(manifestData, to: folder.appendingPathComponent("skin.json"))

    let result = load(folder)

    #expect(result.isAccepted)
    #expect(result.diagnostics.isEmpty)
    #expect(result.manifest?.id == "webby.example.empty")
    #expect(result.document?.manifest?.id == "webby.example.empty")
    #expect(result.entries == [SkinEntry(path: "skin.json")])
    #expect(result.assetChecker.inventory() == [
        SkinAssetRecord(path: "skin.json", bytes: manifestData.count),
    ])
    #expect(result.assetChecker.image("images/note-body.png") == .missing)
    #expect(result.assetChecker.sound("sounds/note-create.wav") == .missing)
}

@Test func missingManifestIsFatal() throws {
    let folder = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    let result = load(folder)

    #expect(!result.isAccepted)
    #expect(result.manifest == nil)
    #expect(result.document == nil)
    #expect(result.entries.isEmpty)
    #expect(result.assetChecker.inventory().isEmpty)
    #expect(hasCode(result, "manifest-missing", severity: .fatal))
}

@Test func manifestOverTheByteCapIsFatalWithoutDecoding() throws {
    let folder = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    try write(
        Data(repeating: 0x20, count: SkinFolderLoader.maximumManifestBytes + 1),
        to: folder.appendingPathComponent("skin.json")
    )

    let result = load(folder)

    #expect(!result.isAccepted)
    #expect(result.document == nil)
    #expect(hasCode(result, "manifest-too-large", severity: .fatal))
}

@Test func manifestAtTheByteCapIsAccepted() throws {
    let folder = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    let base = minimalManifest()
    let padding = String(
        repeating: " ",
        count: SkinFolderLoader.maximumManifestBytes - base.utf8.count
    )
    let data = Data((base + padding).utf8)
    #expect(data.count == SkinFolderLoader.maximumManifestBytes)
    try write(data, to: folder.appendingPathComponent("skin.json"))

    let result = load(folder)

    #expect(result.isAccepted)
    #expect(result.diagnostics.isEmpty)
}

// MARK: - Caps

@Test func moreThanFourHundredEntriesIsFatal() throws {
    let folder = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    try write(minimalManifest(), to: folder.appendingPathComponent("skin.json"))
    for index in 0..<SkinFolderLoader.maximumEntries {
        try write("x", to: folder.appendingPathComponent("extra-\(index).bin"))
    }

    let result = load(folder)

    #expect(!result.isAccepted)
    #expect(hasCode(result, "entry-count-exceeded", severity: .fatal))
}

@Test func aggregateBytesOverTheCapIsFatal() throws {
    let folder = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    try write(minimalManifest(), to: folder.appendingPathComponent("skin.json"))
    try writeSparseFile(
        byteCount: SkinFolderLoader.maximumTotalBytes + 1,
        to: folder.appendingPathComponent("padding.bin")
    )

    let result = load(folder)

    #expect(!result.isAccepted)
    #expect(hasCode(result, "total-size-exceeded", severity: .fatal))
}

@Test func oversizedImageIsAReportedGroupErrorWithoutReadingTheFile() throws {
    let folder = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    try write(minimalManifest(), to: folder.appendingPathComponent("skin.json"))
    let imageURL = folder.appendingPathComponent("images/note-body.png")
    try writeSparseFile(byteCount: SkinFolderLoader.maximumImageBytes + 1, to: imageURL)

    let result = load(folder)

    #expect(result.isAccepted)
    #expect(result.entries.contains { $0.path == "images/note-body.png" })
    #expect(result.diagnostics.contains {
        $0.code == "invalid-asset" && $0.message.contains("image-too-large")
    })
}

@Test func oversizedSoundIsAReportedGroupErrorWithoutReadingTheFile() throws {
    let folder = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    try write(minimalManifest(), to: folder.appendingPathComponent("skin.json"))
    let soundURL = folder.appendingPathComponent("sounds/note-create.wav")
    try writeSparseFile(byteCount: SkinFolderLoader.maximumSoundBytes + 1, to: soundURL)

    let result = load(folder)

    #expect(result.isAccepted)
    #expect(result.entries.contains { $0.path == "sounds/note-create.wav" })
    #expect(result.diagnostics.contains {
        $0.code == "invalid-asset" && $0.message.contains("sound-too-large")
    })
}

// MARK: - Entry rules and duplicates

@Test func symlinkedEntryIsRejectedAndNeverRead() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let outside = root.appendingPathComponent("outside.png")
    try write(onePixelPNG, to: outside)

    let folder = root.appendingPathComponent("skin", isDirectory: true)
    try write(minimalManifest(), to: folder.appendingPathComponent("skin.json"))
    try FileManager.default.createDirectory(
        at: folder.appendingPathComponent("images"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
        at: folder.appendingPathComponent("images/note-body.png"),
        withDestinationURL: outside
    )

    let result = load(folder)

    #expect(!result.isAccepted)
    #expect(hasCode(result, "entry-symlink", severity: .fatal))
    #expect(!result.entries.contains { $0.path == "images/note-body.png" })
    #expect(result.assetChecker.image("images/note-body.png") == .missing)
}

@Test func symlinkedDirectoryIsNotTraversed() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let outsideDirectory = root.appendingPathComponent("outside", isDirectory: true)
    try write(onePixelPNG, to: outsideDirectory.appendingPathComponent("note-body.png"))

    let folder = root.appendingPathComponent("skin", isDirectory: true)
    try write(minimalManifest(), to: folder.appendingPathComponent("skin.json"))
    try FileManager.default.createSymbolicLink(
        at: folder.appendingPathComponent("images"),
        withDestinationURL: outsideDirectory
    )

    let result = load(folder)

    #expect(!result.isAccepted)
    #expect(hasCode(result, "entry-symlink", severity: .fatal))
    #expect(!result.entries.contains { $0.path.hasPrefix("images/") })
    #expect(result.assetChecker.image("images/note-body.png") == .missing)
}

@Test func directoryEntriesAreSkipped() throws {
    let folder = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    try write(minimalManifest(), to: folder.appendingPathComponent("skin.json"))
    try FileManager.default.createDirectory(
        at: folder.appendingPathComponent("images"),
        withIntermediateDirectories: true
    )

    let result = load(folder)

    #expect(result.isAccepted)
    #expect(result.diagnostics.isEmpty)
    #expect(result.entries == [SkinEntry(path: "skin.json")])
}

@Test func caseCollidingNamesAreFatal() throws {
    let folder = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    try write(minimalManifest(), to: folder.appendingPathComponent("skin.json"))
    try write(onePixelPNG, to: folder.appendingPathComponent("images/note-body.png"))
    do {
        try write(onePixelPNG, to: folder.appendingPathComponent("images/Note-Body.png"))
    } catch {
        // A case-insensitive filesystem cannot represent this collision.
        return
    }

    let result = load(folder)

    #expect(!result.isAccepted)
    #expect(hasCode(result, "duplicate-entry", severity: .fatal))
}

@Test func canonicallyEquivalentNamesAreFatal() throws {
    let folder = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    try write(minimalManifest(), to: folder.appendingPathComponent("skin.json"))
    try write(onePixelPNG, to: folder.appendingPathComponent("images/caf\u{00E9}.png"))
    do {
        try write(onePixelPNG, to: folder.appendingPathComponent("images/cafe\u{0301}.png"))
    } catch {
        // A normalizing filesystem cannot represent this collision.
        return
    }

    let result = load(folder)

    #expect(!result.isAccepted)
    #expect(hasCode(result, "duplicate-entry", severity: .fatal))
}

@Test func traversalLikeNamesAreRejectedWithoutBeingRead() throws {
    let folder = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    try write(minimalManifest(), to: folder.appendingPathComponent("skin.json"))
    try write(onePixelPNG, to: folder.appendingPathComponent("..evil.png"))

    let result = load(folder)

    #expect(!result.isAccepted)
    #expect(hasCode(result, "entry-rejected", severity: .fatal))
    #expect(!result.entries.contains { $0.path == "..evil.png" })
}

@Test func deterministicOrderDoesNotDependOnCreationOrder() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let names = ["zeta.bin", "alpha.bin", "middle.bin"]
    let forward = root.appendingPathComponent("forward", isDirectory: true)
    let reverse = root.appendingPathComponent("reverse", isDirectory: true)

    try write(minimalManifest(), to: forward.appendingPathComponent("skin.json"))
    try write(minimalManifest(), to: reverse.appendingPathComponent("skin.json"))
    for name in names {
        try write("x", to: forward.appendingPathComponent(name))
    }
    for name in names.reversed() {
        try write("x", to: reverse.appendingPathComponent(name))
    }

    let first = load(forward)
    let second = load(reverse)

    #expect(first.entries == second.entries)
    #expect(first.entries.map(\.path) == ["skin.json"])
    #expect(first.diagnostics.map(\.summary) == second.diagnostics.map(\.summary))
    #expect(first.diagnostics.map(\.assetPath) == ["alpha.bin", "middle.bin", "zeta.bin"])
}

// MARK: - Asset metadata

@Test func pngHeaderIsReadFromTheFile() throws {
    let folder = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    try write(minimalManifest(), to: folder.appendingPathComponent("skin.json"))
    try write(onePixelPNG, to: folder.appendingPathComponent("images/note-body.png"))

    let result = load(folder)
    let check = result.assetChecker.image("images/note-body.png")

    guard case .available(let metadata) = check else {
        Issue.record("expected the PNG header to be available")
        return
    }
    #expect(metadata.path == "images/note-body.png")
    #expect(metadata.bytes == onePixelPNG.count)
    #expect(metadata.png.width == 1)
    #expect(metadata.png.height == 1)
    #expect(metadata.png.colorType == 6)
}

@Test func wavContainerReportsPCMAndDuration() throws {
    let folder = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    try write(minimalManifest(), to: folder.appendingPathComponent("skin.json"))
    let sound = makeWAV(sampleRate: 8_000, channels: 1, bits: 16, frames: 8_000)
    try write(sound, to: folder.appendingPathComponent("sounds/note-create.wav"))

    let result = load(folder)
    let check = result.assetChecker.sound("sounds/note-create.wav")

    guard case .available(let metadata) = check else {
        Issue.record("expected the WAV metadata to be available")
        return
    }
    #expect(metadata.isPCM)
    #expect(abs(metadata.duration - 1.0) < 0.0001)
    #expect(metadata.bytes == sound.count)
}

@Test func aiffContainerReportsPCMAndDuration() throws {
    let folder = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    try write(minimalManifest(), to: folder.appendingPathComponent("skin.json"))
    let sound = makeAIFF(sampleRate: 1, frames: 1)
    try write(sound, to: folder.appendingPathComponent("sounds/note-create.aiff"))

    let result = load(folder)
    let check = result.assetChecker.sound("sounds/note-create.aiff")

    guard case .available(let metadata) = check else {
        Issue.record("expected the AIFF metadata to be available")
        return
    }
    #expect(metadata.isPCM)
    #expect(abs(metadata.duration - 1.0) < 0.0001)
}

@Test func cafContainerReportsPCMAndDuration() throws {
    let folder = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    try write(minimalManifest(), to: folder.appendingPathComponent("skin.json"))
    let sound = makeCAF(sampleRate: 8_000, bytesPerPacket: 2, framesPerPacket: 1, frames: 8_000)
    try write(sound, to: folder.appendingPathComponent("sounds/note-create.caf"))

    let result = load(folder)
    let check = result.assetChecker.sound("sounds/note-create.caf")

    guard case .available(let metadata) = check else {
        Issue.record("expected the CAF metadata to be available")
        return
    }
    #expect(metadata.isPCM)
    #expect(abs(metadata.duration - 1.0) < 0.0001)
}

@Test func unsupportedSoundContainerIsInvalidWithAReason() throws {
    let folder = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    try write(minimalManifest(), to: folder.appendingPathComponent("skin.json"))
    try write(Data("not a wave".utf8), to: folder.appendingPathComponent("sounds/note-create.wav"))

    let result = load(folder)
    let check = result.assetChecker.sound("sounds/note-create.wav")

    guard case .invalid(let reason) = check else {
        Issue.record("expected an invalid sound")
        return
    }
    #expect(!reason.isEmpty)
}

// MARK: - Real built-in skins

@Test func realBuiltInSkinsLoadThroughTheFolderLoader() throws {
    let root = repositoryRoot()
    for id in ["webby.clear", "webby.mono"] {
        let folder = root.appendingPathComponent("mac/Resources/Skins/\(id)")
        let data = try Data(contentsOf: folder.appendingPathComponent("skin.json"))
        let result = load(folder, origin: .builtIn)

        #expect(result.isAccepted, "\(id) was rejected")
        #expect(result.diagnostics.isEmpty, "\(id) produced diagnostics")
        #expect(result.manifest?.id == id)
        #expect(result.entries == [SkinEntry(path: "skin.json")])
        #expect(result.assetChecker.inventory() == [
            SkinAssetRecord(path: "skin.json", bytes: data.count),
        ])
    }
}

@Test func builtInSuppressionDoesNotHideExplicitMissingAsset() throws {
    let folder = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    try write("""
    {
      "formatVersion": 1,
      "id": "webby.example.surface",
      "name": "Surface",
      "author": "Test",
      "version": "1.0.0",
      "surface": {
        "image": {
          "element": "note-body",
          "insets": { "top": 1, "left": 1, "bottom": 1, "right": 1 }
        }
      }
    }
    """, to: folder.appendingPathComponent("skin.json"))

    let result = load(folder, origin: .builtIn)

    #expect(result.isAccepted)
    #expect(result.diagnostics.contains {
        $0.code == "missing-asset" && $0.group == "surface"
    })
}

// MARK: - Sound fixtures

private func appendASCII(_ string: String, to data: inout Data) {
    data.append(contentsOf: Array(string.utf8))
}

private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
}

private func appendUInt16BE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 24) & 0xFF))
}

private func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private func appendUInt64BE(_ value: UInt64, to data: inout Data) {
    for shift in stride(from: 56, through: 0, by: -8) {
        data.append(UInt8((value >> UInt64(shift)) & 0xFF))
    }
}

private func appendExtended80(_ value: Double, to data: inout Data) {
    guard value != 0 else {
        data.append(contentsOf: [UInt8](repeating: 0, count: 10))
        return
    }

    let exponent = Int(floor(log2(value)))
    let mantissa = value / pow(2, Double(exponent))
    let biasedExponent = exponent + 16_383
    let mantissaBits = UInt64((mantissa * pow(2, 63)).rounded())

    appendUInt16BE(UInt16(biasedExponent), to: &data)
    appendUInt64BE(mantissaBits, to: &data)
}

private func makeWAV(
    sampleRate: UInt32,
    channels: UInt16,
    bits: UInt16,
    frames: Int,
    format: UInt16 = 1
) -> Data {
    let bytesPerFrame = Int(channels) * Int(bits) / 8
    let byteRate = sampleRate * UInt32(bytesPerFrame)
    let dataBytes = frames * bytesPerFrame

    var data = Data()
    appendASCII("RIFF", to: &data)
    appendUInt32LE(UInt32(36 + dataBytes), to: &data)
    appendASCII("WAVE", to: &data)
    appendASCII("fmt ", to: &data)
    appendUInt32LE(16, to: &data)
    appendUInt16LE(format, to: &data)
    appendUInt16LE(channels, to: &data)
    appendUInt32LE(sampleRate, to: &data)
    appendUInt32LE(byteRate, to: &data)
    appendUInt16LE(UInt16(bytesPerFrame), to: &data)
    appendUInt16LE(bits, to: &data)
    appendASCII("data", to: &data)
    appendUInt32LE(UInt32(dataBytes), to: &data)
    data.append(contentsOf: [UInt8](repeating: 0, count: dataBytes))
    return data
}

private func makeAIFF(sampleRate: Double, frames: UInt32) -> Data {
    var comm = Data()
    appendUInt16BE(1, to: &comm)
    appendUInt32BE(frames, to: &comm)
    appendUInt16BE(16, to: &comm)
    appendExtended80(sampleRate, to: &comm)

    var ssnd = Data()
    appendUInt32BE(0, to: &ssnd)
    appendUInt32BE(0, to: &ssnd)

    var data = Data()
    appendASCII("FORM", to: &data)
    appendUInt32BE(UInt32(4 + 8 + comm.count + 8 + ssnd.count), to: &data)
    appendASCII("AIFF", to: &data)
    appendASCII("COMM", to: &data)
    appendUInt32BE(UInt32(comm.count), to: &data)
    data.append(comm)
    appendASCII("SSND", to: &data)
    appendUInt32BE(UInt32(ssnd.count), to: &data)
    data.append(ssnd)
    return data
}

private func makeCAF(
    sampleRate: Double,
    bytesPerPacket: UInt32,
    framesPerPacket: UInt32,
    frames: Int
) -> Data {
    var desc = Data()
    appendUInt64BE(sampleRate.bitPattern, to: &desc)
    appendASCII("lpcm", to: &desc)
    appendUInt32BE(0, to: &desc)
    appendUInt32BE(bytesPerPacket, to: &desc)
    appendUInt32BE(framesPerPacket, to: &desc)
    appendUInt32BE(1, to: &desc)
    appendUInt32BE(16, to: &desc)

    let dataBytes = frames * Int(bytesPerPacket)

    var data = Data()
    appendASCII("caff", to: &data)
    appendUInt16BE(1, to: &data)
    appendUInt16BE(0, to: &data)
    appendASCII("desc", to: &data)
    appendUInt64BE(UInt64(desc.count), to: &data)
    data.append(desc)
    appendASCII("data", to: &data)
    appendUInt64BE(UInt64(dataBytes), to: &data)
    data.append(contentsOf: [UInt8](repeating: 0, count: dataBytes))
    return data
}
