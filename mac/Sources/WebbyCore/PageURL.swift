import Foundation

/// The durable identity of a web page: a normalized host and path.
public struct PageURL: Hashable, Codable, Sendable, CustomStringConvertible {
    public let host: String
    public let path: String

    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme)
        else { return nil }

        if scheme == "file" {
            host = "file"
            path = Self.normalizePath(components.percentEncodedPath)
            return
        }

        guard let rawHost = components.host, !rawHost.isEmpty else { return nil }
        var normalizedHost = Self.normalizeHost(rawHost)
        guard !normalizedHost.isEmpty else { return nil }

        if let port = components.port, port != Self.defaultPort(for: scheme) {
            normalizedHost += ":\(port)"
        }

        host = normalizedHost
        path = Self.normalizePath(components.percentEncodedPath)
    }

    public init(host: String, path: String) {
        let normalizedHost = Self.normalizeHost(host)
        precondition(!normalizedHost.isEmpty, "PageURL host must not be empty")
        self.host = normalizedHost
        self.path = Self.normalizePath(path)
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case path
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawHost = try container.decode(String.self, forKey: .host)
        let normalizedHost = Self.normalizeHost(rawHost)
        guard !normalizedHost.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .host,
                in: container,
                debugDescription: "PageURL host must not be empty"
            )
        }
        host = normalizedHost
        path = Self.normalizePath(try container.decode(String.self, forKey: .path))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(path, forKey: .path)
    }

    public var segments: [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    public var description: String {
        host + path
    }

    private static func normalizeHost(_ rawHost: String) -> String {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
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
