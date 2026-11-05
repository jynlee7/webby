import Foundation
import Testing
@testable import WebbyCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("webby-settings-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let currentFieldNames: Set<String> = [
    "globalSkinID",
    "skinSoundsEnabled",
    "voiceEarconsEnabled",
    "queryRules",
    "removedBuiltInQueryRules",
    "newNoteHotkey",
    "agentHotkey",
    "agentModel",
    "notesBudgetTokens",
    "conversationRetentionDays",
    "screenCaptureDefault",
    "dismissedCorruptFiles",
]

@Suite("SettingsStore")
struct SettingsStoreTests {
    @Test func defaultsWhenFileMissing() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("settings.json")

        let store = SettingsStore(fileURL: fileURL)

        #expect(store.settings == Settings.default)
        #expect(store.mode == .writable)
        #expect(store.outcome == .missing)
        #expect(store.migrations == .missing)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Webby").path))
    }

    @Test func roundTripPreservesAllFieldsAndRootShape() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("settings.json")

        let custom = Settings(
            globalSkinID: "皮肤-さくら",
            skinSoundsEnabled: true,
            voiceEarconsEnabled: false,
            queryRules: [
                QueryRule(host: "example.com", key: "q"),
                QueryRule(host: "知乎.com", key: "关键词"),
            ],
            newNoteHotkey: "cmd+shift+n",
            agentHotkey: "cmd+shift+a",
            agentModel: "claude-sonnet-5",
            notesBudgetTokens: 1234,
            conversationRetentionDays: 7,
            screenCaptureDefault: true,
            dismissedCorruptFiles: ["notes.corrupt-1.json", "notes.corrupt-2.json"]
        )

        let store = SettingsStore(fileURL: fileURL)
        try store.replace(custom)

        let reloaded = SettingsStore(fileURL: fileURL)
        #expect(reloaded.settings == custom)
        #expect(reloaded.mode == .writable)
        #expect(reloaded.outcome == .loaded)

        let data = try Data(contentsOf: fileURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(root.keys) == ["version", "settings"])
        #expect(root["version"] as? Int == 2)
        let settingsObject = try #require(root["settings"] as? [String: Any])
        #expect(Set(settingsObject.keys) == currentFieldNames)
        #expect(settingsObject["globalSkinID"] as? String == "皮肤-さくら")
        #expect((settingsObject["queryRules"] as? [[String: Any]])?.count == 2)
    }

    @Test func newerVersionIsReadOnlyAndUntouched() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("settings.json")

        let original = Data("""
        {
          "version" : 3,
          "settings" : {
            "globalSkinID" : "future"
          }
        }
        """.utf8)
        try original.write(to: fileURL)

        let store = SettingsStore(fileURL: fileURL)
        #expect(store.settings == Settings.default)
        #expect(store.mode == .readOnly(.newerVersion(found: 3, supported: 2)))
        #expect(store.outcome == .newer(version: 3))

        do {
            try store.save()
            Issue.record("save should throw on a newer version")
        } catch let error as SettingsError {
            #expect(error == .readOnly(.newerVersion(found: 3, supported: 2)))
        }

        do {
            try store.replace(Settings(globalSkinID: "replacement"))
            Issue.record("replace should throw on a newer version")
        } catch let error as SettingsError {
            #expect(error == .readOnly(.newerVersion(found: 3, supported: 2)))
        }
        #expect(store.settings == Settings.default)

        let after = try Data(contentsOf: fileURL)
        #expect(after == original)
    }

    @Test func unreadableFileIsReadOnlyAndUntouched() throws {
        guard geteuid() != 0 else {
            // Root ignores file permissions, so the read error cannot be produced.
            return
        }

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("settings.json")

        let original = Data("""
        {
          "version" : 1,
          "settings" : {
            "globalSkinID" : "existing"
          }
        }
        """.utf8)
        try original.write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path) }

        let store = SettingsStore(fileURL: fileURL)
        #expect(store.settings == Settings.default)
        guard case .readOnly(.unreadable) = store.mode else {
            Issue.record("expected an unreadable read-only mode, got \(store.mode)")
            return
        }
        #expect(store.outcome == .unreadable)

        do {
            try store.save()
            Issue.record("save should throw on an unreadable file")
        } catch let error as SettingsError {
            guard case .readOnly(.unreadable) = error else {
                Issue.record("expected SettingsError.readOnly(.unreadable), got \(error)")
                return
            }
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        let after = try Data(contentsOf: fileURL)
        #expect(after == original)
    }

    @Test func corruptFileIsMovedAsideAndDefaultsAreWritable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("settings.json")

        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: fileURL)

        let store = SettingsStore(fileURL: fileURL)
        #expect(store.settings == Settings.default)
        #expect(store.mode == .writable)

        guard case .recovered(let recoveredURL) = store.outcome else {
            Issue.record("expected a recovered outcome, got \(store.outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: recoveredURL.path))
        #expect(recoveredURL.lastPathComponent.hasPrefix("settings.corrupt-"))
        #expect(try Data(contentsOf: recoveredURL) == corrupt)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        try store.save()
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(SettingsStore(fileURL: fileURL).settings == Settings.default)
    }

    @Test func replacePersistsAndReloads() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("settings.json")

        let store = SettingsStore(fileURL: fileURL)
        var value = Settings.default
        value.agentModel = "claude-sonnet-5"
        try store.replace(value)
        #expect(store.settings == value)
        #expect(SettingsStore(fileURL: fileURL).settings == value)

        value.notesBudgetTokens = 50
        try store.replace(value)
        let reloaded = SettingsStore(fileURL: fileURL)
        #expect(reloaded.settings == value)
        #expect(reloaded.settings.notesBudgetTokens == 50)
    }

    @Test func version1FileLoadsWithNoRemovedBuiltInsAndUpgradesOnSave() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("settings.json")
        try Data("""
        {
          "version" : 1,
          "settings" : {
            "globalSkinID" : "kept",
            "skinSoundsEnabled" : true,
            "voiceEarconsEnabled" : false,
            "queryRules" : [ { "host" : "example.com", "key" : "q" } ],
            "newNoteHotkey" : "cmd+shift+n",
            "agentHotkey" : "cmd+shift+a",
            "agentModel" : "m",
            "notesBudgetTokens" : 9,
            "conversationRetentionDays" : 3,
            "screenCaptureDefault" : true,
            "dismissedCorruptFiles" : [ "x.json" ]
          }
        }
        """.utf8).write(to: fileURL)

        let store = SettingsStore(fileURL: fileURL)
        #expect(store.outcome == .loaded)
        #expect(store.mode == .writable)
        #expect(store.settings.removedBuiltInQueryRules.isEmpty)
        #expect(store.settings.queryRules == [QueryRule(host: "example.com", key: "q")])
        #expect(store.settings.globalSkinID == "kept")
        #expect(store.settings.notesBudgetTokens == 9)

        var updated = store.settings
        updated.removedBuiltInQueryRules = [QueryRule(host: "youtube.com", key: "v")]
        try store.replace(updated)
        let reloaded = SettingsStore(fileURL: fileURL)
        #expect(reloaded.settings == updated)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        #expect(root["version"] as? Int == 2)
    }

    @Test func enabledQueryRulesAreBuiltInsNotRemovedPlusUserRulesWithoutDuplicates() {
        #expect(Settings.default.enabledQueryRules == QueryRules.builtIns)

        let settings = Settings(
            queryRules: [
                QueryRule(host: "Example.com", key: "q"),
                QueryRule(host: "example.com", key: "q"),
                QueryRule(host: "YouTube.com", key: "v"),
            ],
            removedBuiltInQueryRules: [QueryRule(host: "news.ycombinator.com", key: "id")]
        )
        #expect(settings.enabledQueryRules == [
            QueryRule(host: "youtube.com", key: "v"),
            QueryRule(host: "example.com", key: "q"),
        ])

        let removedBoth = Settings(removedBuiltInQueryRules: QueryRules.builtIns)
        #expect(removedBoth.enabledQueryRules.isEmpty)
    }

    @Test func settingsHasNoDateFields() {
        for child in Mirror(reflecting: Settings.default).children {
            #expect(!(child.value is Date), "Settings.\(child.label ?? "unknown") must not be a Date")
        }
        for child in Mirror(reflecting: QueryRule(host: "example.com", key: "q")).children {
            #expect(!(child.value is Date), "QueryRule.\(child.label ?? "unknown") must not be a Date")
        }
    }
}
