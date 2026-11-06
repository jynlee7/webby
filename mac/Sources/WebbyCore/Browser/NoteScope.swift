/// Scope choices are derived from the current page, never from an incognito URL.
public struct NoteScope: Equatable, Sendable {
    /// Where a note sticks: an anchor, or the reporting Chrome tab with no anchor.
    public enum Choice: Equatable, Sendable {
        case anchor(Anchor)
        case thisTab
    }

    public static let thisTabTitle = "Just this tab"

    public let title: String
    public let choice: Choice

    public init(title: String, anchor: Anchor) {
        self.title = title
        self.choice = .anchor(anchor)
    }

    public init(title: String, choice: Choice) {
        self.title = title
        self.choice = choice
    }

    /// The anchor this choice applies, or nil for "Just this tab".
    public var anchor: Anchor? {
        if case .anchor(let anchor) = choice { return anchor }
        return nil
    }

    /// Page scopes, then "Just this tab" while a live, non-incognito tab reports the
    /// context, then the app. A tab without a page identity starts on "Just this tab".
    public static func choices(for context: Context) -> [NoteScope] {
        var choices = anchorChoices(for: context)
        if context.tab != nil {
            choices.insert(NoteScope(title: thisTabTitle, choice: .thisTab), at: choices.count - 1)
        }
        return choices
    }

    /// The choice a note uses in `context`: "Just this tab" while it is bound to a tab,
    /// otherwise the choice its anchor matches.
    public static func index(of note: Note, in choices: [NoteScope]) -> Int? {
        if note.tab != nil { return choices.firstIndex { $0.choice == .thisTab } }
        return index(of: note.anchor, in: choices)
    }

    /// The anchors a page or tab URL can be promoted to: This page, each parent path and
    /// Whole site. Empty when the URL has no page identity, such as chrome://newtab.
    public static func promotions(forURL url: String, queryRules: [QueryRule]) -> [NoteScope] {
        guard let page = PageURL(string: url, queryRules: queryRules) else { return [] }
        return anchorChoices(for: Context(appBundleID: BrowserSession.bundleID, page: page)).filter {
            if case .anchor(.web) = $0.choice { return true }
            return false
        }
    }

    private static func anchorChoices(for context: Context) -> [NoteScope] {
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
        guard let anchor else { return false }
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
