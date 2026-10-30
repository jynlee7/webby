import Foundation
import Testing
import WebbyCore
@testable import WebbyAgent

private func jsonString(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

@Test func requestUsesFixedFieldsDeterministicJSONAndExplicitCacheBreakpoints() throws {
    let context = agentContext()
    let request = ContextAssembler.assemble(
        snapshot: AgentSnapshot(notes: [agentNote(id: 1, text: "A note.")]),
        context: context,
        conversation: agentConversation(scope: .allNotes, context: context),
        now: Date(timeIntervalSince1970: 1_800_000_000),
        question: "What did I decide?"
    ).request
    let body = try requestString(request)
    let object = try requestObject(request)

    #expect(body.hasPrefix("{\"max_tokens\":"))
    #expect(object["model"] as? String == "synthetic-model")
    #expect(object["max_tokens"] as? Int == 4_096)
    #expect(object["stream"] as? Bool == true)

    let thinking = try #require(object["thinking"] as? [String: Any])
    #expect(thinking["type"] as? String == "adaptive")
    let output = try #require(object["output_config"] as? [String: Any])
    #expect(output["effort"] as? String == "medium")

    let tools = try #require(object["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    #expect(tools[0]["name"] as? String == "read_note")
    #expect(tools[0]["strict"] as? Bool == true)

    let system = try #require(object["system"] as? [[String: Any]])
    #expect(system.count == 2)
    #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    #expect((system[1]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    #expect((system[1]["text"] as? String)?.contains("A note.") == true)

    #expect(!body.contains("\"temperature\""))
    #expect(!body.contains("\"top_p\""))
    #expect(!body.contains("\"top_k\""))
    #expect(!body.contains("budget_tokens"))
    #expect(!body.contains("prefill"))
}

@Test func requestTimeAndCurrentPageExistOnlyInTheFinalUserMessage() throws {
    let start = agentContext()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let askedAt = AgentTimestamp.rfc3339(now)
    #expect(askedAt == "2027-01-15T08:00:00Z")

    let history = [
        ClaudeRequest.Message(role: .user, text: "earlier question"),
        ClaudeRequest.Message(role: .assistant, text: "earlier answer"),
    ]
    let conversation = agentConversation(
        scope: .allNotes,
        context: start,
        history: history
    )
    let request = ContextAssembler.assemble(
        snapshot: AgentSnapshot(notes: [agentNote(id: 1, text: "A note.")]),
        context: start,
        conversation: conversation,
        now: now,
        question: "What did I decide?"
    ).request
    let object = try requestObject(request)

    let system = try #require(object["system"] as? [[String: Any]])
    let systemText = system.compactMap { $0["text"] as? String }.joined(separator: "\n")
    #expect(!systemText.contains(askedAt))
    #expect(!systemText.contains("What did I decide?"))

    let messages = try #require(object["messages"] as? [[String: Any]])
    let final = try #require(messages.last)
    let finalContent = try #require(final["content"] as? [[String: Any]])
    let finalText = try #require(finalContent.first?["text"] as? String)
    #expect(finalText.contains("What did I decide?"))
    #expect(finalText.contains(askedAt))
    #expect(finalText.contains("from=\"example.com/a/b\""))

    for message in messages.dropLast() {
        let text = try jsonString(message)
        #expect(!text.contains(askedAt))
    }
}

@Test func unchangedInputsKeepSystemToolsAndNotesBytesWhileOnlyFinalMessageMoves() throws {
    let start = agentContext()
    let conversation = agentConversation(scope: .allNotes, context: start)
    let snapshot = AgentSnapshot(notes: [agentNote(id: 1, text: "Stable note.")])
    let first = ContextAssembler.assemble(
        snapshot: snapshot,
        context: start,
        conversation: conversation,
        now: Date(timeIntervalSince1970: 1_800_000_000),
        question: "question"
    ).request
    let otherPage = PageURL(host: "example.com", path: "/different")
    let second = ContextAssembler.assemble(
        snapshot: snapshot,
        context: Context(appBundleID: start.appBundleID, page: otherPage, tab: start.tab),
        conversation: conversation,
        now: Date(timeIntervalSince1970: 1_800_000_060),
        question: "question"
    ).request

    #expect(first.system == second.system)
    #expect(first.tools == second.tools)
    #expect(first.configuration == second.configuration)
    let firstMessages = try #require(try requestObject(first)["messages"] as? [[String: Any]])
    let secondMessages = try #require(try requestObject(second)["messages"] as? [[String: Any]])
    #expect(firstMessages.count == secondMessages.count)
    #expect(try jsonString(Array(firstMessages.dropLast()))
        == jsonString(Array(secondMessages.dropLast())))
    #expect(try jsonString(firstMessages.last!) != jsonString(secondMessages.last!))
}

