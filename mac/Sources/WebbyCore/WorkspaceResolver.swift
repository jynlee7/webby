import Foundation

/// Where a note belongs in the workspace sidebar.
public enum WorkspaceDestination: Hashable, Sendable {
    case inbox
    case implicit(WorkspaceKey)
    case record(UUID)
}

/// Computes a note's workspace from its override, anchor or creation URL.
public enum WorkspaceResolver {
    public static func resolve(
        _ note: Note,
        workspaces: [WorkspaceRecord]
    ) -> WorkspaceDestination {
        if let override = note.workspaceOverride,
           let record = workspaces.first(where: { $0.id == override }) {
            return .record(record.id)
        }

        guard let key = derivedKey(for: note) else {
            return .inbox
        }

        if let record = workspaces.first(where: { $0.keys.contains(key) }) {
            return .record(record.id)
        }

        return .implicit(key)
    }

    private static func derivedKey(for note: Note) -> WorkspaceKey? {
        if let anchor = note.anchor {
            switch anchor {
            case .app(let bundleID):
                return .app(bundleID: bundleID)
            case .web(let page, _):
                return workspaceKey(forHost: page.host)
            }
        }

        guard note.tab != nil else {
            return nil
        }

        guard let sourceURL = note.source?.url,
              let page = PageURL(string: sourceURL) else {
            return .tabsWithoutPage
        }

        return workspaceKey(forHost: page.host)
    }

    private static func workspaceKey(forHost host: String) -> WorkspaceKey {
        host == "file" ? .localFiles : .host(name: host)
    }
}
