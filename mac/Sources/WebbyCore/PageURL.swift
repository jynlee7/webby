import Foundation

/// A web page identity used to anchor notes: host + path, with everything that
/// doesn't change "which page this is" stripped away.
///
/// Normalization: scheme dropped (http and https are the same page), host lowercased,
/// leading `www.` removed, default ports dropped, query and fragment dropped,
/// duplicate and trailing slashes removed. The root page has an empty path.
public struct PageURL: Hashable, Codable, Sendable, CustomStringConvertible {
    public let host: String
    /// Always either empty (site root) or starting with "/" and never ending with "/".
    public let path: String

    public init?(string: String) {
        guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased() else { return nil }

        switch scheme {
        case "http", "https":
            guard var host = components.host?.lowercased(), !host.isEmpty else { return nil }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            if let port = components.port, !(scheme == "http" && port == 80), !(scheme == "https" && port == 443) {
                host += ":\(port)"
            }
            self.init(host: host, path: components.percentEncodedPath)
        case "file":
            self.init(host: "file", path: components.percentEncodedPath)
        default:
            return nil
        }
    }

    public init(host: String, path: String) {
        self.host = host
        self.path = PageURL.segments(of: path).map { "/" + $0 }.joined()
    }

    public var segments: [String] { PageURL.segments(of: path) }

    /// Ancestor paths from the site root down to (and including) this page, e.g. for
    /// `/problems/two-sum/description`: ["", "/problems", "/problems/two-sum", "/problems/two-sum/description"].
    /// Used to offer "this path and below" choices for a note's scope.
    public var ancestorPaths: [String] {
        let parts = segments
        return (0...parts.count).map { n in parts.prefix(n).map { "/" + $0 }.joined() }
    }

    public var description: String { host + path }

    private static func segments(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
