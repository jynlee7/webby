import Foundation

/// The model behind Settings, "Pages that differ by query". It is pure: operations
/// return new values and the caller persists them.
///
/// A key that a non-trashed page-scoped note still uses stays significant even when
/// it has no rule, so removing a rule never leaves a note unmatchable. The pane shows
/// such a key as still used and offers to convert those notes instead.
public struct QueryRulesPane: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public let host: String
        public let key: String
        public let isBuiltIn: Bool
        /// True when a rule (built-in or user) is in force; false when only notes keep the key in effect.
        public let isEnabled: Bool
        /// Non-trashed notes with a page-scoped anchor on this host whose query has this key.
        public let usageCount: Int

        public var id: String { host + "\u{0}" + key }

        /// "Still used by N notes" while only notes keep the key in effect.
        public var status: String? {
            guard !isEnabled, usageCount > 0 else { return nil }
            return "Still used by \(usageCount) \(usageCount == 1 ? "note" : "notes")"
        }
    }

    public struct AnchorRewrite: Equatable, Sendable {
        public let noteID: UUID
        public let anchor: Anchor

        public init(noteID: UUID, anchor: Anchor) {
            self.noteID = noteID
            self.anchor = anchor
        }
    }

    /// The notes a conversion would change and the text to confirm it with.
    public struct ConvertPlan: Equatable, Sendable {
        public let host: String
        public let key: String
        public let rewrites: [AnchorRewrite]

        public var confirmationTitle: String {
            "Convert \(rewrites.count) \(rewrites.count == 1 ? "note" : "notes")?"
        }

        public var confirmationMessage: String {
            "\(rewrites.count == 1 ? "This note" : "These notes") will match \(host) pages without “\(key)” in the address. "
                + "Notes from pages with different “\(key)” values will then share one page. "
                + "This changes the notes and can’t be undone from Settings."
        }
    }

    public enum RuleError: Error, LocalizedError, Equatable {
        case emptyHost
        case invalidHost
        case emptyKey
        case invalidKey
        case duplicate

        public var errorDescription: String? {
            switch self {
            case .emptyHost: return "Enter a website, such as youtube.com."
            case .invalidHost: return "Enter just the website name, such as youtube.com, without https:// or a path."
            case .emptyKey: return "Enter the query parameter, such as v."
            case .invalidKey: return "A query parameter can't contain spaces, “&”, “=” or “#”."
            case .duplicate: return "That rule already exists."
            }
        }
    }

    public let rows: [Row]
    private let usage: [QueryRuleIdentity: [UUID]]
    private let notesByID: [UUID: Note]

    public init(settings: Settings, notes: [Note]) {
        var usage: [QueryRuleIdentity: [UUID]] = [:]
        var byID: [UUID: Note] = [:]
        for note in notes where note.trashedAt == nil && !note.ephemeral {
            guard case let .web(page, .page)? = note.anchor, let query = page.query else { continue }
            byID[note.id] = note
            var seen: Set<String> = []
            for key in QueryRules.keys(in: query) where seen.insert(key).inserted {
                usage[QueryRuleIdentity(QueryRule(host: page.host, key: key)), default: []].append(note.id)
            }
        }

        let enabled = settings.enabledQueryRules
        let enabledIdentities = Set(enabled.map(QueryRuleIdentity.init))
        let builtIns = Set(QueryRules.builtIns.map(QueryRuleIdentity.init))
        var identities = enabled.map(QueryRuleIdentity.init)
        identities += usage.keys.filter { !enabledIdentities.contains($0) }

        self.rows = identities
            .sorted { ($0.host, $0.key) < ($1.host, $1.key) }
            .map { identity in
                Row(
                    host: identity.host,
                    key: identity.key,
                    isBuiltIn: builtIns.contains(identity),
                    isEnabled: enabledIdentities.contains(identity),
                    usageCount: usage[identity]?.count ?? 0
                )
            }
        self.usage = usage
        self.notesByID = byID
    }

    /// Adds a rule. Adding back a removed built-in restores it rather than copying it.
    public static func adding(host: String, key: String, to settings: Settings) throws -> Settings {
        var host = QueryRules.normalizedHost(host)
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw RuleError.emptyHost }
        guard !key.isEmpty else { throw RuleError.emptyKey }
        let forbiddenInHost = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "/?#@\\%"))
        guard host.rangeOfCharacter(from: forbiddenInHost) == nil,
              !host.hasPrefix("."), !host.hasSuffix(".") else { throw RuleError.invalidHost }
        guard key.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "&=#"))) == nil
        else { throw RuleError.invalidKey }

        let identity = QueryRuleIdentity(QueryRule(host: host, key: key))
        guard !settings.enabledQueryRules.contains(where: { QueryRuleIdentity($0) == identity }) else {
            throw RuleError.duplicate
        }
        var updated = settings
        if QueryRules.builtIns.contains(where: { QueryRuleIdentity($0) == identity }) {
            updated.removedBuiltInQueryRules.removeAll { QueryRuleIdentity($0) == identity }
        } else {
            updated.queryRules.append(QueryRule(host: identity.host, key: identity.key))
        }
        return updated
    }

    /// Removes a rule. A built-in is remembered as removed. Notes that still use the
    /// key keep it in effect, so nothing is stranded.
    public static func removing(host: String, key: String, from settings: Settings) -> Settings {
        let identity = QueryRuleIdentity(QueryRule(host: host, key: key))
        var updated = settings
        updated.queryRules.removeAll { QueryRuleIdentity($0) == identity }
        if QueryRules.builtIns.contains(where: { QueryRuleIdentity($0) == identity }),
           !updated.removedBuiltInQueryRules.contains(where: { QueryRuleIdentity($0) == identity }) {
            updated.removedBuiltInQueryRules.append(QueryRule(host: identity.host, key: identity.key))
        }
        return updated
    }

    /// The plan for dropping `key` from every non-trashed page note on `host`, or nil
    /// when no note uses it.
    public func convertPlan(host: String, key: String) -> ConvertPlan? {
        let identity = QueryRuleIdentity(QueryRule(host: host, key: key))
        let rewrites: [AnchorRewrite] = (usage[identity] ?? []).compactMap { id in
            guard let note = notesByID[id], case let .web(page, scope)? = note.anchor,
                  let query = page.query else { return nil }
            let stripped = PageURL(host: page.host, path: page.path, query: QueryRules.removingKey(key, from: query))
            return AnchorRewrite(noteID: id, anchor: .web(page: stripped, scope: scope))
        }
        guard !rewrites.isEmpty else { return nil }
        return ConvertPlan(host: identity.host, key: identity.key, rewrites: rewrites)
    }
}
