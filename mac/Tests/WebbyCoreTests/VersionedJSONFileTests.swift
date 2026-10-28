import Foundation
import Testing
@testable import WebbyCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000.789)
private let fixedDateStamp = "20231114-221320-789"
private let fixedSuffix: @Sendable (Int) -> String = { _ in "0123abcd" }

private struct TestContent: Codable, Equatable, Sendable {
    var title: String
    var count: Int
}

private let defaultContent = TestContent(title: "default", count: 0)
private let loadedContent = TestContent(title: "loaded", count: 7)

private struct CodecDocument: Codable, Equatable, Sendable {
    var notes: [String]
    var workspaces: [String]
}

private struct CodecRoot: Codable {
    var version: Int
    var notes: [String]
    var workspaces: [String]
}

private struct DatedDocument: Codable, Equatable, Sendable {
    var notes: [String]
    var updatedAt: Date
}

private struct DatedRoot: Codable {
    var version: Int
    var notes: [String]
    var updatedAt: Date
}

private let defaultCodecDocument = CodecDocument(notes: [], workspaces: [])

private func makeCodecDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
    return decoder
}

private func makeCodecEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    return encoder
}

private let decodeCodecDocument: @Sendable (Data, Int) throws -> CodecDocument = { data, _ in
    let root = try makeCodecDecoder().decode(CodecRoot.self, from: data)
    return CodecDocument(notes: root.notes, workspaces: root.workspaces)
}

private let encodeCodecDocument: @Sendable (CodecDocument, Int) throws -> Data = { document, version in
    let encoder = makeCodecEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let root = CodecRoot(version: version, notes: document.notes, workspaces: document.workspaces)
    return try encoder.encode(root)
}

private let decodeDatedDocument: @Sendable (Data, Int) throws -> DatedDocument = { data, _ in
    let root = try makeCodecDecoder().decode(DatedRoot.self, from: data)
    return DatedDocument(notes: root.notes, updatedAt: root.updatedAt)
}

private let encodeDatedDocument: @Sendable (DatedDocument, Int) throws -> Data = { document, version in
    let encoder = makeCodecEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let root = DatedRoot(version: version, notes: document.notes, updatedAt: document.updatedAt)
    return try encoder.encode(root)
}

private struct InjectedWriteError: Error {}

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbyVersionedJSONFileTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func removeTempDirectory(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
}

private func write(_ contents: String, to url: URL) throws {
    try Data(contents.utf8).write(to: url)
}

private func fileNames(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}

@Test func missingFileLeavesDefaultsWritableAndCreatesNothing() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root
        .appendingPathComponent("nested", isDirectory: true)
        .appendingPathComponent("notes.json")
    let file = VersionedJSONFile(fileURL: url, defaultContent: defaultContent, now: { fixedDate })

    #expect(file.fileURL == url)
    #expect(file.content == defaultContent)
    #expect(file.mode == .writable)
    #expect(file.outcome == .missing)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
}

@Test func matchingVersionLoadsContentWritable() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let contents = Data(#"{"version":1,"content":{"title":"loaded","count":7}}"#.utf8)
    try contents.write(to: url)

    let file = VersionedJSONFile(fileURL: url, defaultContent: defaultContent, now: { fixedDate })

    #expect(file.content == loadedContent)
    #expect(file.mode == .writable)
    #expect(file.outcome == .loaded)
    #expect(try Data(contentsOf: url) == contents)
    #expect(try fileNames(in: root) == ["notes.json"])
}

@Test func symlinkToValidFileLoadsAndSavesThroughTarget() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let target = root.appendingPathComponent("real-notes.json")
    let url = root.appendingPathComponent("notes.json")
    let originalContents = Data(#"{"version":1,"content":{"title":"loaded","count":7}}"#.utf8)
    try originalContents.write(to: target)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

    var file = VersionedJSONFile(fileURL: url, defaultContent: defaultContent, now: { fixedDate })

    #expect(file.mode == .writable)
    #expect(file.outcome == .loaded)
    #expect(file.content == loadedContent)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == target.path)

    let savedContent = TestContent(title: "saved", count: 11)
    file.updateContent(savedContent)
    try file.save()

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == target.path)
    #expect(try Data(contentsOf: target) != originalContents)
    let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any])
    #expect(object["version"] as? Int == VersionedJSONFile<TestContent>.currentVersion)
    let encodedContent = try #require(object["content"] as? [String: Any])
    #expect(encodedContent["title"] as? String == savedContent.title)
    #expect(encodedContent["count"] as? Int == savedContent.count)
    #expect(try fileNames(in: root) == ["notes.json", "real-notes.json"])
}

