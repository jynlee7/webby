import Foundation
import WebbyCore

/// A deterministic JSON value used by the Claude request builder.
///
/// Objects are emitted with lexicographically sorted keys and strings are escaped
/// as UTF-8 JSON. Arrays keep caller order, which is how history and tool results
/// remain byte-stable.
public enum ClaudeJSON: Equatable, Sendable {
    case object([String: ClaudeJSON])
    case array([ClaudeJSON])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public static func parse(_ text: String) throws -> ClaudeJSON {
        let object = try JSONSerialization.jsonObject(
            with: Data(text.utf8),
            options: [.fragmentsAllowed]
        )
        return try convert(object)
    }

    public func encoded() -> String {
        switch self {
        case let .object(values):
            let body = values.keys.sorted().map { key in
                Self.encodeString(key) + ":" + values[key]!.encoded()
            }.joined(separator: ",")
            return "{" + body + "}"
        case let .array(values):
            return "[" + values.map { $0.encoded() }.joined(separator: ",") + "]"
        case let .string(value):
            return Self.encodeString(value)
        case let .int(value):
            return String(value)
        case let .double(value):
            if value.isFinite,
               value.rounded(.towardZero) == value,
               value >= Double(Int.min),
               value <= Double(Int.max) {
                return String(Int(value))
            }
            return String(value)
        case let .bool(value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    func addingCacheControl() -> ClaudeJSON {
        guard case let .object(values) = self else { return self }
        var updated = values
        updated["cache_control"] = .object(["type": .string("ephemeral")])
        return .object(updated)
    }

    private static func convert(_ value: Any) throws -> ClaudeJSON {
        if value is NSNull {
            return .null
        }
        if let bool = value as? Bool {
            return .bool(bool)
        }
        if let string = value as? String {
            return .string(string)
        }
        if let dictionary = value as? [String: Any] {
            var result: [String: ClaudeJSON] = [:]
            result.reserveCapacity(dictionary.count)
            for (key, item) in dictionary {
                result[key] = try convert(item)
            }
            return .object(result)
        }
        if let array = value as? [Any] {
            return .array(try array.map { try convert($0) })
        }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            if double.rounded(.towardZero) == double,
               double >= Double(Int.min),
               double <= Double(Int.max) {
                return .int(Int(double))
            }
            return .double(double)
        }
        throw ClaudeRequestError.invalidToolInputJSON
    }

    private static func encodeString(_ value: String) -> String {
        var result = "\""
        result.reserveCapacity(value.count + 2)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                result += "\\\""
            case 0x5C:
                result += "\\\\"
            case 0x08:
                result += "\\b"
            case 0x0C:
                result += "\\f"
            case 0x0A:
                result += "\\n"
            case 0x0D:
                result += "\\r"
            case 0x09:
                result += "\\t"
            case 0x00...0x1F:
                result += String(format: "\\u%04x", scalar.value)
            default:
                result.append(String(scalar))
            }
        }
        result += "\""
        return result
    }
}

public enum ClaudeRequestError: Error, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case invalidToolInputJSON
    case unsupportedAssistantBlock

    public var description: String {
        switch self {
        case .invalidToolInputJSON:
            return "A tool input was not complete JSON"
        case .unsupportedAssistantBlock:
            return "The assistant returned a block type Webby cannot continue"
        }
    }

    public var debugDescription: String {
        description
    }
}

/// A deterministic Claude Messages request body.
///
/// The top-level system instructions, fixed tool definition and note prefix are
/// stable for unchanged conversation inputs. Request time and the current page
/// exist only in the final user message.
public struct ClaudeRequest: Equatable, Sendable {
    public struct SystemBlock: Equatable, Sendable {
        public let text: String
        public let cache: Bool

        public init(text: String, cache: Bool = false) {
            self.text = text
            self.cache = cache
        }
    }

    public struct Message: Equatable, Sendable {
        public enum Role: String, Equatable, Sendable {
            case user
            case assistant
        }

        public let role: Role
        public let content: [ClaudeJSON]

        public init(role: Role, content: [ClaudeJSON]) {
            self.role = role
            self.content = content
        }

        public init(role: Role, text: String) {
            self.init(role: role, content: [.object(["type": .string("text"), "text": .string(text)])])
        }
    }

    public let configuration: ClaudeConfiguration
    public let system: [SystemBlock]
    public let messages: [Message]
    /// The history message whose last content block carries the moving cache
    /// breakpoint. It is never the current volatile user message.
    public let cacheBreakpointMessageIndex: Int?

    public init(
        configuration: ClaudeConfiguration,
        system: [SystemBlock],
        messages: [Message],
        cacheBreakpointMessageIndex: Int? = nil
    ) {
        self.configuration = configuration
        self.system = system
        self.messages = messages
        self.cacheBreakpointMessageIndex = cacheBreakpointMessageIndex
    }

