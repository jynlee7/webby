import WebbyCore

/// The Claude request parameters fixed when a conversation starts.
///
/// Changing model, effort, output limit, notes budget or the tiering context would
/// invalidate the cached prefix, so these values must not vary between turns.
public struct ClaudeConfiguration: Equatable, Sendable {
    public enum Effort: String, Hashable, Sendable {
        case low
        case medium
        case high
    }

    public var model: String
    public var apiVersion: String
    public var effort: Effort
    public var maxOutputTokens: Int
    public var notesBudget: Int
    public var tieringContext: Context

    public init(
        model: String,
        apiVersion: String,
        effort: Effort,
        maxOutputTokens: Int,
        notesBudget: Int,
        tieringContext: Context
    ) {
        self.model = model
        self.apiVersion = apiVersion
        self.effort = effort
        self.maxOutputTokens = maxOutputTokens
        self.notesBudget = notesBudget
        self.tieringContext = tieringContext
    }

    /// Production defaults pending live-doc verification before request fixtures
    /// are frozen (plan.md issue #24 model/version gate).
    ///
    /// This is the single production constant location. Tests must use synthetic
    /// model IDs and API versions so stale values cannot silently become fixtures.
    public static let pendingLiveDocVerification = ClaudeConfiguration(
        model: "claude-haiku-5-5",
        apiVersion: "2026-10-21",
        effort: .medium,
        maxOutputTokens: 16_000,
        notesBudget: 32_000,
        tieringContext: Context(appBundleID: "com.webby.app")
    )
}
