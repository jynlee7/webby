import Foundation

/// One heading-level group inside a compiled document.
public enum CompiledSectionKind: String, Equatable, Hashable, Sendable {
    case workspaceNotes
    case tabNotes
    case appNotes
    case siteWide
    case path
    case exactPage
}

/// A generated link. Only the renderers create these.
public struct CompiledLink: Equatable, Sendable {
    public let title: String
    public let url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

/// An immutable note value with the note-controlled text kept separate from the
/// renderer-owned links and metadata.
public struct CompiledNote: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let body: String
    public let createdAt: Date
    public let isPinned: Bool
    public let isHidden: Bool
    public let isCollapsed: Bool
    public let isExcludedFromAgent: Bool
    public let tags: [String]
    public let noteLink: CompiledLink
    public let pageLink: CompiledLink?

    public init(
        id: UUID,
        title: String,
        body: String,
        createdAt: Date,
        isPinned: Bool,
        isHidden: Bool,
        isCollapsed: Bool,
        isExcludedFromAgent: Bool,
        tags: [String],
        noteLink: CompiledLink,
        pageLink: CompiledLink?
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.isHidden = isHidden
        self.isCollapsed = isCollapsed
        self.isExcludedFromAgent = isExcludedFromAgent
        self.tags = tags
        self.noteLink = noteLink
        self.pageLink = pageLink
    }
}

public struct CompiledSection: Equatable, Sendable {
    public let kind: CompiledSectionKind
    public let heading: String
    public let path: String?
    public let page: PageURL?
    public let notes: [CompiledNote]

    public init(
        kind: CompiledSectionKind,
        heading: String,
        path: String? = nil,
        page: PageURL? = nil,
        notes: [CompiledNote]
    ) {
        self.kind = kind
        self.heading = heading
        self.path = path
        self.page = page
        self.notes = notes
    }
}

/// A deterministic, immutable view of a workspace or a page in a workspace.
///
/// Building never reads or writes files. Output ordering is defined by this
/// type, not by the Library's existing page-tree or search ordering.
public struct CompiledDocument: Equatable, Sendable {
    public enum Scope: Equatable, Sendable {
        case workspace(WorkspaceDestination)
        case page(WorkspaceDestination, PageURL)
    }

    public let scope: Scope
    public let title: String
    public let sections: [CompiledSection]

    public init(scope: Scope, title: String, sections: [CompiledSection]) {
        self.scope = scope
        self.title = title
        self.sections = sections
    }

    /// A workspace document ordered from general to specific.
    public static func workspace(
        destination: WorkspaceDestination,
        notes: [Note],
        workspaces: [WorkspaceRecord],
        queryRules: [QueryRule] = QueryRules.builtIns
    ) -> CompiledDocument {
        let eligible = eligibleNotes(notes, destination: destination, workspaces: workspaces)
        let rules = QueryRules.effective(
            rules: queryRules,
            anchors: eligible.compactMap(\.anchor)
        )
        let sections = workspaceSections(eligible, queryRules: rules)
        return CompiledDocument(
            scope: .workspace(destination),
            title: displayName(for: destination, workspaces: workspaces),
            sections: sections
        )
    }

    /// A page document ordered from specific to general: the exact page, then
    /// matching prefixes deepest first, then site-wide notes.
    public static func page(
        _ page: PageURL,
        destination: WorkspaceDestination,
        notes: [Note],
        workspaces: [WorkspaceRecord],
        queryRules: [QueryRule] = QueryRules.builtIns
    ) -> CompiledDocument {
        let eligible = eligibleNotes(notes, destination: destination, workspaces: workspaces)
        let anchors = eligible.compactMap(\.anchor) + [.web(page: page, scope: .page)]
        let rules = QueryRules.effective(rules: queryRules, anchors: anchors)
        let sections = pageSections(
            page,
            notes: eligible,
            queryRules: rules
        )
        return CompiledDocument(
            scope: .page(destination, page),
            title: page.description,
            sections: sections
        )
    }
}

// MARK: - Eligibility and membership

private extension CompiledDocument {
    static func eligibleNotes(
        _ notes: [Note],
        destination: WorkspaceDestination,
        workspaces: [WorkspaceRecord]
    ) -> [Note] {
        notes.filter { note in
            LibraryEligibility.isOrdinary(note)
                && !note.ephemeral
                && WorkspaceResolver.resolve(note, workspaces: workspaces) == destination
        }
    }

    static func displayName(
        for destination: WorkspaceDestination,
        workspaces: [WorkspaceRecord]
    ) -> String {
        switch destination {
        case .inbox:
            return "Inbox"

        case let .implicit(key):
            return key.displayName

        case let .record(id):
            guard let record = workspaces.first(where: { $0.id == id }) else {
                return "Workspace"
            }
            if let title = record.title {
                let normalized = title.precomposedStringWithCanonicalMapping
                if !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return normalized
                }
            }
            let keyNames = Array(Set(record.keys.map(\.displayName))).sorted()
            if !keyNames.isEmpty {
                return keyNames.joined(separator: " · ")
            }
            return "Workspace"
        }
    }
}

