import CryptoKit
import Foundation
import Testing
import WebbyCore
@testable import WebbySkinArchive

private let bodyPath = "images/note-body.png"
private let retinaBodyPath = "images/note-body@2x.png"
private let soundPath = "sounds/note-create.wav"

private func sha256(of url: URL) throws -> String {
    let digest = SHA256.hash(data: try Data(contentsOf: url))
    return digest.map { String(format: "%02x", $0) }.joined()
}

private func exportFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbySkinExport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: folder.appendingPathComponent("images"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: folder.appendingPathComponent("sounds"),
        withIntermediateDirectories: true
    )

    let manifest = archiveManifest(extra: archiveSurfaceGroup + archiveSoundsGroup)
    try manifest.write(to: folder.appendingPathComponent("skin.json"))
    try onePixelPNG.write(to: folder.appendingPathComponent(bodyPath))
    try onePixelPNG.write(to: folder.appendingPathComponent(retinaBodyPath))
    try makePCMWAV(sampleRate: 8_000, channels: 1, bits: 16, frames: 8_000)
        .write(to: folder.appendingPathComponent(soundPath))
    return folder
}

@Test func exportingTheSameFolderTwiceIsByteIdentical() throws {
    let folder = try exportFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let directory = folder.deletingLastPathComponent()
    let first = directory.appendingPathComponent("first-\(UUID().uuidString).webbyskin")
    let second = directory.appendingPathComponent("second-\(UUID().uuidString).webbyskin")
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }

    try SkinArchiveExporter.export(folder: folder, to: first, availableBaseIDs: ["webby.clear"])

    // Change every timestamp and creation order before the second export.
    for path in ["skin.json", bodyPath, retinaBodyPath, soundPath] {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
            ofItemAtPath: url.path
        )
    }
    try SkinArchiveExporter.export(folder: folder, to: second, availableBaseIDs: ["webby.clear"])

    #expect(try sha256(of: first) == sha256(of: second))
    #expect(try Data(contentsOf: first) == Data(contentsOf: second))
}

@Test func exportedArchiveImportsAndRoundTripsToIdenticalBytes() throws {
    let folder = try exportFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let directory = folder.deletingLastPathComponent()
    let first = directory.appendingPathComponent("round-1-\(UUID().uuidString).webbyskin")
    let second = directory.appendingPathComponent("round-2-\(UUID().uuidString).webbyskin")
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }

    try SkinArchiveExporter.export(folder: folder, to: first, availableBaseIDs: ["webby.clear"])
    let data = try Data(contentsOf: first)

    let preflight = try SkinArchivePreflight.check(data)
    #expect(preflight.entries.map(\.path) == [
        "images/note-body.png",
        "images/note-body@2x.png",
        "skin.json",
        "sounds/note-create.wav",
    ])

    let harness = try StagedExtractionHarness()
    defer { harness.cleanup() }
    let staged = try harness.extract(data)
    let validation = SkinArchiveStaging.validate(staged, availableBaseIDs: ["webby.clear"])
    #expect(validation.isAccepted)
    #expect(validation.groups[.surface] == .usable)
    #expect(validation.groups[.sounds] == .usable)

    try SkinArchiveExporter.export(
        folder: staged.root,
        to: second,
        availableBaseIDs: ["webby.clear"]
    )
    try staged.discard()

    #expect(try sha256(of: first) == sha256(of: second))
}

@Test func exportRefusesToOverwriteAnExistingDestination() throws {
    let folder = try exportFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let outputDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbySkinExportOutput-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: outputDirectory,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: outputDirectory) }
    let destination = outputDirectory
        .appendingPathComponent("existing.webbyskin")

    try Data("occupied".utf8).write(to: destination)
    do {
        try SkinArchiveExporter.export(
            folder: folder,
            to: destination,
            availableBaseIDs: ["webby.clear"]
        )
        Issue.record("expected an existing destination to be refused")
    } catch let error as SkinArchiveError {
        guard case .destinationExists = error else {
            Issue.record("expected destinationExists, got \(error)")
            return
        }
    }
    #expect(try Data(contentsOf: destination) == Data("occupied".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
        == ["existing.webbyskin"])
}

