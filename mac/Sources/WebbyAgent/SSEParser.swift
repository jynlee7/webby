import Foundation

/// One dispatched server-sent event.
public struct SSEEvent: Equatable, Sendable {
    public let name: String
    public let data: String

    public init(name: String, data: String) {
        self.name = name
        self.data = data
    }
}

public enum SSEParserError: Error, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case lineTooLong(limit: Int)
    case eventTooLarge(limit: Int)
    case invalidUTF8

    public var description: String {
        switch self {
        case let .lineTooLong(limit):
            return "SSE line exceeded \(limit) bytes"
        case let .eventTooLarge(limit):
            return "SSE event exceeded \(limit) bytes"
        case .invalidUTF8:
            return "SSE line was not valid UTF-8"
        }
    }

    public var debugDescription: String {
        description
    }
}

/// Incremental SSE parser over raw bytes.
///
/// It never assumes chunk boundaries: LF, CRLF, split CRLF and split UTF-8 all
/// work because lines are decoded only after a complete LF-terminated line exists.
/// A blank line ends an event and is always kept as an event boundary. Unknown
/// event names are emitted unchanged so callers can decide whether to ignore them.
public struct SSEParser: Sendable {
    public let maxLineBytes: Int
    public let maxEventBytes: Int

    private var lineBuffer = Data()
    private var eventName: String?
    private var dataLines: [String] = []
    private var dataByteCount = 0
    private var finished = false

    public init(maxLineBytes: Int = 64 * 1024, maxEventBytes: Int = 1024 * 1024) {
        precondition(maxLineBytes > 0, "maxLineBytes must be positive")
        precondition(maxEventBytes > 0, "maxEventBytes must be positive")
        self.maxLineBytes = maxLineBytes
        self.maxEventBytes = maxEventBytes
    }

    public mutating func feed(_ data: Data) throws -> [SSEEvent] {
        var events: [SSEEvent] = []
        try feed(data, into: &events)
        return events
    }

    /// Appends every event parsed before a failure, so callers can still surface
    /// partial output from the same chunk.
    public mutating func feed(_ data: Data, into events: inout [SSEEvent]) throws {
        guard !finished else { return [] }
        lineBuffer.append(data)

        var pending = lineBuffer
        lineBuffer.removeAll(keepingCapacity: true)

        var lineStart = pending.startIndex
        for index in pending.indices where pending[index] == 0x0A {
            let length = pending.distance(from: lineStart, to: index)
            guard length <= maxLineBytes else {
                throw SSEParserError.lineTooLong(limit: maxLineBytes)
            }
            let line = pending[lineStart..<index]
            try processLine(Data(line), into: &events)
            lineStart = pending.index(after: index)
        }

        if lineStart < pending.endIndex {
            let remainder = pending[lineStart..<pending.endIndex]
            guard remainder.count <= maxLineBytes else {
                throw SSEParserError.lineTooLong(limit: maxLineBytes)
            }
            lineBuffer = Data(remainder)
        }

    }

    /// Flushes a final complete-looking line and any pending event at EOF.
    /// A caller that requires a terminal event must check for it separately.
    public mutating func finish() throws -> [SSEEvent] {
        guard !finished else { return [] }
        finished = true

        var events: [SSEEvent] = []
        if !lineBuffer.isEmpty {
            try processLine(lineBuffer, into: &events)
            lineBuffer.removeAll(keepingCapacity: true)
        }
        dispatch(into: &events)
        return events
    }

    private mutating func processLine(_ rawLine: Data, into events: inout [SSEEvent]) throws {
        var line = rawLine
        if line.last == 0x0D {
            line.removeLast()
        }

        if line.isEmpty {
            dispatch(into: &events)
            return
        }

        let bytes = [UInt8](line)
        if bytes[0] == 0x3A {
            return // Comment.
        }

        let colon = bytes.firstIndex(of: 0x3A)
        let fieldBytes: ArraySlice<UInt8>
        var valueBytes: ArraySlice<UInt8>

        if let colon {
            fieldBytes = bytes[..<colon]
            let afterColon = bytes.index(after: colon)
            if afterColon < bytes.endIndex, bytes[afterColon] == 0x20 {
                valueBytes = bytes[bytes.index(after: afterColon)...]
            } else {
                valueBytes = bytes[afterColon...]
            }
        } else {
            fieldBytes = bytes[...]
            valueBytes = bytes[bytes.endIndex...]
        }

        guard let field = String(bytes: fieldBytes, encoding: .utf8) else {
            throw SSEParserError.invalidUTF8
        }
        guard let value = String(bytes: valueBytes, encoding: .utf8) else {
            throw SSEParserError.invalidUTF8
        }

        switch field {
        case "data":
            let additional = value.utf8.count + (dataLines.isEmpty ? 0 : 1)
            guard dataByteCount + additional <= maxEventBytes else {
                throw SSEParserError.eventTooLarge(limit: maxEventBytes)
            }
            dataByteCount += additional
            dataLines.append(value)
        case "event":
            eventName = value
        default:
            // id, retry and unknown fields are ignored.
            break
        }
    }

    private mutating func dispatch(into events: inout [SSEEvent]) {
        defer {
            eventName = nil
            dataLines.removeAll(keepingCapacity: true)
            dataByteCount = 0
        }

        guard !dataLines.isEmpty else { return }
        events.append(SSEEvent(name: eventName ?? "message", data: dataLines.joined(separator: "\n")))
    }
}
