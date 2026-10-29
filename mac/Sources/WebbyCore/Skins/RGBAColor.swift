import Foundation

/// A validated color in encoded sRGB with straight alpha.
///
/// Every component is finite and lies in `0...1`. Parsing accepts only
/// `#RRGGBB` (opaque) and `#RRGGBBAA`, case-insensitively.
public struct RGBAColor: Sendable, Hashable {
    public let r: Double
    public let g: Double
    public let b: Double
    public let a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) throws {
        guard r.isFinite, g.isFinite, b.isFinite, a.isFinite else {
            throw RGBAColorError.nonFiniteComponent
        }
        guard (0...1).contains(r), (0...1).contains(g), (0...1).contains(b), (0...1).contains(a) else {
            throw RGBAColorError.componentOutOfRange
        }
        self.init(validatedR: r, g: g, b: b, a: a)
    }

    /// Parses `#RRGGBB` or `#RRGGBBAA`. Shorthand and bare hex are rejected.
    public init(hex: String) throws {
        let bytes = Array(hex.utf8)
        guard bytes.count == 7 || bytes.count == 9, bytes.first == UInt8(ascii: "#") else {
            throw RGBAColorError.invalidHexFormat
        }

        var components: [Double] = []
        components.reserveCapacity(4)
        var index = 1
        while index < bytes.count {
            guard let high = Self.hexValue(bytes[index]) else {
                throw RGBAColorError.invalidHexDigit(Self.hexDigit(at: index, in: bytes))
            }
            guard let low = Self.hexValue(bytes[index + 1]) else {
                throw RGBAColorError.invalidHexDigit(Self.hexDigit(at: index + 1, in: bytes))
            }
            components.append(Double(high << 4 | low) / 255)
            index += 2
        }

        self.init(
            validatedR: components[0],
            g: components[1],
            b: components[2],
            a: components.count == 4 ? components[3] : 1
        )
    }

    public static let clear = RGBAColor(validatedR: 0, g: 0, b: 0, a: 0)
    public static let black = RGBAColor(validatedR: 0, g: 0, b: 0, a: 1)
    public static let white = RGBAColor(validatedR: 1, g: 1, b: 1, a: 1)

    /// Composites this color over `background` with source-over in encoded sRGB.
    ///
    /// The result keeps straight alpha. Transparent over transparent is the
    /// canonical `(0, 0, 0, 0)`.
    public func composited(over background: RGBAColor) -> RGBAColor {
        let outAlpha = a + background.a * (1 - a)
        guard outAlpha > 0 else {
            return .clear
        }

        let outRed = (r * a + background.r * background.a * (1 - a)) / outAlpha
        let outGreen = (g * a + background.g * background.a * (1 - a)) / outAlpha
        let outBlue = (b * a + background.b * background.a * (1 - a)) / outAlpha

        return RGBAColor(
            validatedR: Self.clampUnit(outRed),
            g: Self.clampUnit(outGreen),
            b: Self.clampUnit(outBlue),
            a: Self.clampUnit(outAlpha)
        )
    }

    func replacingAlpha(_ alpha: Double) -> RGBAColor {
        RGBAColor(validatedR: r, g: g, b: b, a: Self.clampUnit(alpha))
    }

    private init(validatedR r: Double, g: Double, b: Double, a: Double) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    private static func clampUnit(_ value: Double) -> Double {
        if value <= 0 { return 0 }
        if value >= 1 { return 1 }
        return value
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return byte - UInt8(ascii: "A") + 10
        default:
            return nil
        }
    }

    private static func hexDigit(at index: Int, in bytes: [UInt8]) -> Character {
        let scalar = UnicodeScalar(bytes[index])
        return Character(scalar)
    }
}

public enum RGBAColorError: Error, Equatable, Sendable {
    case invalidHexFormat
    case invalidHexDigit(Character)
    case nonFiniteComponent
    case componentOutOfRange
}