@Test func olderVersionLoadsContentWritable() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    try write(#"{"version":0,"content":{"title":"loaded","count":7}}"#, to: url)

    let file = VersionedJSONFile(fileURL: url, defaultContent: defaultContent, now: { fixedDate })

    #expect(file.content == loadedContent)
    #expect(file.mode == .writable)
    #expect(file.outcome == .loaded)
    #expect(try fileNames(in: root) == ["notes.json"])
}

@Test func newerVersionIsReadOnlyAndUntouched() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let contents = Data(#"{"version":99,"unrecognized":"payload without content"}"#.utf8)
    try contents.write(to: url)

    var file = VersionedJSONFile(fileURL: url, defaultContent: defaultContent, now: { fixedDate })

    #expect(
        file.mode == .readOnly(
            .newerVersion(found: 99, supported: VersionedJSONFile<TestContent>.currentVersion)
        )
    )
    #expect(file.outcome == .newer(version: 99))
    #expect(file.content == defaultContent)
    #expect(try Data(contentsOf: url) == contents)
    #expect(try fileNames(in: root) == ["notes.json"])

    do {
        try file.save()
        Issue.record("Expected saving a newer file to fail")
    } catch let error as VersionedJSONFile<TestContent>.SaveError {
        #expect(
            error == .readOnly(
                .newerVersion(found: 99, supported: VersionedJSONFile<TestContent>.currentVersion)
            )
        )
    }
    #expect(try Data(contentsOf: url) == contents)
    #expect(try fileNames(in: root) == ["notes.json"])
}

@Test func malformedJSONIsRecoveredWithClockAndSuffixInjection() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let contents = Data("{not valid json".utf8)
    try contents.write(to: url)
    let expected = root.appendingPathComponent("notes.corrupt-\(fixedDateStamp)-0123abcd.json")

    let file = VersionedJSONFile(
        fileURL: url,
        defaultContent: defaultContent,
        now: { fixedDate },
        randomSuffix: fixedSuffix
    )

    #expect(file.mode == .writable)
    #expect(file.content == defaultContent)
    #expect(file.outcome == .recovered(at: expected))
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(try Data(contentsOf: expected) == contents)
    #expect(try fileNames(in: root) == [expected.lastPathComponent])
}

@Test func invalidSchemaIsRecovered() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let contents = Data(#"{"version":1,"content":{"title":42,"count":"not a number"}}"#.utf8)
    try contents.write(to: url)
    let expected = root.appendingPathComponent("notes.corrupt-\(fixedDateStamp)-0123abcd.json")

    let file = VersionedJSONFile(
        fileURL: url,
        defaultContent: defaultContent,
        now: { fixedDate },
        randomSuffix: fixedSuffix
    )

    #expect(file.mode == .writable)
    #expect(file.content == defaultContent)
    #expect(file.outcome == .recovered(at: expected))
    #expect(try Data(contentsOf: expected) == contents)
    #expect(try fileNames(in: root) == [expected.lastPathComponent])
}

@Test func corruptNameUsesSourceFileName() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("settings.json")
    try write("{broken", to: url)
    let expected = root.appendingPathComponent("settings.corrupt-\(fixedDateStamp)-0123abcd.json")

    let file = VersionedJSONFile(
        fileURL: url,
        defaultContent: defaultContent,
        now: { fixedDate },
        randomSuffix: fixedSuffix
    )

    #expect(file.outcome == .recovered(at: expected))
    #expect(try fileNames(in: root) == [expected.lastPathComponent])
}

@Test func secondCorruptionInSameMillisecondGetsDistinctName() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let suffix: @Sendable (Int) -> String = { attempt in
        attempt == 0 ? "aaaaaaaa" : "bbbbbbbb"
    }
    let first = root.appendingPathComponent("notes.corrupt-\(fixedDateStamp)-aaaaaaaa.json")
    let second = root.appendingPathComponent("notes.corrupt-\(fixedDateStamp)-bbbbbbbb.json")

    try write("first corrupt", to: url)
    let firstFile = VersionedJSONFile(
        fileURL: url,
        defaultContent: defaultContent,
        now: { fixedDate },
        randomSuffix: suffix
    )
    #expect(firstFile.outcome == .recovered(at: first))

    try write("second corrupt", to: url)
    let secondFile = VersionedJSONFile(
        fileURL: url,
        defaultContent: defaultContent,
        now: { fixedDate },
        randomSuffix: suffix
    )
    #expect(secondFile.outcome == .recovered(at: second))

    #expect(try Data(contentsOf: first) == Data("first corrupt".utf8))
    #expect(try Data(contentsOf: second) == Data("second corrupt".utf8))
    #expect(
        try fileNames(in: root)
            == [first.lastPathComponent, second.lastPathComponent]
    )
}

