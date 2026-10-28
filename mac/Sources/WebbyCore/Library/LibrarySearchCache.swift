import Foundation

/// In-memory, rebuildable search text for the Library.
///
/// Metadata filters always come from the current `Note` values. The cache only
/// holds folded text and tag keys, so a stale entry can never hide a trashed or
/// moved note by itself.
public struct LibrarySearchCache: Sendable {
    public struct Entry: Equatable, Sendable {
        /// The folded first physical line of the note text.
        public let firstLine: String
        /// The folded full note text.
        public let text: String
        /// Folded search keys for tags parsed from the note text.
        public let tagKeys: Set<String>

        public init(firstLine: String, text: String, tagKeys: Set<String>) {
            self.firstLine = firstLine
            self.text = text
            self.tagKeys = tagKeys
        }
    }

    public private(set) var entries: [UUID: Entry]

    public var count: Int { entries.count }

    public init(notes: [Note] = []) {
        entries = [:]
        rebuild(notes: notes)
    }

    public init(_ notes: [Note]) {
        self.init(notes: notes)
    }

    public mutating func rebuild(notes: [Note]) {
        var rebuilt: [UUID: Entry] = [:]
        rebuilt.reserveCapacity(notes.count)
        for note in notes {
            rebuilt[note.id] = Self.makeEntry(for: note)
        }
        entries = rebuilt
    }

    public mutating func rebuild(_ notes: [Note]) {
        rebuild(notes: notes)
    }

    public mutating func update(_ note: Note) {
        entries[note.id] = Self.makeEntry(for: note)
    }

    public mutating func remove(id: UUID) {
        entries.removeValue(forKey: id)
    }

    public func entry(for id: UUID) -> Entry? {
        entries[id]
    }

    public func search(
        _ query: SearchQuery,
        notes: [Note],
        workspaces: [WorkspaceRecord]
    ) -> [UUID] {
        let textClauses = query.clauses.compactMap { clause -> String? in
            guard case .text(let value) = clause else { return nil }
            return SearchRanking.fold(value)
        }
        let siteClauses = query.clauses.compactMap { clause -> String? in
            guard case .site(let value) = clause else { return nil }
            return Self.normalizedHost(value)
        }
        let appClauses = query.clauses.compactMap { clause -> String? in
            guard case .app(let value) = clause else { return nil }
            return SearchRanking.fold(value)
        }
        let tagClauses = query.clauses.compactMap { clause -> String? in
            guard case .tag(let value) = clause else { return nil }
            return SearchRanking.fold(value)
        }
        let stateClauses = query.clauses.compactMap { clause -> SearchQuery.State? in
            guard case .state(let state) = clause else { return nil }
            return state
        }
        let scopeClauses = query.clauses.compactMap { clause -> SearchQuery.Scope? in
            guard case .scope(let scope) = clause else { return nil }
            return scope
        }
        let updatedBoundaries = query.clauses.compactMap { clause -> Date? in
            guard case .updatedAfter(let date) = clause else { return nil }
            return date
        }

        let states = Set(stateClauses)
        let onlyTrash = states.contains(.trashed)
        let needsWorkspace = !siteClauses.isEmpty
            || !appClauses.isEmpty
            || states.contains(.inbox)

        struct Candidate {
            let note: Note
            let tier: Int
        }

        var candidates: [Candidate] = []

        for note in notes {
            let isTrash = note.trashedAt != nil
            if onlyTrash {
                guard isTrash else { continue }
            } else {
                guard !isTrash else { continue }
            }

            if states.contains(.pinned), note.pinnedAt == nil { continue }
            if states.contains(.hidden), !note.hidden { continue }
            if states.contains(.tab), note.tab == nil { continue }

            if !scopeClauses.isEmpty {
                guard let anchor = note.anchor,
                      case .web(_, let noteScope) = anchor
                else { continue }

                let scopeMatches = scopeClauses.allSatisfy { clause in
                    switch (clause, noteScope) {
                    case (.page, .page), (.site, .site):
                        return true
                    case (.prefix, .prefix):
                        return true
                    default:
                        return false
                    }
                }
                guard scopeMatches else { continue }
            }

            if !updatedBoundaries.isEmpty {
                guard updatedBoundaries.allSatisfy({ note.updatedAt > $0 }) else {
                    continue
                }
            }

            if needsWorkspace {
                let destination = WorkspaceResolver.resolve(note, workspaces: workspaces)

                if states.contains(.inbox), destination != .inbox {
                    continue
                }

                if !siteClauses.isEmpty || !appClauses.isEmpty {
                    let keys = Self.keys(for: destination, workspaces: workspaces)

                    if !siteClauses.allSatisfy({ site in
                        keys.contains { key in
                            guard case .host(let name) = key else { return false }
                            return Self.normalizedHost(name) == site
                        }
                    }) {
                        continue
                    }

                    if !appClauses.allSatisfy({ app in
                        keys.contains { key in
                            guard case .app(let bundleID) = key else { return false }
                            return SearchRanking.fold(bundleID) == app
                        }
                    }) {
                        continue
                    }
                }
            }

            guard let entry = entries[note.id] else { continue }

            guard textClauses.allSatisfy({ entry.text.contains($0) }) else {
                continue
            }

            guard tagClauses.allSatisfy({ entry.tagKeys.contains($0) }) else {
                continue
            }

            let tier = SearchRanking.tier(
                foldedTextClauses: textClauses,
                foldedFirstLine: entry.firstLine,
                foldedFullText: entry.text
            )
            candidates.append(Candidate(note: note, tier: tier))
        }

        candidates.sort { lhs, rhs in
            SearchRanking.isOrderedBefore(
                tier: lhs.tier,
                updatedAt: lhs.note.updatedAt,
                id: lhs.note.id,
                tier: rhs.tier,
                updatedAt: rhs.note.updatedAt,
                id: rhs.note.id
            )
        }

        return candidates.map(\.note.id)
    }

    private static func makeEntry(for note: Note) -> Entry {
        let tagKeys = Set(Tags.parse(note.text).map(\.searchKey))
        return Entry(
            firstLine: SearchRanking.fold(SearchRanking.firstLine(of: note.text)),
            text: SearchRanking.fold(note.text),
            tagKeys: tagKeys
        )
    }

    private static func normalizedHost(_ rawHost: String) -> String {
        QueryRules.normalizedHost(rawHost)
    }

    private static func keys(
        for destination: WorkspaceDestination,
        workspaces: [WorkspaceRecord]
    ) -> [WorkspaceKey] {
        switch destination {
        case .inbox:
            return []
        case .implicit(let key):
            return [key]
        case .record(let id):
            return workspaces.first(where: { $0.id == id })?.keys ?? []
        }
    }
}
