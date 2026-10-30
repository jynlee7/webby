import Foundation
import Testing
@testable import WebbyAgent

private func sse(_ name: String, _ json: String) -> String {
    "event: \(name)\ndata: \(json)\n\n"
}

private func chunks(of text: String, size: Int) -> [Data] {
    let bytes = Array(text.utf8)
    var result: [Data] = []
    var start = 0
    while start < bytes.count {
        let end = min(start + size, bytes.count)
        result.append(Data(bytes[start..<end]))
        start = end
    }
    return result
}

private func preparedRequest() -> PreparedRequest {
    PreparedRequest(
        url: URL(string: "https://example.invalid/v1/messages")!,
        headers: ["content-type": "application/json"],
        body: Data("{}".utf8)
    )
}

private func collect(_ stream: AsyncThrowingStream<AgentEvent, Error>) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

private struct ScriptedTransport: ClaudeTransport {
    let chunks: [Data]
    let failure: ClaudeTransportError?

    init(chunks: [Data], failure: ClaudeTransportError? = nil) {
        self.chunks = chunks
        self.failure = failure
    }

    func stream(_ request: PreparedRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.finish()
            }
        }
    }
}

private enum TestTransportFailure: Error, Sendable {
    case unexpected
}

private struct GenericFailingTransport: ClaudeTransport {
    func stream(_ request: PreparedRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: TestTransportFailure.unexpected)
        }
    }
}

private actor CancellationProbe {
    private var cancelled = false

    func markCancelled() {
        cancelled = true
    }

    func isCancelled() -> Bool {
        cancelled
    }
}

private struct HangingTransport: ClaudeTransport {
    let probe: CancellationProbe
    let firstChunk: Data

    func stream(_ request: PreparedRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(firstChunk)
            continuation.onTermination = { @Sendable _ in
                Task {
                    await probe.markCancelled()
                }
            }
        }
    }
}