@Test func defaultCorruptNameHasEightHexadecimalSuffix() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    try write("{broken", to: url)

    let file = VersionedJSONFile(
        fileURL: url,
        defaultContent: defaultContent,
        now: { fixedDate }
    )

    guard case .recovered(let destination) = file.outcome else {
        Issue.record("Expected the corrupt file to be moved aside")
        return
    }
    let name = destination.lastPathComponent
    #expect(name.hasPrefix("notes.corrupt-\(fixedDateStamp)-"))
    #expect(name.hasSuffix(".json"))
    let suffix = name
        .dropFirst("notes.corrupt-\(fixedDateStamp)-".count)
        .dropLast(".json".count)
    #expect(suffix.count == 8)
    #expect(suffix.allSatisfy { $0.isHexDigit })
}

@Test func notARegularFileIsReadOnlyAndUntouched() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

    let file = VersionedJSONFile(fileURL: url, defaultContent: defaultContent, now: { fixedDate })

    guard case .readOnly(.unreadable(let reason)) = file.mode else {
        Issue.record("Expected a non-regular file to open read-only")
        return
    }
    #expect(!reason.isEmpty)
    #expect(file.outcome == .unreadable)
    #expect(file.content == defaultContent)
    #expect(try fileNames(in: root) == ["notes.json"])
}

@Test func symlinkToDirectoryIsReadOnlyAndUntouched() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let target = root.appendingPathComponent("target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let url = root.appendingPathComponent("notes.json")
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

    let file = VersionedJSONFile(fileURL: url, defaultContent: defaultContent, now: { fixedDate })

    guard case .readOnly(.unreadable(let reason)) = file.mode else {
        Issue.record("Expected a symlink to a directory to open read-only")
        return
    }
    #expect(!reason.isEmpty)
    #expect(file.outcome == .unreadable)
    #expect(file.content == defaultContent)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == target.path)
    #expect(try fileNames(in: root) == ["notes.json", "target"])
}

@Test func danglingSymlinkIsReadOnlyAndUntouched() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let target = root.appendingPathComponent("does-not-exist.json")
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

    var file = VersionedJSONFile(fileURL: url, defaultContent: defaultContent, now: { fixedDate })

    guard case .readOnly(.unreadable(let reason)) = file.mode else {
        Issue.record("Expected a dangling symlink to open read-only")
        return
    }
    #expect(!reason.isEmpty)
    #expect(file.outcome == .unreadable)
    #expect(file.content == defaultContent)

    do {
        try file.save()
        Issue.record("Expected saving a dangling symlink to fail")
    } catch let error as VersionedJSONFile<TestContent>.SaveError {
        guard case .readOnly(.unreadable) = error else {
            Issue.record("Expected the save error to be read-only unreadable")
            return
        }
    }

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == target.path)
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(try fileNames(in: root) == ["notes.json"])
}

@Test func unsearchableParentDirectoryIsReadOnlyAndByteIdentical() throws {
    guard geteuid() != 0 else { return }

    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let locked = root.appendingPathComponent("locked", isDirectory: true)
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
    let url = locked.appendingPathComponent("notes.json")
    let contents = Data(#"{"version":1,"content":{"title":"loaded","count":7}}"#.utf8)
    try contents.write(to: url)

    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
    }

    var file = VersionedJSONFile(fileURL: url, defaultContent: defaultContent, now: { fixedDate })

    guard case .readOnly(.unreadable(let reason)) = file.mode else {
        Issue.record("Expected an unsearchable parent directory to open read-only")
        return
    }
    #expect(!reason.isEmpty)
    #expect(file.outcome == .unreadable)
    #expect(file.content == defaultContent)

    do {
        try file.save()
        Issue.record("Expected saving inside an unsearchable directory to fail")
    } catch let error as VersionedJSONFile<TestContent>.SaveError {
        guard case .readOnly(.unreadable) = error else {
            Issue.record("Expected the save error to be read-only unreadable")
            return
        }
    }

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
    #expect(try Data(contentsOf: url) == contents)
    #expect(try fileNames(in: locked) == ["notes.json"])
}