@Test func exportRejectsMediaThatDoesNotDecode() throws {
    let folder = try exportFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data(repeating: 0x41, count: 64).write(to: folder.appendingPathComponent(bodyPath))
    let destination = folder.deletingLastPathComponent()
        .appendingPathComponent("rejected-\(UUID().uuidString).webbyskin")
    defer { try? FileManager.default.removeItem(at: destination) }

    do {
        try SkinArchiveExporter.export(
            folder: folder,
            to: destination,
            availableBaseIDs: ["webby.clear"]
        )
        Issue.record("expected the undecodable image to be rejected")
    } catch let error as SkinArchiveError {
        guard case .exportSourceRejected(let reason) = error else {
            Issue.record("expected exportSourceRejected, got \(error)")
            return
        }
        #expect(reason.contains(bodyPath))
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func exportRejectsAFolderWithASymlink() throws {
    let folder = try exportFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.deletingLastPathComponent()
        .appendingPathComponent("outside-\(UUID().uuidString).png")
    try onePixelPNG.write(to: target)
    defer { try? FileManager.default.removeItem(at: target) }
    let link = folder.appendingPathComponent("images/note-header.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let destination = folder.deletingLastPathComponent()
        .appendingPathComponent("symlink-\(UUID().uuidString).webbyskin")
    defer { try? FileManager.default.removeItem(at: destination) }

    do {
        try SkinArchiveExporter.export(
            folder: folder,
            to: destination,
            availableBaseIDs: ["webby.clear"]
        )
        Issue.record("expected a symlinked skin folder to be rejected")
    } catch let error as SkinArchiveError {
        guard case .exportSourceRejected(let reason) = error else {
            Issue.record("expected exportSourceRejected, got \(error)")
            return
        }
        #expect(reason.contains("symlink"))
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func exportRejectsAnInvalidManifest() throws {
    let folder = try exportFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data("{}".utf8).write(to: folder.appendingPathComponent("skin.json"))
    let destination = folder.deletingLastPathComponent()
        .appendingPathComponent("badmanifest-\(UUID().uuidString).webbyskin")
    defer { try? FileManager.default.removeItem(at: destination) }

    do {
        try SkinArchiveExporter.export(
            folder: folder,
            to: destination,
            availableBaseIDs: ["webby.clear"]
        )
        Issue.record("expected an invalid manifest to be rejected")
    } catch let error as SkinArchiveError {
        guard case .exportSourceRejected = error else {
            Issue.record("expected exportSourceRejected, got \(error)")
            return
        }
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func exportWritesTheBytesItValidated() throws {
    let folder = try exportFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let destination = folder.deletingLastPathComponent()
        .appendingPathComponent("snapshot-\(UUID().uuidString).webbyskin")
    defer { try? FileManager.default.removeItem(at: destination) }

    let manifestBytes = try Data(contentsOf: folder.appendingPathComponent("skin.json"))
    try SkinArchiveExporter.export(
        folder: folder,
        to: destination,
        availableBaseIDs: ["webby.clear"]
    )

    let harness = try StagedExtractionHarness()
    defer { harness.cleanup() }
    let staged = try harness.extract(try Data(contentsOf: destination))
    defer { try? staged.discard() }

    #expect(try Data(contentsOf: staged.root.appendingPathComponent("skin.json")) == manifestBytes)
    #expect(try Data(contentsOf: staged.root.appendingPathComponent(bodyPath)) == onePixelPNG)
}

@Test func exportIntoAnAtLimitFolderDoesNotPushItOverTheEntryCap() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbySkinExportCap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }

    try archiveManifest().write(to: folder.appendingPathComponent("skin.json"))
    // 399 directories plus skin.json is exactly the 400-entry visit cap.
    for index in 0..<399 {
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent(String(format: "d%03d", index)),
            withIntermediateDirectories: false
        )
    }

    let destination = folder.appendingPathComponent("exported.webbyskin")
    try SkinArchiveExporter.export(
        folder: folder,
        to: destination,
        availableBaseIDs: ["webby.clear"]
    )
    #expect(FileManager.default.fileExists(atPath: destination.path))
    #expect(try SkinArchivePreflight.check(Data(contentsOf: destination))
        .entries.map(\.path) == ["skin.json"])
}

@Test func exportRejectsOversizedSourceFilesWithABoundedRead() throws {
    let folder = try exportFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data(repeating: 0x41, count: SkinArchiveLimits.imageByteCount + 1)
        .write(to: folder.appendingPathComponent(bodyPath))
    let destination = folder.deletingLastPathComponent()
        .appendingPathComponent("oversized-\(UUID().uuidString).webbyskin")
    defer { try? FileManager.default.removeItem(at: destination) }

    do {
        try SkinArchiveExporter.export(
            folder: folder,
            to: destination,
            availableBaseIDs: ["webby.clear"]
        )
        Issue.record("expected the oversized image to be rejected")
    } catch let error as SkinArchiveError {
        guard case .declaredSizeExceeded(let path, let declared, let limit) = error else {
            Issue.record("expected declaredSizeExceeded, got \(error)")
            return
        }
        #expect(path == bodyPath)
        #expect(declared > UInt64(limit))
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}