@Test func replaysDocumentedEventsAcrossChunkBoundaries() async throws {
    let start = sse("message_start", #"{"type":"message_start","message":{"id":"msg_1","model":"synthetic-model","usage":{"input_tokens":10,"output_tokens":0,"cache_creation_input_tokens":2,"cache_read_input_tokens":3}}}"#)
    let thinkingStart = sse("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}"#)
    let thinkingDelta = sse("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"abc"}}"#)
    let signatureDelta = sse("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#)
    let thinkingStop = sse("content_block_stop", #"{"type":"content_block_stop","index":0}"#)
    let textStart = sse("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#)
    let textDelta1 = sse("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}"#)
    let textDelta2 = sse("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" world"}}"#)
    let textStop = sse("content_block_stop", #"{"type":"content_block_stop","index":1}"#)
    let toolStart = sse("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_note","input":{}}}"#)
    let toolDelta1 = sse("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"alias\":"}}"#)
    let toolDelta2 = sse("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"N1\"}"}}"#)
    let toolStop = sse("content_block_stop", #"{"type":"content_block_stop","index":2}"#)
    let ping = sse("ping", #"{"type":"ping"}"#)
    let unknown = sse("future_event", "not-json")
    let messageDelta = sse("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":5}}"#)
    let messageStop = sse("message_stop", #"{"type":"message_stop"}"#)

    let source = start + thinkingStart + thinkingDelta + signatureDelta + thinkingStop
        + textStart + textDelta1 + textDelta2 + textStop
        + toolStart + toolDelta1 + toolDelta2 + toolStop
        + ping + unknown + messageDelta + messageStop

    let transport = ScriptedTransport(chunks: chunks(of: source, size: 3))
    let events = try await collect(ClaudeClient(transport: transport).stream(preparedRequest()))

    let startUsage = ClaudeUsage(inputTokens: 10, cacheCreationInputTokens: 2, cacheReadInputTokens: 3)
    let finalUsage = ClaudeUsage(
        inputTokens: 10,
        outputTokens: 5,
        cacheCreationInputTokens: 2,
        cacheReadInputTokens: 3
    )
    let expected: [AgentEvent] = [
        .messageStart(ClaudeMessageStart(id: "msg_1", model: "synthetic-model", usage: startUsage)),
        .usage(startUsage),
        .contentBlockStart(index: 0, block: .thinking),
        .contentBlockDelta(index: 0, delta: .thinking("abc")),
        .contentBlockDelta(index: 0, delta: .signature("sig")),
        .contentBlockStop(index: 0),
        .contentBlockStart(index: 1, block: .text),
        .contentBlockDelta(index: 1, delta: .text("Hello")),
        .contentBlockDelta(index: 1, delta: .text(" world")),
        .contentBlockStop(index: 1),
        .contentBlockStart(index: 2, block: .toolUse(id: "toolu_1", name: "read_note")),
        .contentBlockDelta(index: 2, delta: .inputJSON("{\"alias\":")),
        .contentBlockDelta(index: 2, delta: .inputJSON("\"N1\"}")),
        .contentBlockStop(index: 2),
        .ping,
        .messageDelta(ClaudeMessageDelta(
            stopReason: .toolUse,
            stopSequence: nil,
            usage: finalUsage
        )),
        .usage(finalUsage),
        .messageStop,
        .completed(ClaudeCompletion(
            blocks: [
                .thinking(text: "abc", signature: "sig"),
                .text("Hello world"),
                .toolUse(id: "toolu_1", name: "read_note", inputJSON: "{\"alias\":\"N1\"}"),
            ],
            usage: finalUsage,
            stopReason: .toolUse,
            stopSequence: nil
        )),
    ]
    #expect(events == expected)
}

@Test func surfacesRefusalAndPartialText() async throws {
    let source = sse("message_start", #"{"type":"message_start","message":{"id":"msg_2","model":"synthetic-model","usage":{"input_tokens":1}}}"#)
        + sse("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
        + sse("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}"#)
        + sse("content_block_stop", #"{"type":"content_block_stop","index":0}"#)
        + sse("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_sequence":null},"usage":{"output_tokens":2}}"#)
        + sse("message_stop", #"{"type":"message_stop"}"#)

    let events = try await collect(
        ClaudeClient(transport: ScriptedTransport(chunks: chunks(of: source, size: 7))).stream(preparedRequest())
    )

    #expect(events.contains(.refusal))
    let completion = try #require(events.compactMap { event -> ClaudeCompletion? in
        guard case let .completed(completion) = event else { return nil }
        return completion
    }.first)
    #expect(completion.text == "partial")
    #expect(completion.stopReason == .refusal)
}

@Test func ignoresUnknownEventsAndUnknownBlockTypes() async throws {
    let source = sse("message_start", #"{"type":"message_start","message":{"id":"msg_3","model":"synthetic-model","usage":{}}}"#)
        + sse("future_event", #"{"type":"future_event","future_field":{"secret":"none"}}"#)
        + sse("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"future_block"}}"#)
        + sse("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"future_delta","value":"ignored"}}"#)
        + sse("content_block_stop", #"{"type":"content_block_stop","index":0}"#)
        + sse("message_stop", #"{"type":"message_stop"}"#)

    let events = try await collect(
        ClaudeClient(transport: ScriptedTransport(chunks: [Data(source.utf8)])).stream(preparedRequest())
    )

    #expect(events.contains(.contentBlockStart(index: 0, block: .unknown(type: "future_block"))))
    #expect(events.contains(.contentBlockDelta(index: 0, delta: .unknown(type: "future_delta"))))
    #expect(!events.contains { event in
        if case .messageDelta = event { return true }
        return false
    })
}

@Test func rejectsMalformedKnownEventJSON() async throws {
    let source = sse("message_start", "{not-json}")

    do {
        _ = try await collect(
            ClaudeClient(transport: ScriptedTransport(chunks: [Data(source.utf8)])).stream(preparedRequest())
        )
        Issue.record("Expected malformed JSON error")
    } catch let error as ClaudeClientError {
        #expect(error == .malformedJSON(event: "message_start"))
    }
}

@Test func rejectsPrematureEOFWithoutMessageStop() async throws {
    let source = sse("message_start", #"{"type":"message_start","message":{"id":"msg_4","model":"synthetic-model","usage":{}}}"#)

    do {
        _ = try await collect(
            ClaudeClient(transport: ScriptedTransport(chunks: chunks(of: source, size: 5))).stream(preparedRequest())
        )
        Issue.record("Expected unexpected end of stream")
    } catch let error as ClaudeClientError {
        #expect(error == .unexpectedEndOfStream)
    }
}

@Test func surfacesStreamErrorEvent() async throws {
    let source = sse("error", #"{"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#)

    do {
        _ = try await collect(
            ClaudeClient(transport: ScriptedTransport(chunks: [Data(source.utf8)])).stream(preparedRequest())
        )
        Issue.record("Expected stream error")
    } catch let error as ClaudeClientError {
        #expect(error == .streamError(ClaudeStreamError(type: "overloaded_error", message: "busy")))
    }
}

@Test func mapsTransportErrorsWithoutLeakingDetails() async throws {
    do {
        _ = try await collect(
            ClaudeClient(transport: ScriptedTransport(chunks: [], failure: .httpStatus(500))).stream(preparedRequest())
        )
        Issue.record("Expected transport error")
    } catch let error as ClaudeClientError {
        #expect(error == .transport(.httpStatus(500)))
    }

    do {
        _ = try await collect(
            ClaudeClient(transport: GenericFailingTransport()).stream(preparedRequest())
        )
        Issue.record("Expected generic transport error")
    } catch let error as ClaudeClientError {
        #expect(error == .transport(.network))
        #expect(!error.description.contains("unexpected"))
    }
}

@Test func cancellationCancelsTransport() async throws {
    let probe = CancellationProbe()
    let first = sse("message_start", #"{"type":"message_start","message":{"id":"msg_5","model":"synthetic-model","usage":{}}}"#)
    let transport = HangingTransport(probe: probe, firstChunk: Data(first.utf8))
    let stream = ClaudeClient(transport: transport).stream(preparedRequest())

    let (signals, signalContinuation) = AsyncStream<Void>.makeStream()
    let consumer = Task {
        for try await event in stream {
            if case .messageStart = event {
                signalContinuation.yield()
            }
        }
    }
    var signalIterator = signals.makeAsyncIterator()
    _ = await signalIterator.next()
    consumer.cancel()

    var cancelled = false
    for _ in 0..<100 {
        if await probe.isCancelled() {
            cancelled = true
            break
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(cancelled)
}