@Test func missingFileInExistingDirectoryIsMissingAndWritable() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let file = VersionedJSONFile(fileURL: url, defaultContent: defaultContent, now: { fixedDate })

    #expect(file.mode == .writable)
    #expect(file.outcome == .missing)
    #expect(file.content == defaultContent)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(try fileNames(in: root).isEmpty)
}

@Test func unreadableFileIsReadOnlyAndByteIdentical() throws {
    guard geteuid() != 0 else { return }

    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let contents = Data(#"{"version":1,"content":{"title":"loaded","count":7}}"#.utf8)
    try contents.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    var file = VersionedJSONFile(fileURL: url, defaultContent: defaultContent, now: { fixedDate })

    guard case .readOnly(.unreadable(let reason)) = file.mode else {
        Issue.record("Expected an unreadable file to open read-only")
        return
    }
    #expect(!reason.isEmpty)
    #expect(file.outcome == .unreadable)
    #expect(file.content == defaultContent)

    do {
        try file.save()
        Issue.record("Expected saving an unreadable file to fail")
    } catch let error as VersionedJSONFile<TestContent>.SaveError {
        guard case .readOnly(.unreadable) = error else {
            Issue.record("Expected the save error to be read-only unreadable")
            return
        }
    }

    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    #expect(try Data(contentsOf: url) == contents)
    #expect(try fileNames(in: root) == ["notes.json"])
}

@Test func failedMoveIsReadOnlyAndLeavesOriginalUntouched() throws {
    guard geteuid() != 0 else { return }

    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let contents = Data("{broken".utf8)
    try contents.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    let file = VersionedJSONFile(
        fileURL: url,
        defaultContent: defaultContent,
        now: { fixedDate },
        randomSuffix: fixedSuffix
    )

    guard case .readOnly(.unreadable(let reason)) = file.mode else {
        Issue.record("Expected a failed move to open read-only")
        return
    }
    #expect(!reason.isEmpty)
    #expect(file.outcome == .unreadable)
    #expect(file.content == defaultContent)

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    #expect(try Data(contentsOf: url) == contents)
    #expect(try fileNames(in: root) == ["notes.json"])
}

@Test func saveWritesVersionedEnvelopeAndRoundTrips() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root
        .appendingPathComponent("deep", isDirectory: true)
        .appendingPathComponent("notes.json")
    var file = VersionedJSONFile(fileURL: url, defaultContent: defaultContent, now: { fixedDate })
    file.updateContent(loadedContent)

    try file.save()

    let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(object["version"] as? Int == VersionedJSONFile<TestContent>.currentVersion)
    let encodedContent = try #require(object["content"] as? [String: Any])
    #expect(encodedContent["title"] as? String == loadedContent.title)
    #expect(encodedContent["count"] as? Int == loadedContent.count)

    var reloaded = VersionedJSONFile(fileURL: url, defaultContent: defaultContent, now: { fixedDate })
    #expect(reloaded.content == loadedContent)
    #expect(reloaded.mode == .writable)
    #expect(reloaded.outcome == .loaded)

    try reloaded.save()
    let savedAgain = try Data(contentsOf: url)
    #expect(try JSONSerialization.jsonObject(with: savedAgain) as? [String: Any] != nil)
}

@Test func contentKeyPreservesAnExistingTopLevelShape() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    var file = VersionedJSONFile(
        fileURL: url,
        defaultContent: loadedContent,
        contentKey: "notes",
        now: { fixedDate }
    )

    try file.save()

    let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(object["version"] as? Int == VersionedJSONFile<TestContent>.currentVersion)
    #expect(object["notes"] is [String: Any])
    #expect(object["content"] == nil)

    let reloaded = VersionedJSONFile(
        fileURL: url,
        defaultContent: TestContent(title: "", count: 0),
        contentKey: "notes",
        now: { fixedDate }
    )
    #expect(reloaded.content == loadedContent)
    #expect(reloaded.outcome == .loaded)
}

@Test func scalarContentRoundTrips() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("scalar.json")
    var file = VersionedJSONFile(fileURL: url, defaultContent: 42, now: { fixedDate })

    try file.save()

    let reloaded = VersionedJSONFile(fileURL: url, defaultContent: 0, now: { fixedDate })
    #expect(reloaded.content == 42)
    #expect(reloaded.outcome == .loaded)
}

