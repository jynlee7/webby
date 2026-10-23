import Foundation

/// What is on screen right now, as far as note visibility is concerned.
public enum Context: Hashable, Sendable {
    /// A regular app (or a browser whose current page we don't know).
    case app(bundleID: String)
    /// A browser showing a known page.
    case web(PageURL)
}

/// How widely a web note applies.
public enum WebScope: Hashable, Codable, Sendable {
    /// Only this exact page.
    case page
    /// Any page on the same host whose path is at or below `pathPrefix`.
    case prefix(path: String)
    /// Every page on the same host.
    case site
}

/// What a note is attached to.
public enum Anchor: Hashable, Codable, Sendable {
    case app(bundleID: String)
    case web(page: PageURL, scope: WebScope)

    public func matches(_ context: Context) -> Bool {
        switch (self, context) {
        case let (.app(mine), .app(current)):
            return mine == current
        case let (.web(page, scope), .web(current)):
            guard page.host == current.host else { return false }
            switch scope {
            case .page:
                return page.path == current.path
            case .prefix(let prefix):
                // Compare whole segments so "/problems/two" doesn't match "/problems/two-sum".
                let wanted = PageURL(host: page.host, path: prefix).segments
                return current.segments.starts(with: wanted)
            case .site:
                return true
            }
        default:
            return false
        }
    }
}
