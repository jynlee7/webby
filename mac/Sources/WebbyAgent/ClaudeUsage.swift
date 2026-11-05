/// Token counts reported by a Claude response.
public struct ClaudeUsage: Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationInputTokens: Int
    public var cacheReadInputTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0,
        cacheReadInputTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    public static let zero = ClaudeUsage()

    /// Combines the start event's cache/input counts with a delta's counts.
    /// Delta events may omit fields, so zero does not overwrite a known value.
    public func merging(_ other: ClaudeUsage) -> ClaudeUsage {
        ClaudeUsage(
            inputTokens: other.inputTokens == 0 ? inputTokens : other.inputTokens,
            outputTokens: other.outputTokens == 0 ? outputTokens : other.outputTokens,
            cacheCreationInputTokens: other.cacheCreationInputTokens == 0
                ? cacheCreationInputTokens
                : other.cacheCreationInputTokens,
            cacheReadInputTokens: other.cacheReadInputTokens == 0
                ? cacheReadInputTokens
                : other.cacheReadInputTokens
        )
    }
}