// MARK: - Workspace sections

private extension CompiledDocument {
    static func workspaceSections(
        _ notes: [Note],
        queryRules: [QueryRule]
    ) -> [CompiledSection] {
        var sections: [CompiledSection] = []

        let tabNotes = notes.filter { $0.tab != nil }
        let pageable = notes.filter { $0.tab == nil }
        let workspaceNotes = pageable.filter { $0.anchor == nil }
        let appNotes = pageable.filter { note in
            guard let anchor = note.anchor else { return false }
            guard case .app = anchor else { return false }
            return true
        }
        let webNotes = pageable.filter { note in
            guard let anchor = note.anchor else { return false }
            guard case .web = anchor else { return false }
            return true
        }

        appendSection(
            kind: .workspaceNotes,
            heading: "Not attached to a page",
            notes: workspaceNotes,
            queryRules: queryRules,
            to: &sections
        )
        appendSection(
            kind: .tabNotes,
            heading: "Just this tab",
            notes: tabNotes,
            queryRules: queryRules,
            to: &sections
        )
        appendSection(
            kind: .appNotes,
            heading: "App",
            notes: appNotes,
            queryRules: queryRules,
            to: &sections
        )

        var notesByHost: [String: [Note]] = [:]
        for note in webNotes {
            guard let anchor = note.anchor,
                  case let .web(page, _) = anchor
            else { continue }
            notesByHost[page.host, default: []].append(note)
        }

        let includeHostInHeadings = notesByHost.keys.count > 1
        for host in notesByHost.keys.sorted() {
            let hostNotes = notesByHost[host] ?? []
            let siteWide = hostNotes.filter { note in
                guard let anchor = note.anchor,
                      case let .web(_, scope) = anchor
                else { return false }
                if case .site = scope { return true }
                return false
            }
            appendSection(
                kind: .siteWide,
                heading: includeHostInHeadings ? "\(host) · Whole site" : "Whole site",
                notes: siteWide,
                queryRules: queryRules,
                to: &sections
            )

            var prefixNotes: [String: [Note]] = [:]
            var exactNotes: [PageURL: [Note]] = [:]

            for note in hostNotes {
                guard let anchor = note.anchor,
                      case let .web(page, scope) = anchor
                else { continue }
                switch scope {
                case .site:
                    continue
                case let .prefix(rawPath):
                    let path = PageURL(host: page.host, path: rawPath).path
                    prefixNotes[path, default: []].append(note)
                case .page:
                    exactNotes[page, default: []].append(note)
                }
            }

            var paths = Set(prefixNotes.keys)
            for page in exactNotes.keys {
                paths.insert(page.path)
            }

            for path in paths.sorted(by: pathLess) {
                if let notes = prefixNotes[path] {
                    appendSection(
                        kind: .path,
                        heading: pathHeading(
                            path,
                            host: host,
                            includeHost: includeHostInHeadings
                        ),
                        path: path,
                        notes: notes,
                        queryRules: queryRules,
                        to: &sections
                    )
                }

                let pages = exactNotes.keys
                    .filter { $0.path == path }
                    .sorted(by: pageLess)
                for page in pages {
                    appendSection(
                        kind: .exactPage,
                        heading: exactHeading(page, includeHost: includeHostInHeadings),
                        path: path,
                        page: page,
                        notes: exactNotes[page] ?? [],
                        queryRules: queryRules,
                        to: &sections
                    )
                }
            }
        }

        return sections
    }

    static func appendSection(
        kind: CompiledSectionKind,
        heading: String,
        path: String? = nil,
        page: PageURL? = nil,
        notes: [Note],
        queryRules: [QueryRule],
        to sections: inout [CompiledSection]
    ) {
        guard !notes.isEmpty else { return }
        sections.append(
            CompiledSection(
                kind: kind,
                heading: heading,
                path: path,
                page: page,
                notes: compiledNotes(notes, queryRules: queryRules)
            )
        )
    }
}

// MARK: - Page sections