@Test func convenienceInitKeepsVersionOneAndRejectsVersionTwo() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    var file = VersionedJSONFile(fileURL: url, defaultContent: defaultContent, now: { fixedDate })
    #expect(file.supportedVersion == 1)
    #expect(VersionedJSONFile<TestContent>.currentVersion == 1)
    try file.save()

    let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(saved["version"] as? Int == 1)

    let newerURL = root.appendingPathComponent("newer.json")
    let newerContents = Data(#"{"version":2,"content":{"title":"future","count":0}}"#.utf8)
    try newerContents.write(to: newerURL)
    var newer = VersionedJSONFile(fileURL: newerURL, defaultContent: defaultContent, now: { fixedDate })

    #expect(newer.mode == .readOnly(.newerVersion(found: 2, supported: 1)))
    #expect(newer.content == defaultContent)

    do {
        try newer.save()
        Issue.record("Expected a version 2 file to reject saving")
    } catch let error as VersionedJSONFile<TestContent>.SaveError {
        #expect(error == .readOnly(.newerVersion(found: 2, supported: 1)))
    }
    #expect(try Data(contentsOf: newerURL) == newerContents)
}

@Test func customCodecWritesUnwrappedVersionTwo() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let source = Data(#"{"version":1,"notes":["alpha"],"workspaces":["one"]}"#.utf8)
    try source.write(to: url)

    var file = VersionedJSONFile(
        fileURL: url,
        defaultContent: defaultCodecDocument,
        supportedVersion: 2,
        decode: decodeCodecDocument,
        encode: encodeCodecDocument,
        backupBeforeUpgrade: true,
        now: { fixedDate },
        randomSuffix: fixedSuffix
    )

    #expect(file.supportedVersion == 2)
    #expect(file.content == CodecDocument(notes: ["alpha"], workspaces: ["one"]))
    #expect(file.mode == .writable)
    #expect(file.outcome == .loaded)
    #expect(file.migrationBackupURL == nil)
    #expect(try fileNames(in: root) == ["notes.json"])

    file.updateContent(CodecDocument(notes: ["beta"], workspaces: ["two"]))
    try file.save()

    let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(object["version"] as? Int == 2)
    #expect(object["notes"] as? [String] == ["beta"])
    #expect(object["workspaces"] as? [String] == ["two"])
    #expect(object["content"] == nil)
    #expect(file.migrationBackupURL == root.appendingPathComponent("notes.v1-\(fixedDateStamp)-0123abcd.json"))
}

@Test func datedContentRoundTripsThroughCustomCodec() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let loadedAt = Date(timeIntervalSince1970: 1_700_000_000.123456)
    let savedAt = Date(timeIntervalSince1970: 1_700_000_100.987654)
    let source = try makeCodecEncoder().encode(
        DatedRoot(version: 1, notes: ["alpha"], updatedAt: loadedAt)
    )
    try source.write(to: url)

    var file = VersionedJSONFile(
        fileURL: url,
        defaultContent: DatedDocument(notes: [], updatedAt: Date(timeIntervalSince1970: 0)),
        supportedVersion: 2,
        decode: decodeDatedDocument,
        encode: encodeDatedDocument,
        now: { fixedDate },
        randomSuffix: fixedSuffix
    )

    #expect(file.content == DatedDocument(notes: ["alpha"], updatedAt: loadedAt))
    file.updateContent(DatedDocument(notes: ["beta"], updatedAt: savedAt))
    try file.save()

    let decoded = try decodeDatedDocument(try Data(contentsOf: url), 2)
    #expect(decoded.updatedAt == savedAt)
    #expect(decoded.notes == ["beta"])
}

@Test func migrationBackupKeepsOriginalBytesExactly() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let sourceText = "{\n  \"version\" : 1,\n  \"notes\" : [ \"alpha\" ],\n  \"workspaces\" : []\n}\n"
    let source = Data(sourceText.utf8)
    try source.write(to: url)
    let backup = root.appendingPathComponent("notes.v1-\(fixedDateStamp)-0123abcd.json")

    var file = VersionedJSONFile(
        fileURL: url,
        defaultContent: defaultCodecDocument,
        supportedVersion: 2,
        decode: decodeCodecDocument,
        encode: encodeCodecDocument,
        backupBeforeUpgrade: true,
        now: { fixedDate },
        randomSuffix: fixedSuffix
    )

    #expect(file.migrationBackupURL == nil)
    #expect(try fileNames(in: root) == ["notes.json"])

    file.updateContent(CodecDocument(notes: ["beta"], workspaces: []))
    try file.save()

    #expect(file.migrationBackupURL == backup)
    #expect(try Data(contentsOf: backup) == source)
    #expect(try fileNames(in: root) == ["notes.json", backup.lastPathComponent])
}

