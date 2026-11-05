import Foundation
import Testing
@testable import WebbyAgent

@Test func parsesEveryByteSplitWithCRLF() throws {
    let source = "event: message_start\r\ndata: {\"a\":1}\r\n\r\nevent: ping\r\ndata: {}\r\n\r\n"
    var parser = SSEParser()
    var events: [SSEEvent] = []

    for byte in source.utf8 {
        events += try parser.feed(Data([byte]))
    }
    events += try parser.finish()

    #expect(events == [
        SSEEvent(name: "message_start", data: "{\"a\":1}"),
        SSEEvent(name: "ping", data: "{}"),
    ])
}

@Test func splitsCRLFAndUTF8AcrossChunks() throws {
    let source = "event: note\ndata: café\n\n"
    let bytes = Array(source.utf8)
    // Split before the final byte of the two-byte é and between CR/LF.
    let split = try #require(bytes.lastIndex(of: 0xA9))
    var parser = SSEParser()
    var events = try parser.feed(Data(bytes[..<split]))
    events += try parser.feed(Data(bytes[split...]))
    events += try parser.finish()

    #expect(events == [SSEEvent(name: "note", data: "café")])
}

@Test func joinsMultiLineDataAndIgnoresComments() throws {
    let source = "event: custom\n: keep-alive\ndata: first\ndata: second\nid: 4\n\n"
    var parser = SSEParser()

    var events = try parser.feed(Data(source.utf8))
    events += try parser.finish()

    #expect(events == [SSEEvent(name: "custom", data: "first\nsecond")])
}

@Test func defaultsEventNameToMessageAndSkipsEmptyEvents() throws {
    let source = "data: one\n\nevent: empty\n\n: comment only\n\n"
    var parser = SSEParser()

    var events = try parser.feed(Data(source.utf8))
    events += try parser.finish()

    #expect(events == [SSEEvent(name: "message", data: "one")])
}

@Test func flushesPendingEventAtEOF() throws {
    var parser = SSEParser()
    let first = try parser.feed(Data("event: custom\ndata: tail".utf8))
    let second = try parser.finish()

    #expect(first.isEmpty)
    #expect(second == [SSEEvent(name: "custom", data: "tail")])
}

@Test func enforcesLineAndEventLimits() throws {
    var lineLimited = SSEParser(maxLineBytes: 4)
    #expect(throws: SSEParserError.lineTooLong(limit: 4)) {
        try lineLimited.feed(Data("data: 1".utf8))
    }

    var eventLimited = SSEParser(maxEventBytes: 5)
    #expect(throws: SSEParserError.eventTooLarge(limit: 5)) {
        try eventLimited.feed(Data("data: abc\ndata: def\n\n".utf8))
    }
}

@Test func rejectsInvalidUTF8() throws {
    var parser = SSEParser()
    let invalid = Data([0x64, 0x61, 0x74, 0x61, 0x3A, 0x20, 0xFF, 0x0A])

    #expect(throws: SSEParserError.invalidUTF8) {
        try parser.feed(invalid)
    }
}

@Test func feedPreservesParsedEventsWhenALaterLineFails() throws {
    var parser = SSEParser(maxLineBytes: 32, maxEventBytes: 1_024)
    var events: [SSEEvent] = []
    let first = Data("event: ping\ndata: {}\n\n".utf8)
    let oversized = Data(("data: " + String(repeating: "x", count: 64) + "\n\n").utf8)

    do {
        try parser.feed(first + oversized, into: &events)
        Issue.record("expected the oversized line to fail")
    } catch {
        // The event parsed before the failure must survive.
    }
    #expect(events.map(\.name) == ["ping"])
}
