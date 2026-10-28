/// The current app or page that a note's anchor is compared against.
public struct Context: Hashable, Sendable {
    /// The frontmost app's bundle identifier.
    public var appBundleID: String
    /// The known page in a supported browser, if any.
    public var page: PageURL?
    /// The reporting browser tab, if any.
    public var tab: TabRef?

    public init(appBundleID: String, page: PageURL? = nil, tab: TabRef? = nil) {
        self.appBundleID = appBundleID
        self.page = page
        self.tab = tab
    }
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
        switch self {
        case let .app(bundleID):
            // An app anchor is about the frontmost app. A known browser page does
            // not make the app identity less true, so "This app" notes still match.
            return bundleID == context.appBundleID

        case let .web(page, scope):
            guard let currentPage = context.page, page.host == currentPage.host else {
                return false
            }

            switch scope {
            case .page:
                return currentPage.matchesPageAnchor(page)
            case .site:
                return true
            case .prefix(let path):
                let prefix = PageURL(host: page.host, path: path).path
                return prefix.isEmpty
                    || currentPage.path == prefix
                    || currentPage.path.hasPrefix(prefix + "/")
            }
        }
    }
}
