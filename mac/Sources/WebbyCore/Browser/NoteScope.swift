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
}
