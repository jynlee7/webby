/// The current app or page that a note's anchor is compared against.
public enum Context: Hashable, Sendable {
    case app(bundleID: String)
    case web(PageURL)
}

/// How much of a site a web anchor covers.
public enum WebScope: Hashable, Codable, Sendable {
    case page
    case prefix(path: String)
    case site
}

/// The app or web page a note belongs to.
public enum Anchor: Hashable, Codable, Sendable {
    case app(bundleID: String)
    case web(page: PageURL, scope: WebScope)

    public func matches(_ context: Context) -> Bool {
        switch (self, context) {
        case let (.app(bundleID), .app(currentBundleID)):
            return bundleID == currentBundleID

        case let (.web(page, scope), .web(currentPage)):
            guard page.host == currentPage.host else { return false }

            switch scope {
            case .page:
                return page.path == currentPage.path
            case .site:
                return true
            case .prefix(let path):
                let prefix = PageURL(host: page.host, path: path).path
                return prefix.isEmpty
                    || currentPage.path == prefix
                    || currentPage.path.hasPrefix(prefix + "/")
            }

        default:
            return false
        }
    }
}
