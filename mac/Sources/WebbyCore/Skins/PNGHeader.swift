import Foundation

/// A typed failure from parsing a PNG header.
public enum PNGHeaderError: Error, Equatable, Sendable {
    case truncated
    case badSignature
    case badIHDRLength
    case badIHDRChunkType
    case badCRC
    case invalidDimensions
    case unsupportedColorDepth
    case unsupportedCompression
    case unsupportedFilter
    case unsupportedInterlace
    case oversized

    /// Alias for callers that name the chunk failure `badIHDRChunk`.
    public static var badIHDRChunk: PNGHeaderError {
        .badIHDRChunkType
    }
}

/// The fields read from the PNG IHDR chunk before any image decoding.
public struct PNGHeader: Sendable, Equatable, Hashable {
    public typealias Error = PNGHeaderError

    /// The largest permitted width or height of a single skin image.
    public static let maximumDimension = 2048

    /// The largest permitted decoded pixel count for one skin.
    public static let maxPixels = 24_000_000

    public let width: Int
    public let height: Int
    public let bitDepth: Int
    public let colorType: Int
    public let interlace: Int

    public init(width: Int, height: Int, bitDepth: Int, colorType: Int, interlace: Int) {
        self.width = width
        self.height = height
        self.bitDepth = bitDepth
        self.colorType = colorType
        self.interlace = interlace
    }

    /// The pixel count, or `nil` when the multiplication overflows or a
    /// dimension is negative.
    public static func pixelCount(width: Int, height: Int) -> Int? {
        guard width >= 0, height >= 0 else {
            return nil
        }
        let (result, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? nil : result
    }

    /// The pixel count for this header, with the same overflow behavior.
    public var pixelCount: Int? {
        Self.pixelCount(width: width, height: height)
    }

    public static func parse(_ data: Data) throws -> PNGHeader {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

        guard data.count >= signature.count else {
            throw PNGHeaderError.truncated
        }

        // Only the signature and IHDR chunk are needed. Never copy image payload.
        let bytes = Array(data.prefix(33))
        guard Array(bytes[0..<signature.count]) == signature else {
            throw PNGHeaderError.badSignature
        }

        guard bytes.count >= 16 else {
            throw PNGHeaderError.truncated
        }

        let ihdrLength = uint32(bytes, at: 8)
        guard ihdrLength == 13 else {
            throw PNGHeaderError.badIHDRLength
        }

        guard String(bytes: bytes[12..<16], encoding: .ascii) == "IHDR" else {
            throw PNGHeaderError.badIHDRChunkType
        }

        guard bytes.count >= 33 else {
            throw PNGHeaderError.truncated
        }

        let expectedCRC = uint32(bytes, at: 29)
        let actualCRC = crc32(bytes[12..<29])
        guard expectedCRC == actualCRC else {
            throw PNGHeaderError.badCRC
        }

        let width = Int(uint32(bytes, at: 16))
        let height = Int(uint32(bytes, at: 20))
        let bitDepth = Int(bytes[24])
        let colorType = Int(bytes[25])
        let compression = bytes[26]
        let filter = bytes[27]
        let interlace = Int(bytes[28])

        guard width > 0, height > 0 else {
            throw PNGHeaderError.invalidDimensions
        }
        guard isLegalColorDepthPair(colorType: colorType, bitDepth: bitDepth) else {
            throw PNGHeaderError.unsupportedColorDepth
        }
        guard compression == 0 else {
            throw PNGHeaderError.unsupportedCompression
        }
        guard filter == 0 else {
            throw PNGHeaderError.unsupportedFilter
        }
        guard interlace == 0 || interlace == 1 else {
            throw PNGHeaderError.unsupportedInterlace
        }
        guard width <= maximumDimension, height <= maximumDimension else {
            throw PNGHeaderError.oversized
        }

        return PNGHeader(
            width: width,
            height: height,
            bitDepth: bitDepth,
            colorType: colorType,
            interlace: interlace
        )
    }

    private static func isLegalColorDepthPair(colorType: Int, bitDepth: Int) -> Bool {
        switch colorType {
        case 0:
            return [1, 2, 4, 8, 16].contains(bitDepth)
        case 2:
            return [8, 16].contains(bitDepth)
        case 3:
            return [1, 2, 4, 8].contains(bitDepth)
        case 4, 6:
            return [8, 16].contains(bitDepth)
        default:
            return false
        }
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
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
}
