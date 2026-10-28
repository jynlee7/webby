import Foundation

/// User preferences stored in `settings.json` v1.
///
/// It holds no secrets and no `Date` values, so it is not subject to the notes
/// file's date precision rules. Any later change to the persisted shape, even an
/// optional field, bumps the version instead of relying on synthesized decoding.
public struct Settings: Codable, Sendable, Equatable {
    public var globalSkinID: String?
    public var skinSoundsEnabled: Bool
    public var voiceEarconsEnabled: Bool
    public var queryRules: [QueryRule]
    public var newNoteHotkey: String
    public var agentHotkey: String
    public var agentModel: String
    public var notesBudgetTokens: Int
    public var conversationRetentionDays: Int
    public var screenCaptureDefault: Bool
    public var dismissedCorruptFiles: [String]

    public init(
        globalSkinID: String? = nil,
        skinSoundsEnabled: Bool = false,
        voiceEarconsEnabled: Bool = true,
        queryRules: [QueryRule] = [],
        newNoteHotkey: String = "ctrl+opt+n",
        agentHotkey: String = "ctrl+opt+a",
        agentModel: String = "claude-haiku-5-5",
        notesBudgetTokens: Int = 8000,
        conversationRetentionDays: Int = 30,
        screenCaptureDefault: Bool = false,
        dismissedCorruptFiles: [String] = []
    ) {
        self.globalSkinID = globalSkinID
        self.skinSoundsEnabled = skinSoundsEnabled
        self.voiceEarconsEnabled = voiceEarconsEnabled
        self.queryRules = queryRules
        self.newNoteHotkey = newNoteHotkey
        self.agentHotkey = agentHotkey
        self.agentModel = agentModel
        self.notesBudgetTokens = notesBudgetTokens
        self.conversationRetentionDays = conversationRetentionDays
        self.screenCaptureDefault = screenCaptureDefault
        self.dismissedCorruptFiles = dismissedCorruptFiles
    }

    public static let `default` = Settings()
}

/// A user rule that makes a query parameter part of a page's identity.
public struct QueryRule: Codable, Sendable, Hashable {
    public var host: String
    public var key: String

    public init(host: String, key: String) {
        self.host = host
        self.key = key
    }
}
