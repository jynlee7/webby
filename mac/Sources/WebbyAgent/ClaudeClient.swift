import Foundation

public enum ClaudeClientError: Error, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case malformedJSON(event: String)
    case unexpectedSequence(String)
    case unexpectedEndOfStream
    case streamError(ClaudeStreamError)
    case sse(SSEParserError)
    case transport(ClaudeTransportError)

    public var description: String {
        switch self {
        case let .malformedJSON(event):
            return "Claude event '\(event)' had malformed JSON"
        case let .unexpectedSequence(reason):
            return "Claude event sequence was invalid: \(reason)"
        case .unexpectedEndOfStream:
            return "Claude stream ended before message_stop"
        case let .streamError(error):
            return "Claude stream error: \(error.type)"
        case let .sse(error):
            return error.description
        case let .transport(error):
            return error.description
        }
    }

    public var debugDescription: String {
        description
    }
}

/// Consumes a prepared Claude Messages request as a stream of public agent events.
///
/// This slice covers transport, SSE decoding and content accumulation only.
/// Request assembly and tool execution belong to later slices.
public struct ClaudeClient: Sendable {
    private let transport: any ClaudeTransport

    public init(transport: any ClaudeTransport) {
        self.transport = transport
    }

    public func stream(_ request: PreparedRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        let transport = self.transport
        return AsyncThrowingStream { continuation in
            let task = Task { @Sendable in
                var parser = SSEParser()
                var state = StreamState()
                let transportStream = transport.stream(request)

                do {
                    streamLoop: for try await chunk in transportStream {
                        try Task.checkCancellation()
                        for event in try parser.feed(chunk) {
                            try Self.handle(event, state: &state, continuation: continuation)
                            if state.finished {
                                break streamLoop
                            }
                        }
                    }

                    if !state.finished {
                        for event in try parser.finish() {
                            try Self.handle(event, state: &state, continuation: continuation)
                            if state.finished {
                                break
                            }
                        }
                    }

                    guard state.finished else {
                        throw ClaudeClientError.unexpectedEndOfStream
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as ClaudeClientError {
                    continuation.finish(throwing: error)
                } catch let error as ClaudeTransportError {
                    if error == .cancelled {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish(throwing: ClaudeClientError.transport(error))
                    }
                } catch let error as SSEParserError {
                    continuation.finish(throwing: ClaudeClientError.sse(error))
                } catch {
                    continuation.finish(throwing: ClaudeClientError.transport(.network))
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private struct BlockAccumulator {
        let block: ClaudeContentBlock
        var text = ""
        var thinking = ""
        var signature = ""
        var inputJSON = ""
        var redactedData = ""
    }

    private struct StreamState {
        var usage = ClaudeUsage.zero
        var blocks: [Int: BlockAccumulator] = [:]
        var order: [Int] = []
        var stopReason: ClaudeStopReason?
        var stopSequence: String?
        var sawMessageStart = false
        var finished = false
    }

    private static func handle(
        _ event: SSEEvent,
        state: inout StreamState,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) throws {
        guard !state.finished else { return }

        let raw: RawEvent
        do {
            raw = try JSONDecoder().decode(RawEvent.self, from: Data(event.data.utf8))
        } catch {
            if event.name == "message" {
                throw ClaudeClientError.malformedJSON(event: event.name)
            }
            // Unknown named events are ignored without decoding their payload.
            if !knownEventNames.contains(event.name) {
                return
            }
            throw ClaudeClientError.malformedJSON(event: event.name)
        }

        let name = event.name == "message" ? raw.type : event.name
        guard knownEventNames.contains(name) else { return }

        switch name {
        case "message_start":
            guard !state.sawMessageStart else {
                throw ClaudeClientError.unexpectedSequence("duplicate message_start")
            }
            guard let message = raw.message, let id = message.id, let model = message.model else {
                throw ClaudeClientError.unexpectedSequence("message_start missing message")
            }
            state.sawMessageStart = true
            state.usage = message.usage?.usage ?? .zero
            continuation.yield(.messageStart(ClaudeMessageStart(id: id, model: model, usage: state.usage)))
            continuation.yield(.usage(state.usage))

        case "content_block_start":
            guard state.sawMessageStart else {
                throw ClaudeClientError.unexpectedSequence("content block before message_start")
            }
            guard let index = raw.index, let contentBlock = raw.contentBlock else {
                throw ClaudeClientError.unexpectedSequence("content_block_start missing index or block")
            }
            guard state.blocks[index] == nil else {
                throw ClaudeClientError.unexpectedSequence("duplicate content block \(index)")
            }

            let block = try decodedBlock(contentBlock)
            var accumulator = BlockAccumulator(block: block)
            if case let .redactedThinking(data) = block {
                accumulator.redactedData = data
            }
            state.blocks[index] = accumulator
            state.order.append(index)
            continuation.yield(.contentBlockStart(index: index, block: block))

        case "content_block_delta":
            guard state.sawMessageStart else {
                throw ClaudeClientError.unexpectedSequence("content delta before message_start")
            }
            guard let index = raw.index, let rawDelta = raw.delta, let accumulator = state.blocks[index] else {
                throw ClaudeClientError.unexpectedSequence("content delta for an unknown block")
            }

            let delta = try decodedDelta(rawDelta)
            var block = accumulator
            switch delta {
            case let .text(text):
                guard case .text = block.block else {
                    throw ClaudeClientError.unexpectedSequence("text delta for a non-text block")
                }
                block.text += text
            case let .thinking(thinking):
                guard case .thinking = block.block else {
                    throw ClaudeClientError.unexpectedSequence("thinking delta for a non-thinking block")
                }
                block.thinking += thinking
            case let .signature(signature):
                guard case .thinking = block.block else {
                    throw ClaudeClientError.unexpectedSequence("signature delta for a non-thinking block")
                }
                block.signature += signature
            case let .inputJSON(fragment):
                guard case .toolUse = block.block else {
                    throw ClaudeClientError.unexpectedSequence("input_json delta for a non-tool block")
                }
                block.inputJSON += fragment
            case .unknown:
                break
            }
            state.blocks[index] = block
            continuation.yield(.contentBlockDelta(index: index, delta: delta))

        case "content_block_stop":
            guard let index = raw.index, state.blocks[index] != nil else {
                throw ClaudeClientError.unexpectedSequence("content block stop for an unknown block")
            }
            continuation.yield(.contentBlockStop(index: index))

        case "message_delta":
            guard state.sawMessageStart else {
                throw ClaudeClientError.unexpectedSequence("message_delta before message_start")
            }
            let deltaUsage = raw.usage?.usage ?? .zero
            state.usage = state.usage.merging(deltaUsage)
            let rawStopReason = raw.delta?.stopReason ?? raw.stopReason
            let rawStopSequence = raw.delta?.stopSequence ?? raw.stopSequence
            let reason = rawStopReason.map(ClaudeStopReason.init(rawValue:))
            state.stopReason = reason
            state.stopSequence = rawStopSequence

            let delta = ClaudeMessageDelta(
                stopReason: reason,
                stopSequence: rawStopSequence,
                usage: state.usage
            )
            continuation.yield(.messageDelta(delta))
            continuation.yield(.usage(state.usage))
            if reason == .refusal {
                continuation.yield(.refusal)
            }

        case "message_stop":
            guard state.sawMessageStart else {
                throw ClaudeClientError.unexpectedSequence("message_stop before message_start")
            }
            state.finished = true
            continuation.yield(.messageStop)
            continuation.yield(.completed(completion(from: state)))

        case "ping":
            continuation.yield(.ping)

        case "error":
            let streamError = ClaudeStreamError(
                type: raw.error?.type ?? "unknown",
                message: raw.error?.message
            )
            continuation.yield(.streamError(streamError))
            throw ClaudeClientError.streamError(streamError)

        default:
            break
        }
    }

    private static let knownEventNames: Set<String> = [
        "message_start",
        "content_block_start",
        "content_block_delta",
        "content_block_stop",
        "message_delta",
        "message_stop",
        "ping",
        "error",
    ]

    private static func decodedBlock(_ raw: RawContentBlock) throws -> ClaudeContentBlock {
        switch raw.type {
        case "text":
            return .text
        case "thinking":
            return .thinking
        case "redacted_thinking":
            return .redactedThinking(data: raw.data ?? "")
        case "tool_use":
            guard let id = raw.id, let name = raw.name else {
                throw ClaudeClientError.unexpectedSequence("tool_use block missing id or name")
            }
            return .toolUse(id: id, name: name)
        default:
            return .unknown(type: raw.type)
        }
    }

    private static func decodedDelta(_ raw: RawDelta) throws -> ClaudeContentDelta {
        guard let type = raw.type else {
            throw ClaudeClientError.unexpectedSequence("content delta missing type")
        }
        switch type {
        case "text_delta":
            guard let text = raw.text else {
                throw ClaudeClientError.unexpectedSequence("text_delta missing text")
            }
            return .text(text)
        case "thinking_delta":
            guard let thinking = raw.thinking else {
                throw ClaudeClientError.unexpectedSequence("thinking_delta missing thinking")
            }
            return .thinking(thinking)
        case "signature_delta":
            guard let signature = raw.signature else {
                throw ClaudeClientError.unexpectedSequence("signature_delta missing signature")
            }
            return .signature(signature)
        case "input_json_delta":
            guard let fragment = raw.partialJSON else {
                throw ClaudeClientError.unexpectedSequence("input_json_delta missing partial_json")
            }
            return .inputJSON(fragment)
        default:
            return .unknown(type: type)
        }
    }

    private static func completion(from state: StreamState) -> ClaudeCompletion {
        let blocks = state.order.compactMap { index -> ClaudeCompletedBlock? in
            guard let accumulator = state.blocks[index] else { return nil }
            switch accumulator.block {
            case .text:
                return .text(accumulator.text)
            case .thinking:
                return .thinking(text: accumulator.thinking, signature: accumulator.signature)
            case .redactedThinking:
                return .redactedThinking(data: accumulator.redactedData)
            case let .toolUse(id, name):
                return .toolUse(id: id, name: name, inputJSON: accumulator.inputJSON)
            case let .unknown(type):
                return .unknown(type: type)
            }
        }
        return ClaudeCompletion(
            blocks: blocks,
            usage: state.usage,
            stopReason: state.stopReason,
            stopSequence: state.stopSequence
        )
    }
}

private struct RawEvent: Decodable {
    let type: String
    let index: Int?
    let message: RawMessage?
    let contentBlock: RawContentBlock?
    let delta: RawDelta?
    let usage: RawUsage?
    let error: RawError?
    let stopReason: String?
    let stopSequence: String?

    enum CodingKeys: String, CodingKey {
        case type
        case index
        case message
        case contentBlock = "content_block"
        case delta
        case usage
        case error
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
    }
}

private struct RawMessage: Decodable {
    let id: String?
    let model: String?
    let usage: RawUsage?
}

private struct RawContentBlock: Decodable {
    let type: String
    let id: String?
    let name: String?
    let data: String?
}

private struct RawDelta: Decodable {
    let type: String?
    let text: String?
    let thinking: String?
    let signature: String?
    let partialJSON: String?
    let stopReason: String?
    let stopSequence: String?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case thinking
        case signature
        case partialJSON = "partial_json"
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
    }
}

private struct RawUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    var usage: ClaudeUsage {
        ClaudeUsage(
            inputTokens: inputTokens ?? 0,
            outputTokens: outputTokens ?? 0,
            cacheCreationInputTokens: cacheCreationInputTokens ?? 0,
            cacheReadInputTokens: cacheReadInputTokens ?? 0
        )
    }
}

private struct RawError: Decodable {
    let type: String
    let message: String?
}