@Test func migrationBackupIsOwnerOnly() throws {
    guard geteuid() != 0 else { return }

    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }
    let url = root.appendingPathComponent("notes.json")
    try Data(#"{"version":1,"notes":["private"],"workspaces":[]}"#.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let previous = umask(0o022)
    defer { umask(previous) }

    var file = VersionedJSONFile(
        fileURL: url, defaultContent: defaultCodecDocument, supportedVersion: 2,
        decode: decodeCodecDocument, encode: encodeCodecDocument, backupBeforeUpgrade: true,
        now: { fixedDate }, randomSuffix: fixedSuffix
    )
    file.updateContent(CodecDocument(notes: ["converted"], workspaces: []))
    try file.save()

    let backup = try #require(file.migrationBackupURL)
    let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(try fileNames(in: root).filter { $0.hasSuffix(".tmp") }.isEmpty)
}

@Test func migrationBackupRetriesCollisionsWithoutOverwriting() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let source = Data(#"{"version":1,"notes":["alpha"],"workspaces":[]}"#.utf8)
    try source.write(to: url)

    let occupied = root.appendingPathComponent("notes.v1-\(fixedDateStamp)-aaaa1111.json")
    let occupiedContents = Data("occupied".utf8)
    try occupiedContents.write(to: occupied)
    let dangling = root.appendingPathComponent("notes.v1-\(fixedDateStamp)-bbbb2222.json")
    let danglingTarget = root.appendingPathComponent("missing-backup-target.json")
    try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: danglingTarget)

    let expected = root.appendingPathComponent("notes.v1-\(fixedDateStamp)-cccc3333.json")
    let suffix: @Sendable (Int) -> String = { attempt in
        switch attempt {
        case 0: return "aaaa1111"
        case 1: return "bbbb2222"
        default: return "cccc3333"
        }
    }

    var file = VersionedJSONFile(
        fileURL: url,
        defaultContent: defaultCodecDocument,
        supportedVersion: 2,
        decode: decodeCodecDocument,
        encode: encodeCodecDocument,
        backupBeforeUpgrade: true,
        now: { fixedDate },
        randomSuffix: suffix
    )
    file.updateContent(CodecDocument(notes: ["beta"], workspaces: []))
    try file.save()

    #expect(file.migrationBackupURL == expected)
    #expect(try Data(contentsOf: expected) == source)
    #expect(try Data(contentsOf: occupied) == occupiedContents)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path) == danglingTarget.path)
    #expect(!FileManager.default.fileExists(atPath: danglingTarget.path))
    #expect(
        try fileNames(in: root)
            == ["notes.json", expected.lastPathComponent, occupied.lastPathComponent, dangling.lastPathComponent].sorted()
    )
}

