/// Scope choices are derived from the current page, never from an incognito URL.
public struct NoteScope: Equatable, Sendable {
    public let title: String
    public let anchor: Anchor

    public static func choices(for context: Context) -> [NoteScope] {
        var choices: [NoteScope] = []
        if let page = context.page {
            choices.append(NoteScope(title: "This page", anchor: .web(page: page, scope: .page)))
            // Include the current path: its descendants often contain the problem's
            // solutions/submissions even when this page has no final path component.
            for count in stride(from: page.segments.count, through: 1, by: -1) {
                let path = "/" + page.segments.prefix(count).joined(separator: "/")
                choices.append(NoteScope(title: path + " and below", anchor: .web(page: page, scope: .prefix(path: path))))
            }
            choices.append(NoteScope(title: "Whole site", anchor: .web(page: page, scope: .site)))
        }
        choices.append(NoteScope(title: "This app", anchor: .app(bundleID: context.appBundleID)))
        return choices
    }

    /// The choice that describes `anchor`, if any. Path and site anchors keep the page
    /// they were created on, so they are compared by what they cover, not by equality.
    public static func index(of anchor: Anchor?, in choices: [NoteScope]) -> Int? {
        guard let anchor else { return nil }
        return choices.firstIndex { $0.covers(anchor) }
    }

    private func covers(_ other: Anchor) -> Bool {
        switch (anchor, other) {
        case let (.app(current), .app(stored)):
            return current == stored
        case let (.web(current, .page), .web(stored, .page)):
            return current.matchesPageAnchor(stored)
        case let (.web(current, .site), .web(stored, .site)):
            return current.host == stored.host
        case let (.web(current, .prefix(path)), .web(stored, .prefix(storedPath))):
            return current.host == stored.host
                && PageURL(host: current.host, path: path).path == PageURL(host: stored.host, path: storedPath).path
        default:
            return false
        }
    }
}
