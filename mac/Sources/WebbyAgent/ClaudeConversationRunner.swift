import Foundation

/// One turn ready for the bounded `read_note` loop.
///
/// The request and snapshot are immutable. `authorizationValidator` is consulted
/// before every continuation; a false result aborts before a stale tool result can
/// be sent.
public struct PreparedTurn: Sendable {
    public let request: ClaudeRequest
    public let snapshot: AgentTurnSnapshot
    public let authorizationValidator: @Sendable (String) async -> Bool

    public init(
        request: ClaudeRequest,
        snapshot: AgentTurnSnapshot,
        authorizationValidator: @escaping @Sendable (String) async -> Bool = { _ in true }
    ) {
        self.request = request
        self.snapshot = snapshot
        self.authorizationValidator = authorizationValidator
    }

    public init(
        assembled: AgentAssembledTurn,
        authorizationValidator: @escaping @Sendable (String) async -> Bool = { _ in true }
    ) {
        self.init(
            request: assembled.request,
            snapshot: assembled.turnSnapshot,
            authorizationValidator: authorizationValidator
        )
    }

    public var authorizationFingerprint: String {
        snapshot.authorizationFingerprint
    }
}

public enum ClaudeTurnTermination: String, Codable, Equatable, Sendable {
    case completed
    case truncated
    case refused
    case invalidated
}

public enum ClaudeConversationError: Error, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case authorizationInvalidated
    case toolRoundLimitExceeded
    case malformedToolInput(toolID: String)
    case unsupportedTool(name: String)
    case unknownStopReason(reason: String, partialAnswer: String)
    case missingStopReason(partialAnswer: String)
    case missingToolBlocks(partialAnswer: String)

    public var description: String {
        switch self {
        case .authorizationInvalidated:
            return "The turn's authorization changed before its continuation."
        case .toolRoundLimitExceeded:
            return "The turn exceeded the tool-round limit."
        case let .malformedToolInput(toolID):
            return "Tool call \(toolID) had incomplete JSON input."
        case let .unsupportedTool(name):
            return "The model called an unsupported tool: \(name)."
        case let .unknownStopReason(reason, _):
            return "Claude returned an unknown stop reason: \(reason)."
        case .missingToolBlocks(_):
            return "Claude stopped for a tool continuation without any content blocks."
        case .missingStopReason:
            return "Claude stopped without a stop reason."
        }
    }

    public var debugDescription: String {
        description
    }
}

public struct ClaudeTurnResult: Equatable, Sendable {
    public let answerText: String
    public let usage: ClaudeUsage
    public let readAliases: [String]
    public let citations: [CitationValidator.Citation]
    public let termination: ClaudeTurnTermination
    public let toolRounds: Int

    public var terminalStatus: ClaudeTurnTermination { termination }

    public init(
        answerText: String,
        usage: ClaudeUsage,
        readAliases: [String],
        citations: [CitationValidator.Citation],
        termination: ClaudeTurnTermination,
        toolRounds: Int
    ) {
        self.answerText = answerText
        self.usage = usage
        self.readAliases = readAliases
        self.citations = citations
        self.termination = termination
        self.toolRounds = toolRounds
    }
}

/// Runs a prepared turn through the bounded `read_note` continuation loop.
///
/// Completed assistant blocks are re-sent exactly as received. Parallel tool calls
/// are answered in one user message. `pause_turn` resends the assistant content
/// unchanged. No retry is attempted after the first output.
public struct ClaudeConversationRunner: Sendable {
    public static let defaultMaxToolRounds = 8

    private let client: ClaudeClient
    private let maxToolRounds: Int

    public init(
        transport: any ClaudeTransport,
        maxToolRounds: Int = ClaudeConversationRunner.defaultMaxToolRounds
    ) {
        self.client = ClaudeClient(transport: transport)
        self.maxToolRounds = max(0, maxToolRounds)
    }

    public init(client: ClaudeClient, maxToolRounds: Int = ClaudeConversationRunner.defaultMaxToolRounds) {
        self.client = client
        self.maxToolRounds = max(0, maxToolRounds)
    }

    public func run(_ turn: PreparedTurn) async throws -> ClaudeTurnResult {
        try await run(turn) { _ in }
    }