@Test func backupPermissionFailureAbortsSaveAndKeepsOriginal() throws {
    guard geteuid() != 0 else { return }

    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let source = Data(#"{"version":1,"notes":["alpha"],"workspaces":[]}"#.utf8)
    try source.write(to: url)

    var file = VersionedJSONFile(
        fileURL: url,
        defaultContent: defaultCodecDocument,
        supportedVersion: 2,
        decode: decodeCodecDocument,
        encode: encodeCodecDocument,
        backupBeforeUpgrade: true,
        now: { fixedDate },
        randomSuffix: fixedSuffix
    )
    file.updateContent(CodecDocument(notes: ["beta"], workspaces: []))

    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    do {
        try file.save()
        Issue.record("Expected creating the migration backup to fail")
    } catch {
        #expect(!(error is VersionedJSONFile<CodecDocument>.SaveError))
    }

    #expect(file.migrationBackupURL == nil)
    #expect(try Data(contentsOf: url) == source)
    #expect(try fileNames(in: root) == ["notes.json"])
}

@Test func injectedAtomicWriteFailureRetainsBackupForRetry() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let source = Data(#"{"version":1,"notes":["alpha"],"workspaces":[]}"#.utf8)
    try source.write(to: url)

    let marker = root.appendingPathComponent("write-attempted")
    let suffix: @Sendable (Int) -> String = { attempt in
        attempt == 0 ? "aaaa1111" : "bbbb2222"
    }
    let atomicWrite: @Sendable (Data, URL) throws -> Void = { data, destination in
        if !FileManager.default.fileExists(atPath: marker.path) {
            try Data().write(to: marker)
            throw InjectedWriteError()
        }
        try data.write(to: destination, options: .atomic)
    }

    var file = VersionedJSONFile(
        fileURL: url,
        defaultContent: defaultCodecDocument,
        supportedVersion: 2,
        decode: decodeCodecDocument,
        encode: encodeCodecDocument,
        backupBeforeUpgrade: true,
        now: { fixedDate },
        randomSuffix: suffix,
        atomicWrite: atomicWrite
    )
    file.updateContent(CodecDocument(notes: ["beta"], workspaces: []))

    do {
        try file.save()
        Issue.record("Expected the first atomic write to fail")
    } catch is InjectedWriteError {
    }

    let backup = root.appendingPathComponent("notes.v1-\(fixedDateStamp)-aaaa1111.json")
    #expect(file.migrationBackupURL == backup)
    #expect(try Data(contentsOf: backup) == source)
    #expect(try Data(contentsOf: url) == source)

    try file.save()

    let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(object["version"] as? Int == 2)
    #expect(object["notes"] as? [String] == ["beta"])
    let backups = try fileNames(in: root).filter { $0.hasPrefix("notes.v1-") }
    #expect(backups == [backup.lastPathComponent])
}

@Test func migratedRetryDoesNotOverwriteAnExternalEdit() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }
    let url = root.appendingPathComponent("notes.json")
    let original = Data(#"{"version":1,"notes":["original"],"workspaces":[]}"#.utf8)
    try original.write(to: url)
    let marker = root.appendingPathComponent("allow-write")
    var file = VersionedJSONFile(
        fileURL: url, defaultContent: defaultCodecDocument, supportedVersion: 2,
        decode: decodeCodecDocument, encode: encodeCodecDocument, backupBeforeUpgrade: true,
        atomicWrite: { data, destination in
            guard FileManager.default.fileExists(atPath: marker.path) else { throw InjectedWriteError() }
            try data.write(to: destination, options: .atomic)
        }
    )
    #expect(throws: InjectedWriteError.self) { try file.save() }
    let external = Data(#"{"version":1,"notes":["external edit"],"workspaces":[]}"#.utf8)
    try external.write(to: url)
    try Data().write(to: marker)
    #expect(throws: VersionedJSONFile<CodecDocument>.SaveError.sourceChanged) { try file.save() }
    #expect(try Data(contentsOf: url) == external)
}

@Test func migratedRetryRequiresAnIntactBackup() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }
    let url = root.appendingPathComponent("notes.json")
    let original = Data(#"{"version":1,"notes":["original"],"workspaces":[]}"#.utf8)
    try original.write(to: url)
    let marker = root.appendingPathComponent("allow-write")
    var file = VersionedJSONFile(
        fileURL: url, defaultContent: defaultCodecDocument, supportedVersion: 2,
        decode: decodeCodecDocument, encode: encodeCodecDocument, backupBeforeUpgrade: true,
        atomicWrite: { data, destination in
            guard FileManager.default.fileExists(atPath: marker.path) else { throw InjectedWriteError() }
            try data.write(to: destination, options: .atomic)
        }
    )
    #expect(throws: InjectedWriteError.self) { try file.save() }
    let backup = try #require(file.migrationBackupURL)
    try FileManager.default.removeItem(at: backup)
    try Data().write(to: marker)
    #expect(throws: (any Error).self) { try file.save() }
    #expect(try Data(contentsOf: url) == original)
}

@Test func futureVersionNeverCallsCodecOrCreatesBackup() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let source = Data(#"{"version":99,"notes":["future"]}"#.utf8)
    try source.write(to: url)
    let marker = root.appendingPathComponent("codec-called")

    let decode: @Sendable (Data, Int) throws -> CodecDocument = { _, _ in
        try Data().write(to: marker)
        return CodecDocument(notes: ["called"], workspaces: [])
    }
    let encode: @Sendable (CodecDocument, Int) throws -> Data = { _, _ in
        try Data().write(to: marker)
        return Data()
    }

    var file = VersionedJSONFile(
        fileURL: url,
        defaultContent: defaultCodecDocument,
        supportedVersion: 2,
        decode: decode,
        encode: encode,
        backupBeforeUpgrade: true,
        now: { fixedDate },
        randomSuffix: fixedSuffix
    )

    #expect(file.mode == .readOnly(.newerVersion(found: 99, supported: 2)))
    #expect(file.outcome == .newer(version: 99))
    #expect(file.content == defaultCodecDocument)
    #expect(file.migrationBackupURL == nil)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(try fileNames(in: root) == ["notes.json"])

    do {
        try file.save()
        Issue.record("Expected saving a future version to fail")
    } catch let error as VersionedJSONFile<CodecDocument>.SaveError {
        #expect(error == .readOnly(.newerVersion(found: 99, supported: 2)))
    }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(try Data(contentsOf: url) == source)
}

