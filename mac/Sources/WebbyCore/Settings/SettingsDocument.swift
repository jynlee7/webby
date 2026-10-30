import Foundation

/// The `settings.json` envelopes. Version 1 is decoded only through the frozen
/// `SettingsV1` shape; encoding always writes version 2.
enum SettingsDocument {
    private struct Envelope<Content: Codable>: Codable {
        let version: Int
        let settings: Content
    }

    /// The version 1 shape, before built-in rules could be removed.
    private struct SettingsV1: Codable {
        var globalSkinID: String?
        var skinSoundsEnabled: Bool
        var voiceEarconsEnabled: Bool
        var queryRules: [QueryRule]
        var newNoteHotkey: String
        var agentHotkey: String
        var agentModel: String
        var notesBudgetTokens: Int
        var conversationRetentionDays: Int
        var screenCaptureDefault: Bool
        var dismissedCorruptFiles: [String]
    }

    static func decode(_ data: Data, version: Int) throws -> Settings {
        let decoder = JSONDecoder()
        switch version {
        case 1:
            let old = try decoder.decode(Envelope<SettingsV1>.self, from: data).settings
            return Settings(
                globalSkinID: old.globalSkinID,
                skinSoundsEnabled: old.skinSoundsEnabled,
                voiceEarconsEnabled: old.voiceEarconsEnabled,
                queryRules: old.queryRules,
                removedBuiltInQueryRules: [],
                newNoteHotkey: old.newNoteHotkey,
                agentHotkey: old.agentHotkey,
                agentModel: old.agentModel,
                notesBudgetTokens: old.notesBudgetTokens,
                conversationRetentionDays: old.conversationRetentionDays,
                screenCaptureDefault: old.screenCaptureDefault,
                dismissedCorruptFiles: old.dismissedCorruptFiles
            )
        case 2:
            return try decoder.decode(Envelope<Settings>.self, from: data).settings
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Unsupported settings version \(version)")
            )
        }
    }

    static func encode(_ settings: Settings, version: Int) throws -> Data {
        guard version == SettingsStore.currentVersion else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Unsupported settings version \(version)")
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Envelope(version: version, settings: settings))
    }
}
