import Foundation
import Testing
import WebbyCore
@testable import WebbyAgent

private func event(_ name: String, _ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return "event: \(name)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
}

private func textBlock(index: Int, _ text: String) -> String {
    event("content_block_start", [
        "type": "content_block_start",
        "index": index,
        "content_block": ["type": "text", "text": ""],
    ])
        + event("content_block_delta", [
            "type": "content_block_delta",
            "index": index,
            "delta": ["type": "text_delta", "text": text],
        ])
        + event("content_block_stop", ["type": "content_block_stop", "index": index])
}

private func thinkingBlock(index: Int, text: String, signature: String) -> String {
    event("content_block_start", [
        "type": "content_block_start",
        "index": index,
        "content_block": ["type": "thinking"],
    ])
        + event("content_block_delta", [
            "type": "content_block_delta",
            "index": index,
            "delta": ["type": "thinking_delta", "thinking": text],
        ])
        + event("content_block_delta", [
            "type": "content_block_delta",
            "index": index,
            "delta": ["type": "signature_delta", "signature": signature],
        ])
        + event("content_block_stop", ["type": "content_block_stop", "index": index])
}

private func toolBlock(index: Int, id: String, alias: String) -> String {
    let input = "{\"alias\":\"\(alias)\"}"
    return event("content_block_start", [
        "type": "content_block_start",
        "index": index,
        "content_block": [
            "type": "tool_use",
            "id": id,
            "name": "read_note",
            "input": [:],
        ],
    ])
        + event("content_block_delta", [
            "type": "content_block_delta",
            "index": index,
            "delta": ["type": "input_json_delta", "partial_json": input],
        ])
        + event("content_block_stop", ["type": "content_block_stop", "index": index])
}

private func response(
    id: String = "msg_synthetic",
    blocks: [String],
    stop: String,
    inputTokens: Int = 10,
    outputTokens: Int = 2
) -> String {
    event("message_start", [
        "type": "message_start",
        "message": [
            "id": id,
            "model": "synthetic-model",
            "usage": ["input_tokens": inputTokens, "output_tokens": 0],
        ],
    ])
        + blocks.joined()
        + event("message_delta", [
            "type": "message_delta",
            "delta": ["stop_reason": stop, "stop_sequence": NSNull()],
            "usage": ["output_tokens": outputTokens],
        ])
        + event("message_stop", ["type": "message_stop"])
}

private final class RecordingTransport: ClaudeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [String]
    private var captured: [PreparedRequest] = []

    init(_ responses: [String]) {
        self.responses = responses
    }

    func stream(_ request: PreparedRequest) -> AsyncThrowingStream<Data, Error> {
        lock.lock()
        captured.append(request)
        let index = min(captured.count - 1, responses.count - 1)
        let body = responses[index]
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(Data(body.utf8))
            continuation.finish()
        }
    }

    func requests() -> [PreparedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
}

private final class InvalidAfterFirstCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0

    func isValid() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        checks += 1
        return checks > 1
    }
}

private func preparedTurn(
    notes: [Note],
    validator: @escaping @Sendable (String) async -> Bool = { _ in true }
) -> PreparedTurn {
    let context = agentContext()
    let assembled = ContextAssembler.assemble(
        snapshot: AgentSnapshot(notes: notes),
        context: context,
        conversation: agentConversation(scope: .allNotes, context: context),
        now: Date(timeIntervalSince1970: 1_800_000_000),
        question: "What did I write?"
    )
    return PreparedTurn(
        request: assembled.request,
        snapshot: assembled.turnSnapshot,
        authorizationValidator: validator
    )
}

@Test func toolLoopResendsAssistantBlocksAndToolResultExactly() async throws {
    let first = response(
        blocks: [
            thinkingBlock(index: 0, text: "reasoning", signature: "sig-1"),
            textBlock(index: 1, "Checking."),
            toolBlock(index: 2, id: "toolu_1", alias: "N1"),
        ],
        stop: "tool_use"
    )
    let second = response(
        blocks: [textBlock(index: 0, "The answer is [N1].")],
        stop: "end_turn"
    )
    let transport = RecordingTransport([first, second])
    let turn = preparedTurn(notes: [agentNote(id: 1, text: "Full note text")])
    let runner = ClaudeConversationRunner(transport: transport)

    let result = try await runner.run(turn)

    #expect(result.answerText == "The answer is [N1].")
    #expect(result.termination == .completed)
    #expect(result.readAliases == ["N1"])
    #expect(result.citations.map(\.alias) == ["N1"])
    #expect(transport.requests().count == 2)

    let completion = ClaudeCompletion(
        blocks: [
            .thinking(text: "reasoning", signature: "sig-1"),
            .text("Checking."),
            .toolUse(id: "toolu_1", name: "read_note", inputJSON: "{\"alias\":\"N1\"}"),
        ],
        usage: ClaudeUsage(inputTokens: 10, outputTokens: 2),
        stopReason: .toolUse,
        stopSequence: nil
    )
    let expected = try turn.request.appendingToolRound(
        assistant: completion,
        toolResults: [ClaudeToolResult(toolUseID: "toolu_1", content: "Full note text")]
    )
    #expect(transport.requests()[1].body == expected.body)
}

