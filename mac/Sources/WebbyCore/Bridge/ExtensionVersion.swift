import Foundation

/// A Chrome extension version: one to four dot-separated integers in `0...65535`, compared
/// numerically with missing components as zero, so `0.9 < 0.10` and `1.0 == 1.0.0`.
/// Anything else (signs, letters, empty components, more than four parts) is rejected
/// rather than guessed at.
public struct ExtensionVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]
    /// The string as written, for display.
    public let description: String

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 5, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part), value <= 65535
            else { return nil }
            components.append(value)
        }
        self.components = components
        self.description = string
    }

    private var padded: [Int] { components + Array(repeating: 0, count: 4 - components.count) }

    public static func == (lhs: ExtensionVersion, rhs: ExtensionVersion) -> Bool {
        lhs.padded == rhs.padded
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(padded)
    }

    public static func < (lhs: ExtensionVersion, rhs: ExtensionVersion) -> Bool {
        lhs.padded.lexicographicallyPrecedes(rhs.padded)
    }
}