@Test func continuationAppendsExactAssistantBlocksAndOneToolResultUserMessage() throws {
    let request = ContextAssembler.assemble(
        snapshot: AgentSnapshot(notes: [agentNote(id: 1, text: "A note.")]),
        context: agentContext(),
        conversation: agentConversation(scope: .allNotes),
        now: Date(timeIntervalSince1970: 1_800_000_000),
        question: "Please read note one."
    ).request
    let completion = ClaudeCompletion(
        blocks: [
            .thinking(text: "", signature: "signature-1"),
            .text("I need the full note."),
            .toolUse(id: "toolu_1", name: "read_note", inputJSON: #"{"alias":"N1"}"#),
        ],
        usage: .zero,
        stopReason: .toolUse,
        stopSequence: nil
    )
    let continuation = try request.appendingToolRound(
        assistant: completion,
        toolResults: [
            ClaudeToolResult(toolUseID: "toolu_1", content: "Full note text."),
            ClaudeToolResult(toolUseID: "toolu_2", content: "Unknown alias.", isError: true),
        ]
    )

    #expect(continuation.messages.count == request.messages.count + 2)
    #expect(Array(continuation.messages.prefix(request.messages.count)) == request.messages)

    let assistant = continuation.messages[request.messages.count]
    #expect(assistant.role == .assistant)
    #expect(assistant.content.count == 3)
    guard case let .object(thinking) = assistant.content[0] else {
        Issue.record("Expected thinking object")
        return
    }
    #expect(thinking["type"] == .string("thinking"))
    #expect(thinking["signature"] == .string("signature-1"))
    guard case let .object(toolUse) = assistant.content[2] else {
        Issue.record("Expected tool_use object")
        return
    }
    #expect(toolUse["id"] == .string("toolu_1"))
    #expect(toolUse["name"] == .string("read_note"))
    #expect(toolUse["input"] == .object(["alias": .string("N1")]))

    let toolUser = continuation.messages[request.messages.count + 1]
    #expect(toolUser.role == .user)
    #expect(toolUser.content.count == 2)
    for block in toolUser.content {
        guard case let .object(object) = block else {
            Issue.record("Expected tool_result object")
            return
        }
        #expect(object["type"] == .string("tool_result"))
    }
    #expect(continuation.messages.allSatisfy { $0.role == .user || $0.role == .assistant })
}

@Test func requestNeverLeaksQueriesFilePathsOrRawURLs() throws {
    let querySecret = "query-sentinel"
    let fileSecret = "file-sentinel"
    let page = PageURL(
        host: "example.com",
        path: "/a/b",
        query: "token=\(querySecret)"
    )
    let context = agentContext(page: page)
    let notes = [
        agentNote(
            id: 1,
            anchor: .web(page: page, scope: .page),
            sourceURL: "https://example.com/a/b?token=\(querySecret)"
        ),
        agentNote(
            id: 2,
            tab: agentTab(tabID: 99),
            sourceURL: "file:///Users/secret/\(fileSecret).txt"
        ),
    ]
    let request = ContextAssembler.assemble(
        snapshot: AgentSnapshot(notes: notes),
        context: context,
        conversation: agentConversation(scope: .allNotes, context: context),
        now: Date(timeIntervalSince1970: 1_800_000_000),
        question: "question"
    ).request
    let body = try requestString(request)

    #expect(!body.contains(querySecret))
    #expect(!body.contains(fileSecret))
    #expect(!body.contains("file:///"))
    #expect(!body.contains("https://example.com"))
    #expect(body.contains("example.com/a/b"))
    #expect(body.contains("Local file"))
}

@Test func preparedRequestUsesFixedEndpointAndConfigurationVersion() {
    let request = ContextAssembler.assemble(
        snapshot: AgentSnapshot(notes: [agentNote(id: 1, text: "A note.")]),
        context: agentContext(),
        conversation: agentConversation(scope: .allNotes),
        now: Date(timeIntervalSince1970: 1_800_000_000),
        question: "question"
    ).request
    let prepared = request.preparedRequest(apiKey: "test-key")

    #expect(prepared.url.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(prepared.headers.contains(.init(name: "anthropic-version", value: "synthetic-version")))
    #expect(prepared.headers.contains(.init(name: "x-api-key", value: "test-key")))
    #expect(prepared.body == request.body)
}

@Test func replayedToolInputKeepsNumericZeroAndOne() throws {
    let text = "{\"a\":1,\"b\":0,\"c\":true,\"d\":false}"
    let parsed = try ClaudeJSON.parse(text)

    #expect(parsed == .object([
        "a": .int(1),
        "b": .int(0),
        "c": .bool(true),
        "d": .bool(false),
    ]))
    #expect(parsed.encoded() == text)
}
