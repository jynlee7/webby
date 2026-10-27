import Foundation

/// Chrome native-messaging framing: a 32-bit length in native byte order, then that many
/// bytes of UTF-8 JSON. The bridge uses the same framing on the app socket.
public struct NativeMessageFramer: Sendable {
    public enum FramingError: Error, Equatable {
        case messageTooLarge(length: Int, limit: Int)
    }

    public static let headerLength = MemoryLayout<UInt32>.size

    /// Largest payload this reader accepts.
    public let limit: Int
    private var buffer = Data()

    public init(limit: Int) {
        self.limit = limit
    }

    /// Frames one payload for writing.
    public static func frame(_ payload: Data, limit: Int) throws -> Data {
        guard payload.count <= limit, payload.count <= Int(UInt32.max) else {
            throw FramingError.messageTooLarge(length: payload.count, limit: limit)
        }
        var length = UInt32(payload.count)
        var framed = withUnsafeBytes(of: &length) { Data($0) }
        framed.append(payload)
        return framed
    }

    /// Adds bytes read from the stream and returns every payload they complete, in order.
    /// An oversized length is rejected as soon as its header arrives. After an error the
    /// stream can't be resynchronized, so the caller must close it.
    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var payloads: [Data] = []
        var offset = 0
        while buffer.count - offset >= Self.headerLength {
            let length = Int(buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
            guard length <= limit else {
                throw FramingError.messageTooLarge(length: length, limit: limit)
            }
            let start = offset + Self.headerLength
            guard buffer.count - start >= length else { break }
            payloads.append(buffer.subdata(in: start..<start + length))
            offset = start + length
        }
        // Copy the remainder only when something was consumed, so a large message arriving
        // in many reads is appended to rather than copied on every read.
        if offset > 0 {
            buffer = buffer.subdata(in: offset..<buffer.count)
        }
        return payloads
    }
}
