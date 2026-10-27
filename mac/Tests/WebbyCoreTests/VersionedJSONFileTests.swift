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

    let file = VersionedJSONFile(fileURL: url, defaultContent: defaultContent, now: { fixedDate })

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

    let file = VersionedJSONFile(fileURL: url, defaultContent: defaultContent, now: { fixedDate })

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

    let reloaded = VersionedJSONFile(fileURL: url, defaultContent: defaultContent, now: { fixedDate })
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