    public func run(
        _ turn: PreparedTurn,
        onEvent: @escaping @Sendable (AgentEvent) async -> Void
    ) async throws -> ClaudeTurnResult {
        var request = turn.request
        var session = AgentReadSession(snapshot: turn.snapshot)
        var answerText = ""
        var pausedText = ""
        var usage = ClaudeUsage.zero
        var readAliases: Set<String> = []
        var toolRounds = 0

        while true {
            let completion = try await consume(request, onEvent: onEvent)
            // A pause continues the same assistant turn, so its text accumulates.
            // Text from an intermediate tool round is not the answer.
            if completion.stopReason == .pauseTurn {
                pausedText = Self.joinedTurnText(pausedText, completion.text)
                answerText = pausedText
            } else if !pausedText.isEmpty {
                answerText = Self.joinedTurnText(pausedText, completion.text)
                pausedText = ""
            } else {
                answerText = completion.text
            }
            usage = Self.adding(usage, completion.usage)

            guard let stopReason = completion.stopReason else {
                throw ClaudeConversationError.missingStopReason(partialAnswer: answerText)
            }

            if stopReason == .endTurn || stopReason == .stopSequence {
                return finish(
                    answerText: answerText,
                    usage: usage,
                    turn: turn,
                    readAliases: readAliases,
                    termination: .completed,
                    toolRounds: toolRounds
                )
            }

            if stopReason == .toolUse {
                guard toolRounds < maxToolRounds else {
                    throw ClaudeConversationError.toolRoundLimitExceeded
                }
                guard await turn.authorizationValidator(turn.authorizationFingerprint) else {
                    throw ClaudeConversationError.authorizationInvalidated
                }
                let results = try toolResults(
                    for: completion,
                    session: &session,
                    readAliases: &readAliases
                )
                guard !results.isEmpty else {
                    throw ClaudeConversationError.missingToolBlocks(
                        partialAnswer: answerText
                    )
                }
                request = try request.appendingToolRound(
                    assistant: completion,
                    toolResults: results
                )
                toolRounds += 1
                continue
            }

            if stopReason == .pauseTurn {
                guard completion.blocks.contains(where: { block in
                    if case .unknown = block { return false }
                    return true
                }) else {
                    throw ClaudeConversationError.missingToolBlocks(
                        partialAnswer: answerText
                    )
                }
                guard toolRounds < maxToolRounds else {
                    throw ClaudeConversationError.toolRoundLimitExceeded
                }
                guard await turn.authorizationValidator(turn.authorizationFingerprint) else {
                    throw ClaudeConversationError.authorizationInvalidated
                }
                request = try request.appendingAssistant(completion)
                toolRounds += 1
                continue
            }

            if stopReason == .maxTokens || stopReason == .modelContextWindowExceeded {
                return finish(
                    answerText: answerText,
                    usage: usage,
                    turn: turn,
                    readAliases: readAliases,
                    termination: .truncated,
                    toolRounds: toolRounds
                )
            }

            if stopReason == .refusal {
                return finish(
                    answerText: answerText,
                    usage: usage,
                    turn: turn,
                    readAliases: readAliases,
                    termination: .refused,
                    toolRounds: toolRounds
                )
            }

            throw ClaudeConversationError.unknownStopReason(
                reason: stopReason.rawValue,
                partialAnswer: answerText
            )
        }
    }

    private func finish(
        answerText: String,
        usage: ClaudeUsage,
        turn: PreparedTurn,
        readAliases: Set<String>,
        termination: ClaudeTurnTermination,
        toolRounds: Int
    ) -> ClaudeTurnResult {
        let sentAliases = Set(turn.snapshot.notesByAlias.compactMap { alias, note in
            note.status == .omitted ? nil : alias
        })
        let validation = CitationValidator.validate(
            answerText: answerText,
            snapshot: turn.snapshot,
            sentAliases: sentAliases,
            readAliases: readAliases
        )
        return ClaudeTurnResult(
            answerText: validation.answerText,
            usage: usage,
            readAliases: readAliases.sorted(),
            citations: validation.citations,
            termination: termination,
            toolRounds: toolRounds
        )
    }

    private func consume(
        _ request: ClaudeRequest,
        onEvent: @escaping @Sendable (AgentEvent) async -> Void
    ) async throws -> ClaudeCompletion {
        var completion: ClaudeCompletion?
        for try await event in client.stream(request.preparedRequest()) {
            if case let .completed(value) = event {
                completion = value
            }
            await onEvent(event)
        }
        guard let completion else {
            throw ClaudeClientError.unexpectedEndOfStream
        }
        return completion
    }

    private func toolResults(
        for completion: ClaudeCompletion,
        session: inout AgentReadSession,
        readAliases: inout Set<String>
    ) throws -> [ClaudeToolResult] {
        var results: [ClaudeToolResult] = []
        for block in completion.blocks {
            guard case let .toolUse(id, name, inputJSON) = block else { continue }
            guard name == "read_note" else {
                throw ClaudeConversationError.unsupportedTool(name: name)
            }
            let alias = try alias(from: inputJSON, toolID: id)
            let read = session.readNote(alias: alias)
            if !read.isError {
                readAliases.insert(alias)
            }
            results.append(ClaudeToolResult(
                toolUseID: id,
                content: read.toolResultContent,
                isError: read.isError
            ))
        }
        return results
    }

    private func alias(from inputJSON: String, toolID: String) throws -> String {
        let value: ClaudeJSON
        do {
            value = try ClaudeJSON.parse(inputJSON)
        } catch {
            throw ClaudeConversationError.malformedToolInput(toolID: toolID)
        }
        guard case let .object(fields) = value,
              case let .string(alias)? = fields["alias"],
              !alias.isEmpty else {
            throw ClaudeConversationError.malformedToolInput(toolID: toolID)
        }
        return alias
    }

    private static func joinedTurnText(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        if lhs.last?.isWhitespace == true || rhs.first?.isWhitespace == true {
            return lhs + rhs
        }
        return lhs + " " + rhs
    }

    private static func adding(_ lhs: ClaudeUsage, _ rhs: ClaudeUsage) -> ClaudeUsage {
        ClaudeUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationInputTokens: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens,
            cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens
        )
    }
}

public extension ClaudeClient {
    /// Runs a prepared turn through the same bounded loop as `ClaudeConversationRunner`.
    func run(_ turn: PreparedTurn) async throws -> ClaudeTurnResult {
        try await ClaudeConversationRunner(client: self).run(turn)
    }
}
