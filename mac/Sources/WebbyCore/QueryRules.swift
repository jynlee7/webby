import Foundation

/// The query parameters that participate in a page's durable identity.
///
/// A rule applies only to its exact host, including any non-default port. Hosts
/// are compared after trimming, lowercasing and NFC normalization. Keys are
/// case-sensitive and are matched exactly after percent-decoding.
public enum QueryRules {
    public static let builtIns: [QueryRule] = [
        QueryRule(host: "youtube.com", key: "v"),
        QueryRule(host: "news.ycombinator.com", key: "id"),
    ]

    /// The rules currently in force plus every key still used by a page-scoped
    /// web anchor with a query. `rules` is the complete enabled list supplied by
    /// the caller; built-ins are not added here.
    public static func effective(rules: [QueryRule], anchors: [Anchor]) -> [QueryRule] {
        struct Identity: Hashable {
            let host: String
            let key: String
        }

        var identities: Set<Identity> = []
        var result: [QueryRule] = []

        func append(host: String, key: String) {
            let identity = Identity(host: normalizedHost(host), key: key)
            guard identities.insert(identity).inserted else { return }
            result.append(QueryRule(host: identity.host, key: identity.key))
        }

        for rule in rules {
            append(host: rule.host, key: rule.key)
        }

        for anchor in anchors {
            guard case let .web(page, .page) = anchor, let query = page.query else { continue }
            for item in parseQuery(query) {
                if let key = item.decodedKey {
                    append(host: page.host, key: key)
                }
            }
        }

        return result.sorted {
            if $0.host != $1.host { return $0.host < $1.host }
            return $0.key < $1.key
        }
    }

    static func canonicalQuery(for rawQuery: String?, host: String, rules: [QueryRule]) -> String? {
        guard let rawQuery, !rawQuery.isEmpty else { return nil }

        let host = normalizedHost(host)
        let keys = Set(rules.lazy
            .filter { normalizedHost($0.host) == host }
            .map(\.key))
        guard !keys.isEmpty else { return nil }

        let selected = parseQuery(rawQuery).filter { item in
            item.decodedKey.map(keys.contains) == true
        }
        guard !selected.isEmpty else { return nil }

        let sorted = selected.enumerated().sorted {
            if $0.element.encodedKey != $1.element.encodedKey {
                return $0.element.encodedKey < $1.element.encodedKey
            }
            return $0.offset < $1.offset
        }

        return sorted.map { _, item in
            item.encodedKey + (item.encodedValue.map { "=" + $0 } ?? "")
        }.joined(separator: "&")
    }

    static func normalizedHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .precomposedStringWithCanonicalMapping
    }

    static func currentQuery(_ currentQuery: String?, contains requiredQuery: String) -> Bool {
        struct Pair: Hashable {
            let key: String
            let value: String?
        }

        var remaining: [Pair: Int] = [:]
        for item in parseQuery(requiredQuery) {
            remaining[Pair(key: item.encodedKey, value: item.encodedValue), default: 0] += 1
        }
        guard !remaining.isEmpty else { return true }

        guard let currentQuery else { return false }
        for item in parseQuery(currentQuery) {
            let pair = Pair(key: item.encodedKey, value: item.encodedValue)
            guard let count = remaining[pair] else { continue }
            if count == 1 {
                remaining.removeValue(forKey: pair)
            } else {
                remaining[pair] = count - 1
            }
            if remaining.isEmpty { return true }
        }

        return false
    }

    private struct QueryItem {
        let decodedKey: String?
        let encodedKey: String
        let encodedValue: String?
    }

    private static func parseQuery(_ query: String) -> [QueryItem] {
        guard !query.isEmpty else { return [] }

        return query.split(separator: "&", omittingEmptySubsequences: true).map { rawComponent in
            let component = String(rawComponent)
            let rawKey: String
            let rawValue: String?
            if let separator = component.firstIndex(of: "=") {
                rawKey = String(component[..<separator])
                rawValue = String(component[component.index(after: separator)...])
            } else {
                rawKey = component
                rawValue = nil
            }

            let keyBytes = percentDecodedBytes(rawKey)
            let valueBytes = rawValue.map(percentDecodedBytes)
            return QueryItem(
                decodedKey: String(bytes: keyBytes, encoding: .utf8),
                encodedKey: encode(keyBytes),
                encodedValue: valueBytes.map(encode)
            )
        }
    }

    private static func percentDecodedBytes(_ encoded: String) -> [UInt8] {
        let bytes = Array(encoded.utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count)
        var index = 0

        while index < bytes.count {
            if bytes[index] == 0x25, index + 2 < bytes.count,
               let high = hexValue(bytes[index + 1]),
               let low = hexValue(bytes[index + 2]) {
                decoded.append(high << 4 | low)
                index += 3
            } else {
                decoded.append(bytes[index])
                index += 1
            }
        }
        return decoded
    }

    private static func encode(_ bytes: [UInt8]) -> String {
        let hex: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7",
                                "8", "9", "A", "B", "C", "D", "E", "F"]
        var encoded = ""
        encoded.reserveCapacity(bytes.count)

        for byte in bytes {
            if isUnreserved(byte) {
                encoded.append(Character(UnicodeScalar(byte)))
            } else {
                encoded.append("%")
                encoded.append(hex[Int(byte >> 4)])
                encoded.append(hex[Int(byte & 0x0F)])
            }
        }
        return encoded
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
            return true
        default:
            return false
        }
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}
