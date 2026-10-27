import Foundation
import Testing
@testable import WebbyCore

@Test func framesStartWithANativeByteOrderLength() throws {
    let framed = try NativeMessageFramer.frame(Data("{}".utf8), limit: 1024)

    #expect(framed.count == NativeMessageFramer.headerLength + 2)
    #expect(framed.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } == 2)
    // Every Mac Webby supports is little-endian.
    #expect(Array(framed.prefix(4)) == [2, 0, 0, 0])
    #expect(framed.suffix(2) == Data("{}".utf8))
}

@Test func severalMessagesInOneReadComeOutInOrder() throws {
    let payloads = ["{\"a\":1}", "{}", "{\"b\":\"two\"}"].map { Data($0.utf8) }
    var stream = Data()
    for payload in payloads {
        stream.append(try NativeMessageFramer.frame(payload, limit: 1024))
    }

    var framer = NativeMessageFramer(limit: 1024)
    #expect(try framer.append(stream) == payloads)
    #expect(try framer.append(Data()) == [])
}

@Test func messagesSplitAcrossReadsAreReassembled() throws {
    let first = Data("{\"type\":\"hello\"}".utf8)
    let second = Data("{\"type\":\"active\"}".utf8)
    let stream = try NativeMessageFramer.frame(first, limit: 1024) + NativeMessageFramer.frame(second, limit: 1024)

    var framer = NativeMessageFramer(limit: 1024)
    var received: [Data] = []
    for byte in stream {
        received += try framer.append(Data([byte]))
    }
    #expect(received == [first, second])
}

@Test func oversizedLengthIsRejectedAsSoonAsTheHeaderArrives() throws {
    var length = UInt32(1025)
    let header = withUnsafeBytes(of: &length) { Data($0) }

    var framer = NativeMessageFramer(limit: 1024)
    #expect(try framer.append(header.prefix(3)) == [])
    #expect(throws: NativeMessageFramer.FramingError.messageTooLarge(length: 1025, limit: 1024)) {
        try framer.append(header.suffix(1))
    }
}

@Test func messagesUpToTheLimitAreAccepted() throws {
    let payload = Data(repeating: 0x20, count: 1024)
    var framer = NativeMessageFramer(limit: 1024)
    #expect(try framer.append(NativeMessageFramer.frame(payload, limit: 1024)) == [payload])
}

@Test func messagesToChromeAreCappedAtOneMegabyte() throws {
    let limit = BridgeConstants.maxMessageToChrome
    #expect(limit == 1024 * 1024)
    #expect(try NativeMessageFramer.frame(Data(count: limit), limit: limit).count == limit + 4)
    #expect(throws: NativeMessageFramer.FramingError.messageTooLarge(length: limit + 1, limit: limit)) {
        try NativeMessageFramer.frame(Data(count: limit + 1), limit: limit)
    }
}

@Test func messagesFromChromeMayBeUpTo64MiB() {
    #expect(BridgeConstants.maxMessageFromChrome == 64 * 1024 * 1024)
}
