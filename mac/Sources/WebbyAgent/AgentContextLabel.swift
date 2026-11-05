import Foundation
import WebbyCore

/// Builds the only page and app labels that may enter an agent request.
///
/// Web labels are a normalized host plus path. Query strings are never included,
/// even when a query rule made them significant for note identity. File pages
/// become `Local file` without any path. A tab with no durable page becomes
/// `Browser tab without page`. `PageURL.description` is deliberately not used.
public enum AgentContextLabel {
    public static let localFile = "Local file"
    public static let tabWithoutPage = "Browser tab without page"

    /// A web label with the query removed unconditionally.
    public static func page(_ page: PageURL) -> String {
        if page.host == "file" {
            return localFile
        }
        return clean(page.host + page.path)
    }

    /// A label for an app, preferring an explicit display name or workspace title.
    public static func app(bundleID: String, displayName: String? = nil) -> String {
        if let displayName {
            let normalized = clean(displayName).trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                return normalized
            }
        }
        return clean(bundleID)
    }

    /// The label for the page or app the question was asked from.
    public static func label(
        for context: Context,
        workspaces: [WorkspaceRecord] = [],
        appDisplayName: String? = nil
    ) -> String {
        if let page = context.page {
            return self.page(page)
        }
        if context.tab != nil {
            return tabWithoutPage
        }
        let displayName = appDisplayName ?? workspaceDisplayName(
            forAppBundleID: context.appBundleID,
            workspaces: workspaces
        )
        return app(bundleID: context.appBundleID, displayName: displayName)
    }

    /// A stable label for a note's own anchor or durable source.
    public static func label(for note: Note, workspaces: [WorkspaceRecord] = []) -> String {
        if let anchor = note.anchor {
            switch anchor {
            case let .app(bundleID):
                return app(
                    bundleID: bundleID,
                    displayName: workspaceDisplayName(forAppBundleID: bundleID, workspaces: workspaces)
                )
            case let .web(page, _):
                return self.page(page)
            }
        }

        if let sourceURL = note.source?.url,
           let page = PageURL(string: sourceURL, queryRules: []) {
            return self.page(page)
        }

        if note.tab != nil {
            return tabWithoutPage
        }

        return "Inbox"
    }

    /// The host-only label used on the `<notes scope="…">` wrapper.
    public static func scopeLabel(for context: Context) -> String {
        if let page = context.page {
            return page.host == "file" ? localFile : clean(page.host)
        }
        if context.tab != nil {
            return tabWithoutPage
        }
        return clean(context.appBundleID)
    }

    private static func workspaceDisplayName(
        forAppBundleID bundleID: String,
        workspaces: [WorkspaceRecord]
    ) -> String? {
        let key = WorkspaceKey.app(bundleID: bundleID)
        return workspaces
            .filter { $0.keys.contains(key) }
            .sorted { $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased() }
            .compactMap(\.title)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// Removes control characters that could break an attribute or a single line.
    private static func clean(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) {
                result.append(" ")
            } else {
                result.append(String(scalar))
            }
        }
        return result
    }
}