@Test func symlinkTargetUpgradePreservesLinkAndPlacesBackupBesideTarget() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let target = root.appendingPathComponent("real-notes.json")
    let url = root.appendingPathComponent("notes.json")
    let source = Data(#"{"version":1,"notes":["alpha"],"workspaces":[]}"#.utf8)
    try source.write(to: target)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

    var file = VersionedJSONFile(
        fileURL: url,
        defaultContent: defaultCodecDocument,
        supportedVersion: 2,
        decode: decodeCodecDocument,
        encode: encodeCodecDocument,
        backupBeforeUpgrade: true,
        now: { fixedDate },
        randomSuffix: fixedSuffix
    )
    file.updateContent(CodecDocument(notes: ["beta"], workspaces: []))
    try file.save()

    let backup = root.appendingPathComponent("real-notes.v1-\(fixedDateStamp)-0123abcd.json")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == target.path)
    #expect(file.migrationBackupURL == backup)
    #expect(try Data(contentsOf: backup) == source)

    let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any])
    #expect(object["version"] as? Int == 2)
    #expect(object["notes"] as? [String] == ["beta"])
    #expect(
        try fileNames(in: root)
            == ["notes.json", "real-notes.json", backup.lastPathComponent].sorted()
    )
}

@Test func externallyModifiedTargetRefusesMigratedWrite() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let source = Data(#"{"version":1,"notes":["alpha"],"workspaces":[]}"#.utf8)
    try source.write(to: url)

    var file = VersionedJSONFile(
        fileURL: url,
        defaultContent: defaultCodecDocument,
        supportedVersion: 2,
        decode: decodeCodecDocument,
        encode: encodeCodecDocument,
        backupBeforeUpgrade: true,
        now: { fixedDate },
        randomSuffix: fixedSuffix
    )
    file.updateContent(CodecDocument(notes: ["beta"], workspaces: []))

    let external = Data(#"{"version":1,"notes":["external"],"workspaces":[]}"#.utf8)
    try external.write(to: url)

    do {
        try file.save()
        Issue.record("Expected an externally modified target to refuse the migrated write")
    } catch let error as VersionedJSONFile<CodecDocument>.SaveError {
        #expect(error == .sourceChanged)
    }

    #expect(file.migrationBackupURL == nil)
    #expect(try Data(contentsOf: url) == external)
    #expect(try fileNames(in: root) == ["notes.json"])
}

@Test func saveGateKeepsOneMigrationBackupAcrossFailedWrite() throws {
    let root = try makeTempDirectory()
    defer { removeTempDirectory(root) }

    let url = root.appendingPathComponent("notes.json")
    let source = Data(#"{"version":1,"notes":["alpha"],"workspaces":[]}"#.utf8)
    try source.write(to: url)
    let marker = root.appendingPathComponent("allow-write")
    let file = VersionedJSONFile(
        fileURL: url, defaultContent: defaultCodecDocument, supportedVersion: 2,
        decode: decodeCodecDocument, encode: encodeCodecDocument, backupBeforeUpgrade: true,
        now: { fixedDate }, randomSuffix: { "backup\($0)" },
        atomicWrite: { data, destination in
            guard FileManager.default.fileExists(atPath: marker.path) else { throw InjectedWriteError() }
            try data.write(to: destination, options: .atomic)
        }
    )
    let gate = SaveGate(file: file, committedGeneration: 0)
    let snapshot = SaveGate<CodecDocument>.Snapshot(
        generation: 1,
        content: CodecDocument(notes: ["beta"], workspaces: [])
    )

    #expect(throws: InjectedWriteError.self) { try gate.commit(snapshot) }
    let firstBackup = try #require(gate.migrationBackupURL)

    try Data().write(to: marker)
    _ = try gate.commit(snapshot)

    #expect(gate.migrationBackupURL == firstBackup)
    let backups = try fileNames(in: root).filter { $0.hasPrefix("notes.v1-") }
    #expect(backups == [firstBackup.lastPathComponent])
}
