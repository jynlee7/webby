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
        self.host = Self.normalizeHost(host)
        self.path = Self.normalizePath(path)
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
