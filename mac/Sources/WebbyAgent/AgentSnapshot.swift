import Foundation
import WebbyCore

/// The note scope fixed when a conversation starts.
///
/// `currentPage` is the page or app the conversation was opened from,
/// `workspace` is that page or app's workspace, and `allNotes` is the only scope
/// that includes notes whose workspace is Inbox.
public enum AgentScope: String, Hashable, CaseIterable, Sendable {
    case page
    case workspace
    case allNotes

    /// Alias used by callers that prefer the longer description.
    public static let currentPage = AgentScope.page
    /// Alias used by callers that prefer the shorter description.
    public static let all = AgentScope.allNotes

    public var includesInbox: Bool {
        self == .allNotes
    }
}

/// An immutable copy of the notes, workspaces and query rules used by the agent.
///
/// Trashed, AI-excluded and ephemeral notes are removed when the snapshot is
/// created, before any aliases or manifests are built. Inbox notes remain in the
/// copy, but `notes(for:context:)` includes them only for the explicit
/// `allNotes` scope.
public struct AgentSnapshot: Equatable, Sendable {
    /// Eligible notes, already stripped of trash, AI exclusions and ephemeral notes.
    public let notes: [Note]
    public let workspaces: [WorkspaceRecord]
    /// The rules supplied by the store, before anchor-derived rules are added.
    public let configuredQueryRules: [QueryRule]
    /// The complete effective rule list, sorted by host then key.
    public let effectiveQueryRules: [QueryRule]

    public var eligibleNotes: [Note] {
        notes
    }

    /// Effective query rules. Named for the value the agent consumes.
    public var queryRules: [QueryRule] {
        effectiveQueryRules
    }

    public init(
        notes: [Note],
        workspaces: [WorkspaceRecord] = [],
        queryRules: [QueryRule] = []
    ) {
        let eligible = notes.filter {
            $0.trashedAt == nil && !$0.excludedFromAgent && !$0.ephemeral
        }
        self.notes = eligible
        self.workspaces = workspaces
        self.configuredQueryRules = queryRules
        self.effectiveQueryRules = QueryRules.effective(
            rules: queryRules,
            anchors: eligible.compactMap(\.anchor)
        )
    }

    /// The notes authorized for the conversation scope.
    ///
    /// A page or workspace scope stays inside the workspace derived from the
    /// captured context. Only `allNotes` can return Inbox notes.
    public func notes(for scope: AgentScope, context: Context) -> [Note] {
        guard scope != .allNotes else { return notes }
        let destination = workspaceDestination(for: context)
        return notes.filter {
            WorkspaceResolver.resolve($0, workspaces: workspaces) == destination
        }
    }

    /// The explicit or implicit workspace destination for a captured context.
    public func workspaceDestination(for context: Context) -> WorkspaceDestination {
        let key: WorkspaceKey
        if let page = context.page {
            key = page.host == "file" ? .localFiles : .host(name: page.host)
        } else if context.tab != nil {
            key = .tabsWithoutPage
        } else {
            key = .app(bundleID: context.appBundleID)
        }

        var matchingRecordID: UUID?
        for record in workspaces where record.keys.contains(key) {
            if matchingRecordID.map({
                record.id.uuidString.lowercased() < $0.uuidString.lowercased()
            }) ?? true {
                matchingRecordID = record.id
            }
        }
        if let matchingRecordID {
            return .record(matchingRecordID)
        }
        return .implicit(key)
    }

    /// A deterministic summary of the authorization inputs for an active turn.
    ///
    /// The client can compare this value before a continuation and reject a turn
    /// whose scope or authorized notes changed. It contains no note text or URL.
    public func authorizationFingerprint(scope: AgentScope, context: Context) -> String {
        let authorized = notes(for: scope, context: context)
            .map { "\($0.id.uuidString.lowercased()):\($0.revision)" }
            .sorted()
        return ([scope.rawValue] + authorized).joined(separator: "|")
    }
}
