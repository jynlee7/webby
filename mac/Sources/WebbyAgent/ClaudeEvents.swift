/// A stop reason string that preserves values Webby does not yet know.
public struct ClaudeStopReason: RawRepresentable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let endTurn = ClaudeStopReason(rawValue: "end_turn")
    public static let stopSequence = ClaudeStopReason(rawValue: "stop_sequence")
    public static let toolUse = ClaudeStopReason(rawValue: "tool_use")
    public static let pauseTurn = ClaudeStopReason(rawValue: "pause_turn")
    public static let maxTokens = ClaudeStopReason(rawValue: "max_tokens")
    public static let modelContextWindowExceeded = ClaudeStopReason(rawValue: "model_context_window_exceeded")
    public static let refusal = ClaudeStopReason(rawValue: "refusal")
}

public struct ClaudeMessageStart: Equatable, Sendable {
    public let id: String
    public let model: String
    public let usage: ClaudeUsage

    public init(id: String, model: String, usage: ClaudeUsage) {
        self.id = id
        self.model = model
        self.usage = usage
    }
}

public enum ClaudeContentBlock: Equatable, Sendable {
    case text
    case thinking
    case redactedThinking(data: String)
    case toolUse(id: String, name: String)
    case unknown(type: String)
}

public enum ClaudeContentDelta: Equatable, Sendable {
    case text(String)
    case thinking(String)
    case signature(String)
    case inputJSON(String)
    case unknown(type: String)
}

public struct ClaudeMessageDelta: Equatable, Sendable {
    public let stopReason: ClaudeStopReason?
    public let stopSequence: String?
    public let usage: ClaudeUsage

    public init(stopReason: ClaudeStopReason?, stopSequence: String?, usage: ClaudeUsage) {
        self.stopReason = stopReason
        self.stopSequence = stopSequence
        self.usage = usage
    }
}

public struct ClaudeStreamError: Equatable, Sendable {
    public let type: String
    public let message: String?

    public init(type: String, message: String?) {
        self.type = type
        self.message = message
    }
}

public enum ClaudeCompletedBlock: Equatable, Sendable {
    case text(String)
    case thinking(text: String, signature: String)
    case redactedThinking(data: String)
    case toolUse(id: String, name: String, inputJSON: String)
    case unknown(type: String)
}

public struct ClaudeCompletion: Equatable, Sendable {
    public let blocks: [ClaudeCompletedBlock]
    public let usage: ClaudeUsage
    public let stopReason: ClaudeStopReason?
    public let stopSequence: String?

    public init(
        blocks: [ClaudeCompletedBlock],
        usage: ClaudeUsage,
        stopReason: ClaudeStopReason?,
        stopSequence: String?
    ) {
        self.blocks = blocks
        self.usage = usage
        self.stopReason = stopReason
        self.stopSequence = stopSequence
    }

    public var text: String {
        blocks.compactMap { block in
            guard case let .text(text) = block else { return nil }
            return text
        }.joined()
    }
}

/// A public event from the streaming Claude client.
public enum AgentEvent: Equatable, Sendable {
    case messageStart(ClaudeMessageStart)
    case contentBlockStart(index: Int, block: ClaudeContentBlock)
    case contentBlockDelta(index: Int, delta: ClaudeContentDelta)
    case contentBlockStop(index: Int)
    case messageDelta(ClaudeMessageDelta)
    case messageStop
    case ping
    case usage(ClaudeUsage)
    case refusal
    case completed(ClaudeCompletion)
    case streamError(ClaudeStreamError)
}
