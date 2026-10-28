import Foundation

/// The durable identity of a web page: a normalized host, path and optional query.
/// URL parsing strips one leading `www.`; stored identities preserve their host on decode.
public struct PageURL: Hashable, Codable, Sendable, CustomStringConvertible {
    public let host: String
    public let path: String
    public let query: String?

    init?(string: String) {
        self.init(string: string, queryRules: QueryRules.builtIns)
    }

    /// Parses a page using the caller's complete effective significant-query rules.
    public init?(string: String, queryRules: [QueryRule]) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme)
        else { return nil }

        if scheme == "file" {
            query = nil
            host = "file"
            path = Self.normalizePath(components.percentEncodedPath)
            return
        }

        guard let rawHost = components.host, !rawHost.isEmpty else { return nil }
        var normalizedHost = Self.normalizeStoredHost(rawHost)
        if normalizedHost.hasPrefix("www.") {
            normalizedHost.removeFirst(4)
        }
        guard !normalizedHost.isEmpty else { return nil }

        if let port = components.port, port != Self.defaultPort(for: scheme) {
            normalizedHost += ":\(port)"
        }

        host = normalizedHost
        path = Self.normalizePath(components.percentEncodedPath)
        query = QueryRules.canonicalQuery(
            for: components.percentEncodedQuery,
            host: normalizedHost,
            rules: queryRules
        )
    }

    /// Creates an identity from an already selected stored host rather than a raw URL host.
    public init(host: String, path: String, query: String? = nil) {
        let normalizedHost = Self.normalizeStoredHost(host)
        precondition(!normalizedHost.isEmpty, "PageURL host must not be empty")
        self.host = normalizedHost
        self.path = Self.normalizePath(path)
        self.query = query
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case path
        case query
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawHost = try container.decode(String.self, forKey: .host)
        let normalizedHost = Self.normalizeStoredHost(rawHost)
        guard !normalizedHost.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .host,
                in: container,
                debugDescription: "PageURL host must not be empty"
            )
        }
        host = normalizedHost
        path = Self.normalizePath(try container.decode(String.self, forKey: .path))
        query = try container.decodeIfPresent(String.self, forKey: .query)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(query, forKey: .query)
    }

    public var segments: [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    public var description: String {
        host + path + (query.map { "?" + $0 } ?? "")
    }

    /// Whether a page-scoped anchor matches this page.
    public func matchesPageAnchor(_ anchor: PageURL) -> Bool {
        guard QueryRules.normalizedHost(host) == QueryRules.normalizedHost(anchor.host),
              path == anchor.path
        else { return false }

        guard let anchorQuery = anchor.query else { return true }
        return QueryRules.currentQuery(query, contains: anchorQuery)
    }

    private static func normalizeStoredHost(_ rawHost: String) -> String {
        QueryRules.normalizedHost(rawHost)
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private static func normalizePath(_ rawPath: String) -> String {
        var normalized = ""
        var previousWasSlash = false

        for character in rawPath {
            if character == "/" {
                if !previousWasSlash {
                    normalized.append(character)
                }
                previousWasSlash = true
            } else {
                normalized.append(character)
                previousWasSlash = false
            }
        }

        if normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        if !normalized.isEmpty && !normalized.hasPrefix("/") {
            normalized.insert("/", at: normalized.startIndex)
        }
        return normalized
    }
}