@Test func parallelToolCallsAreAnsweredInOneUserMessage() async throws {
    let first = response(
        blocks: [
            toolBlock(index: 0, id: "toolu_1", alias: "N1"),
            toolBlock(index: 1, id: "toolu_2", alias: "N2"),
        ],
        stop: "tool_use"
    )
    let second = response(blocks: [textBlock(index: 0, "Done.")], stop: "end_turn")
    let transport = RecordingTransport([first, second])
    let turn = preparedTurn(notes: [
        agentNote(id: 1, text: "one"),
        agentNote(id: 2, text: "two"),
    ])

    _ = try await ClaudeConversationRunner(transport: transport).run(turn)

    let object = try JSONSerialization.jsonObject(
        with: transport.requests()[1].body
    ) as! [String: Any]
    let messages = object["messages"] as! [[String: Any]]
    let assistant = messages[messages.count - 2]
    let user = messages[messages.count - 1]
    #expect((assistant["content"] as! [[String: Any]]).filter {
        $0["type"] as? String == "tool_use"
    }.count == 2)
    let results = (user["content"] as! [[String: Any]]).filter {
        $0["type"] as? String == "tool_result"
    }
    #expect(user["role"] as? String == "user")
    #expect(results.count == 2)
    #expect(results.map { $0["tool_use_id"] as? String } == ["toolu_1", "toolu_2"])
}

@Test func unknownAliasAndReadCapReturnErrorToolResults() async throws {
    var blocks: [String] = []
    for index in 0..<6 {
        blocks.append(toolBlock(index: index, id: "toolu_\(index)", alias: "N1"))
    }
    blocks.append(toolBlock(index: 6, id: "toolu_unknown", alias: "N99"))
    let first = response(blocks: blocks, stop: "tool_use")
    let second = response(blocks: [textBlock(index: 0, "Answer.")], stop: "end_turn")
    let transport = RecordingTransport([first, second])
    let turn = preparedTurn(notes: [agentNote(id: 1, text: "one")])

    _ = try await ClaudeConversationRunner(transport: transport).run(turn)

    let object = try JSONSerialization.jsonObject(
        with: transport.requests()[1].body
    ) as! [String: Any]
    let messages = object["messages"] as! [[String: Any]]
    let results = (messages.last!["content"] as! [[String: Any]]).filter {
        $0["type"] as? String == "tool_result"
    }
    #expect(results.count == 7)
    #expect(results[0]["is_error"] as? Bool == false)
    #expect(results[4]["is_error"] as? Bool == false)
    #expect(results[5]["is_error"] as? Bool == true)
    #expect(results[5]["content"] as? String == "The read_note limit for this turn was reached.")
    #expect(results[6]["is_error"] as? Bool == true)
    #expect(results[6]["content"] as? String == "Unknown note alias N99.")
}

@Test func pauseTurnResendsAssistantWithoutToolResult() async throws {
    let first = response(
        blocks: [
            thinkingBlock(index: 0, text: "pause reason", signature: "sig-pause"),
            textBlock(index: 1, "First part. "),
        ],
        stop: "pause_turn"
    )
    let second = response(
        blocks: [textBlock(index: 0, "Second part.")],
        stop: "end_turn"
    )
    let transport = RecordingTransport([first, second])
    let turn = preparedTurn(notes: [agentNote(id: 1, text: "one")])

    let result = try await ClaudeConversationRunner(transport: transport).run(turn)

    #expect(result.answerText == "First part. Second part.")
    #expect(result.termination == .completed)
    let object = try JSONSerialization.jsonObject(
        with: transport.requests()[1].body
    ) as! [String: Any]
    let messages = object["messages"] as! [[String: Any]]
    let last = messages.last!
    #expect(last["role"] as? String == "assistant")
    let content = last["content"] as! [[String: Any]]
    #expect(content.map { $0["type"] as? String } == ["thinking", "text"])
    #expect(content[0]["signature"] as? String == "sig-pause")
    #expect(!String(decoding: transport.requests()[1].body, as: UTF8.self)
        .contains("tool_result"))
}

@Test func truncationAndRefusalAreTerminal() async throws {
    let truncated = try await ClaudeConversationRunner(
        transport: RecordingTransport([
            response(blocks: [textBlock(index: 0, "partial")], stop: "max_tokens"),
        ])
    ).run(preparedTurn(notes: [agentNote(id: 1, text: "one")]))
    #expect(truncated.termination == .truncated)
    #expect(truncated.answerText == "partial")

    let refused = try await ClaudeConversationRunner(
        transport: RecordingTransport([
            response(blocks: [textBlock(index: 0, "no")], stop: "refusal"),
        ])
    ).run(preparedTurn(notes: [agentNote(id: 1, text: "one")]))
    #expect(refused.termination == .refused)
    #expect(refused.answerText == "no")
}

@Test func unknownStopReasonIsAProtocolErrorWithPartialText() async throws {
    let transport = RecordingTransport([
        response(blocks: [textBlock(index: 0, "partial")], stop: "future_stop"),
    ])

    do {
        _ = try await ClaudeConversationRunner(transport: transport)
            .run(preparedTurn(notes: [agentNote(id: 1, text: "one")]))
        Issue.record("Expected an unknown stop reason error")
    } catch let error as ClaudeConversationError {
        #expect(error == .unknownStopReason(reason: "future_stop", partialAnswer: "partial"))
    }
}

@Test func invalidAuthorizationAbortsBeforeTheContinuation() async throws {
    let transport = RecordingTransport([
        response(blocks: [toolBlock(index: 0, id: "toolu_1", alias: "N1")], stop: "tool_use"),
        response(blocks: [textBlock(index: 0, "should not happen")], stop: "end_turn"),
    ])
    let flag = InvalidAfterFirstCheck()
    let turn = preparedTurn(notes: [agentNote(id: 1, text: "one")]) { _ in
        flag.isValid()
    }

    do {
        _ = try await ClaudeConversationRunner(transport: transport).run(turn)
        Issue.record("Expected authorization invalidation")
    } catch let error as ClaudeConversationError {
        #expect(error == .authorizationInvalidated)
    }
    #expect(transport.requests().count == 1)
}