private extension CompiledDocument {
    static func pageSections(
        _ page: PageURL,
        notes: [Note],
        queryRules: [QueryRule]
    ) -> [CompiledSection] {
        var sections: [CompiledSection] = []
        var exactNotes: [Note] = []
        var prefixNotes: [String: [Note]] = [:]
        var siteWide: [Note] = []

        for note in notes {
            guard note.tab == nil,
                  let anchor = note.anchor,
                  case let .web(anchorPage, scope) = anchor,
                  anchorPage.host == page.host
            else { continue }

            switch scope {
            case .site:
                siteWide.append(note)
            case let .prefix(rawPath):
                let path = PageURL(host: anchorPage.host, path: rawPath).path
                guard pageMatchesPrefix(page.path, prefix: path) else { continue }
                prefixNotes[path, default: []].append(note)
            case .page:
                guard page.matchesPageAnchor(anchorPage) else { continue }
                exactNotes.append(note)
            }
        }

        if !exactNotes.isEmpty {
            sections.append(
                CompiledSection(
                    kind: .exactPage,
                    heading: "This page",
                    path: page.path,
                    page: page,
                    notes: compiledNotes(exactNotes, queryRules: queryRules)
                )
            )
        }

        for path in prefixNotes.keys.sorted(by: pathLess).reversed() {
            let notes = prefixNotes[path] ?? []
            guard !notes.isEmpty else { continue }
            sections.append(
                CompiledSection(
                    kind: .path,
                    heading: pathHeading(path),
                    path: path,
                    notes: compiledNotes(notes, queryRules: queryRules)
                )
            )
        }

        if !siteWide.isEmpty {
            sections.append(
                CompiledSection(
                    kind: .siteWide,
                    heading: "Whole site",
                    notes: compiledNotes(siteWide, queryRules: queryRules)
                )
            )
        }

        return sections
    }

    static func pageMatchesPrefix(_ pagePath: String, prefix: String) -> Bool {
        prefix.isEmpty || pagePath == prefix || pagePath.hasPrefix(prefix + "/")
    }
}

// MARK: - Compiled note values

extension CompiledDocument {
    public static func compiledNotes(_ notes: [Note], queryRules: [QueryRule]) -> [CompiledNote] {
        CompiledNoteOrdering.sorted(notes).map { note in
            let (title, body) = CompiledFormatting.titleAndBody(from: note.text)
            return CompiledNote(
                id: note.id,
                title: title,
                body: body,
                createdAt: note.createdAt,
                isPinned: note.pinnedAt != nil,
                isHidden: note.hidden,
                isCollapsed: note.collapsed,
                isExcludedFromAgent: note.excludedFromAgent,
                tags: Tags.parse(note.text).map(\.name),
                noteLink: CompiledLink(title: "Open note", url: NoteLink.url(for: note.id)),
                pageLink: pageLink(for: note, queryRules: queryRules)
            )
        }
    }

    private static func pageLink(for note: Note, queryRules: [QueryRule]) -> CompiledLink? {
        guard let anchor = note.anchor,
              case let .web(page, _) = anchor,
              let url = CanonicalExportURL.make(for: page, queryRules: queryRules)
        else { return nil }
        return CompiledLink(title: "Open page", url: url)
    }
}

// MARK: - Deterministic ordering

enum CompiledNoteOrdering {
    static func sorted(_ notes: [Note]) -> [Note] {
        notes.sorted { lhs, rhs in
            let lhsPinned = lhs.pinnedAt != nil
            let rhsPinned = rhs.pinnedAt != nil
            if lhsPinned != rhsPinned {
                return lhsPinned
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
    }
}

private func pathLess(_ lhs: String, _ rhs: String) -> Bool {
    let lhsSegments = lhs.split(separator: "/", omittingEmptySubsequences: true)
    let rhsSegments = rhs.split(separator: "/", omittingEmptySubsequences: true)

    for (lhsSegment, rhsSegment) in zip(lhsSegments, rhsSegments) {
        if lhsSegment != rhsSegment {
            return lhsSegment < rhsSegment
        }
    }
    return lhsSegments.count < rhsSegments.count
}

private func pageLess(_ lhs: PageURL, _ rhs: PageURL) -> Bool {
    switch (lhs.query, rhs.query) {
    case (nil, nil):
        break
    case (nil, .some):
        return true
    case (.some, nil):
        return false
    case let (lhsQuery?, rhsQuery?):
        if lhsQuery != rhsQuery {
            return lhsQuery < rhsQuery
        }
    }
    return lhs.description < rhs.description
}

private func pathHeading(
    _ path: String,
    host: String? = nil,
    includeHost: Bool = false
) -> String {
    let display = path.isEmpty ? "/" : path
    let qualified = includeHost ? "\(host ?? "")\(display)" : display
    return "\(qualified) (and below)"
}

private func exactHeading(_ page: PageURL, includeHost: Bool = false) -> String {
    let displayPath = page.path.isEmpty ? "/" : page.path
    let display = includeHost ? "\(page.host)\(displayPath)" : displayPath
    if let query = page.query {
        return "\(display)?\(query) (this page)"
    }
    return "\(display) (this page)"
}

// MARK: - Shared formatting

enum CompiledFormatting {
    static func utcDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static func titleAndBody(from text: String) -> (title: String, body: String) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        guard let titleIndex = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else {
            return ("Untitled", "")
        }

        let title = lines[titleIndex].trimmingCharacters(in: .whitespaces)
        var bodyLines = Array(lines[(titleIndex + 1)...])

        while let first = bodyLines.first,
              first.trimmingCharacters(in: .whitespaces).isEmpty {
            bodyLines.removeFirst()
        }
        while let last = bodyLines.last,
              last.trimmingCharacters(in: .whitespaces).isEmpty {
            bodyLines.removeLast()
        }

        return (title, bodyLines.joined(separator: "\n"))
    }
}