    public var tools: [ClaudeJSON] {
        [Self.readNoteToolDefinition]
    }

    public var body: Data {
        Data(encodedBodyString().utf8)
    }

    public func encodedBody() -> Data {
        body
    }

    public func preparedRequest(apiKey: String? = nil) -> PreparedRequest {
        var headers: [String: String] = [
            "accept": "text/event-stream",
            "anthropic-version": configuration.apiVersion,
            "content-type": "application/json",
        ]
        if let apiKey {
            headers["x-api-key"] = apiKey
        }
        return PreparedRequest(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            headers: headers,
            body: body
        )
    }

    /// Appends the assistant content exactly as received and one user message
    /// containing only the tool_result blocks. Previous messages are not edited.
    public func appendingToolRound(
        assistant: ClaudeCompletion,
        toolResults: [ClaudeToolResult]
    ) throws -> ClaudeRequest {
        let blocks = try Self.assistantContent(for: assistant)
        var next = messages
        next.append(Message(role: .assistant, content: blocks))
        next.append(Message(role: .user, content: toolResults.map(\.json)))
        return replacing(messages: next)
    }

    /// Used by `pause_turn`, which resends assistant content without a tool result.
    public func appendingAssistant(_ assistant: ClaudeCompletion) throws -> ClaudeRequest {
        var next = messages
        next.append(Message(
            role: .assistant,
            content: try Self.assistantContent(for: assistant)
        ))
        return replacing(messages: next)
    }

    private func replacing(messages: [Message]) -> ClaudeRequest {
        ClaudeRequest(
            configuration: configuration,
            system: system,
            messages: messages,
            cacheBreakpointMessageIndex: cacheBreakpointMessageIndex
        )
    }

    private func encodedBodyString() -> String {
        let systemBlocks = system.map { block -> ClaudeJSON in
            var object: [String: ClaudeJSON] = [
                "type": .string("text"),
                "text": .string(block.text),
            ]
            if block.cache {
                object["cache_control"] = .object(["type": .string("ephemeral")])
            }
            return .object(object)
        }

        let encodedMessages = messages.enumerated().map { index, message -> ClaudeJSON in
            var blocks = message.content
            if index == cacheBreakpointMessageIndex, !blocks.isEmpty {
                blocks[blocks.count - 1] = blocks[blocks.count - 1].addingCacheControl()
            }
            return .object([
                "role": .string(message.role.rawValue),
                "content": .array(blocks),
            ])
        }

        let body = ClaudeJSON.object([
            "model": .string(configuration.model),
            "max_tokens": .int(configuration.maxOutputTokens),
            "stream": .bool(true),
            "thinking": .object(["type": .string("adaptive")]),
            "output_config": .object(["effort": .string(configuration.effort.rawValue)]),
            "tools": .array(tools),
            "system": .array(systemBlocks),
            "messages": .array(encodedMessages),
        ])
        return body.encoded()
    }

    private static func assistantContent(for completion: ClaudeCompletion) throws -> [ClaudeJSON] {
        try completion.blocks.map { block in
            switch block {
            case let .text(text):
                return .object(["type": .string("text"), "text": .string(text)])
            case let .thinking(text, signature):
                return .object([
                    "type": .string("thinking"),
                    "thinking": .string(text),
                    "signature": .string(signature),
                ])
            case let .redactedThinking(data):
                return .object([
                    "type": .string("redacted_thinking"),
                    "data": .string(data),
                ])
            case let .toolUse(id, name, inputJSON):
                return .object([
                    "type": .string("tool_use"),
                    "id": .string(id),
                    "name": .string(name),
                    "input": try ClaudeJSON.parse(inputJSON),
                ])
            case .unknown:
                throw ClaudeRequestError.unsupportedAssistantBlock
            }
        }
    }

    /// The one fixed tool. It is a lookup, not a search.
    public static let readNoteToolDefinition: ClaudeJSON = .object([
        "name": .string("read_note"),
        "description": .string(
            "Return the full text of one note by the alias listed in the notes block. "
                + "Use it only when a note is truncated or omitted."
        ),
        "strict": .bool(true),
        "input_schema": .object([
            "type": .string("object"),
            "properties": .object([
                "alias": .object([
                    "type": .string("string"),
                    "description": .string("A note alias such as N1."),
                ]),
            ]),
            "required": .array([.string("alias")]),
            "additionalProperties": .bool(false),
        ]),
    ])
}

/// One tool result block for a continuation's user message.
public struct ClaudeToolResult: Equatable, Sendable {
    public let toolUseID: String
    public let content: String
    public let isError: Bool

    public init(toolUseID: String, content: String, isError: Bool = false) {
        self.toolUseID = toolUseID
        self.content = content
        self.isError = isError
    }

    var json: ClaudeJSON {
        .object([
            "type": .string("tool_result"),
            "tool_use_id": .string(toolUseID),
            "content": .string(content),
            "is_error": .bool(isError),
        ])
    }
}
