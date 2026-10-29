import Foundation
import Testing
@testable import WebbyCore

private let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            if crc & 1 != 0 {
                crc = (crc >> 1) ^ 0xEDB8_8320
            } else {
                crc >>= 1
            }
        }
    }
    return crc ^ 0xFFFF_FFFF
}

private func makePNGHeader(
    width: UInt32 = 1,
    height: UInt32 = 1,
    bitDepth: UInt8 = 8,
    colorType: UInt8 = 6,
    compression: UInt8 = 0,
    filter: UInt8 = 0,
    interlace: UInt8 = 0,
    chunkType: String = "IHDR",
    length: UInt32 = 13,
    crcOverride: UInt32? = nil
) -> Data {
    var data = Data(pngSignature)

    var payload = Data()
    appendUInt32(width, to: &payload)
    appendUInt32(height, to: &payload)
    payload.append(bitDepth)
    payload.append(colorType)
    payload.append(compression)
    payload.append(filter)
    payload.append(interlace)

    appendUInt32(length, to: &data)
    let typeBytes = Array(chunkType.utf8)
    data.append(contentsOf: typeBytes)
    data.append(payload)

    let crc = crc32(typeBytes + Array(payload))
    appendUInt32(crcOverride ?? crc, to: &data)
    return data
}

private let knownOnePixelPNG = Data(base64Encoded: """
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==
""")!

@Test func parsesKnownPNGHeader() throws {
    let header = try PNGHeader.parse(knownOnePixelPNG)

    #expect(header.width == 1)
    #expect(header.height == 1)
    #expect(header.bitDepth == 8)
    #expect(header.colorType == 6)
    #expect(header.interlace == 0)
    #expect(header.pixelCount == 1)
}

@Test func everyTruncatedBoundaryFailsAsTruncated() {
    for length in 0..<33 {
        let data = Data(knownOnePixelPNG.prefix(length))
        #expect(throws: PNGHeaderError.truncated) {
            try PNGHeader.parse(data)
        }
    }
}

@Test func rejectsBadSignature() {
    var data = makePNGHeader()
    data[0] = 0x00

    #expect(throws: PNGHeaderError.badSignature) {
        try PNGHeader.parse(data)
    }
}

@Test func rejectsBadIHDRLength() {
    let data = makePNGHeader(length: 12)

    #expect(throws: PNGHeaderError.badIHDRLength) {
        try PNGHeader.parse(data)
    }
}

@Test func rejectsBadIHDRChunkType() {
    let data = makePNGHeader(chunkType: "IDAT")

    #expect(throws: PNGHeaderError.badIHDRChunkType) {
        try PNGHeader.parse(data)
    }
}

@Test func rejectsBadCRC() {
    let data = makePNGHeader(crcOverride: 0)

    #expect(throws: PNGHeaderError.badCRC) {
        try PNGHeader.parse(data)
    }
}

@Test func rejectsZeroDimensions() {
    #expect(throws: PNGHeaderError.invalidDimensions) {
        try PNGHeader.parse(makePNGHeader(width: 0, height: 1))
    }
    #expect(throws: PNGHeaderError.invalidDimensions) {
        try PNGHeader.parse(makePNGHeader(width: 1, height: 0))
    }
    #expect(throws: PNGHeaderError.invalidDimensions) {
        try PNGHeader.parse(makePNGHeader(width: 0, height: 0))
    }
}

@Test func acceptsDimensionLimitAndRejectsBeyondIt() throws {
    let maximum = try PNGHeader.parse(makePNGHeader(width: 2048, height: 1))
    #expect(maximum.width == 2048)
    #expect(maximum.height == 1)

    let maximumContained = try PNGHeader.parse(makePNGHeader(width: 2048, height: 2048))
    #expect(maximumContained.width == 2048)
    #expect(maximumContained.height == 2048)

    #expect(throws: PNGHeaderError.oversized) {
        try PNGHeader.parse(makePNGHeader(width: 2049, height: 1))
    }
    #expect(throws: PNGHeaderError.oversized) {
        try PNGHeader.parse(makePNGHeader(width: 1, height: 2049))
    }
}

@Test func acceptsEveryLegalColorTypeAndBitDepthPair() throws {
    let legalPairs: [(UInt8, UInt8)] = [
        (0, 1), (0, 2), (0, 4), (0, 8), (0, 16),
        (2, 8), (2, 16),
        (3, 1), (3, 2), (3, 4), (3, 8),
        (4, 8), (4, 16),
        (6, 8), (6, 16),
    ]

    for (colorType, bitDepth) in legalPairs {
        let header = try PNGHeader.parse(
            makePNGHeader(bitDepth: bitDepth, colorType: colorType)
        )
        #expect(header.colorType == Int(colorType))
        #expect(header.bitDepth == Int(bitDepth))
    }
}

@Test func rejectsIllegalColorTypeAndBitDepthPairs() {
    let illegalPairs: [(UInt8, UInt8)] = [
        (0, 3), (1, 8), (2, 4), (3, 16),
        (4, 1), (5, 8), (6, 2), (7, 8),
    ]

    for (colorType, bitDepth) in illegalPairs {
        #expect(throws: PNGHeaderError.unsupportedColorDepth) {
            try PNGHeader.parse(makePNGHeader(bitDepth: bitDepth, colorType: colorType))
        }
    }
}

@Test func rejectsUnsupportedCompressionFilterAndInterlace() {
    #expect(throws: PNGHeaderError.unsupportedCompression) {
        try PNGHeader.parse(makePNGHeader(compression: 1))
    }
    #expect(throws: PNGHeaderError.unsupportedFilter) {
        try PNGHeader.parse(makePNGHeader(filter: 1))
    }
    #expect(throws: PNGHeaderError.unsupportedInterlace) {
        try PNGHeader.parse(makePNGHeader(interlace: 2))
    }
}

@Test func acceptsInterlacedHeader() throws {
    let header = try PNGHeader.parse(makePNGHeader(interlace: 1))
    #expect(header.interlace == 1)
}

@Test func pixelCountHelperChecksOverflowAndNegativeInput() {
    #expect(PNGHeader.maxPixels == 24_000_000)
    #expect(PNGHeader.pixelCount(width: 4000, height: 6000) == 24_000_000)
    #expect(PNGHeader.pixelCount(width: 0, height: 6000) == 0)
    #expect(PNGHeader.pixelCount(width: -1, height: 6000) == nil)
    #expect(PNGHeader.pixelCount(width: 6000, height: -1) == nil)
    #expect(PNGHeader.pixelCount(width: Int.max, height: 2) == nil)

    let header = PNGHeader(width: 12, height: 34, bitDepth: 8, colorType: 6, interlace: 0)
    #expect(header.pixelCount == 408)
}
