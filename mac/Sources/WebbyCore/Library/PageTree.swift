import Foundation

/// A deterministic page tree for one workspace destination.
///
/// Notes without a web page anchor come first in `notAttached`. Web notes are
/// grouped by host, then by normalized path. Every note appears exactly once.
public struct PageTree: Equatable, Sendable {
    public let notAttached: [LibraryNote]
    public let hosts: [PageTreeHost]

    public init(notAttached: [LibraryNote], hosts: [PageTreeHost]) {
        self.notAttached = notAttached
        self.hosts = hosts
    }

    public static func build(
        notes: [Note],
        destination: WorkspaceDestination,
        workspaces: [WorkspaceRecord]
    ) -> PageTree {
        var notAttached: [Note] = []
        var hostBuilders: [String: HostBuilder] = [:]

        for note in notes {
            guard LibraryEligibility.isOrdinary(note) else { continue }
            guard WorkspaceResolver.resolve(note, workspaces: workspaces) == destination else {
                continue
            }

            guard note.tab == nil, let anchor = note.anchor else {
                notAttached.append(note)
                continue
            }

            switch anchor {
            case .app:
                notAttached.append(note)

            case let .web(page, scope):
                // The default subscript gives an in-place `inout` access. Copying the
                // builder out and back would trigger dictionary copy-on-write per note.
                switch scope {
                case .site:
                    hostBuilders[page.host, default: HostBuilder(host: page.host)]
                        .siteWide.append(note)

                case let .prefix(scopePath):
                    let path = PageURL(host: page.host, path: scopePath).path
                    hostBuilders[page.host, default: HostBuilder(host: page.host)]
                        .addPrefix(note, at: path)

                case .page:
                    let path = PageURL(host: page.host, path: page.path).path
                    hostBuilders[page.host, default: HostBuilder(host: page.host)]
                        .addExactPage(note, page: page, at: path)
                }
            }
        }

        let hosts = hostBuilders.values
            .sorted { $0.host < $1.host }
            .map { builder in
                var builder = builder
                return PageTreeHost(
                    host: builder.host,
                    siteWide: libraryNotes(NoteOrdering.sorted(builder.siteWide, by: .updatedDescending)),
                    root: builder.buildRoot()
                )
            }

        return PageTree(
            notAttached: libraryNotes(NoteOrdering.sorted(notAttached, by: .createdAscending)),
            hosts: hosts
        )
    }

    fileprivate static func libraryNotes(_ notes: [Note]) -> [LibraryNote] {
        notes.map(LibraryNote.init)
    }

    fileprivate static func exactPageLess(_ lhs: PageTreeExactPage, _ rhs: PageTreeExactPage) -> Bool {
        switch (lhs.page.query, rhs.page.query) {
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
        return lhs.page.description < rhs.page.description
    }
}

/// One host inside a page tree. A merged workspace record can contain several.
public struct PageTreeHost: Equatable, Sendable {
    public let host: String
    public let siteWide: [LibraryNote]
    public let root: PageTreeNode

    public init(host: String, siteWide: [LibraryNote], root: PageTreeNode) {
        self.host = host
        self.siteWide = siteWide
        self.root = root
    }
}

/// A normalized path node. The root node has an empty path and segment.
public struct PageTreeNode: Equatable, Sendable {
    public let path: String
    public let segment: String
    public let prefixNotes: [LibraryNote]
    public let exactPages: [PageTreeExactPage]
    public let children: [PageTreeNode]

    public init(
        path: String,
        segment: String,
        prefixNotes: [LibraryNote],
        exactPages: [PageTreeExactPage],
        children: [PageTreeNode]
    ) {
        self.path = path
        self.segment = segment
        self.prefixNotes = prefixNotes
        self.exactPages = exactPages
        self.children = children
    }
}

/// Notes anchored to one exact page, including its stored query string.
public struct PageTreeExactPage: Equatable, Sendable {
    public let page: PageURL
    public let notes: [LibraryNote]

    public var query: String? { page.query }

    public init(page: PageURL, notes: [LibraryNote]) {
        self.page = page
        self.notes = notes
    }
}

private struct HostBuilder {
    let host: String
    var siteWide: [Note] = []
    var nodes: [String: NodeBuilder] = [:]

    mutating func addPrefix(_ note: Note, at path: String) {
        ensureNode(path)
        nodes[path]!.prefixNotes.append(note)
    }

    mutating func addExactPage(_ note: Note, page: PageURL, at path: String) {
        ensureNode(path)
        nodes[path]!.exactPages[page, default: []].append(note)
    }

    mutating func buildRoot() -> PageTreeNode {
        ensureNode("")
        var childrenByParent: [String: [String]] = [:]
        for path in nodes.keys where !path.isEmpty {
            childrenByParent[parentPath(path), default: []].append(path)
        }
        for parent in Array(childrenByParent.keys) {
            childrenByParent[parent]?.sort { nodes[$0]!.segment < nodes[$1]!.segment }
        }
        return buildNode("", childrenByParent: childrenByParent)
    }

    private mutating func ensureNode(_ path: String) {
        if nodes[""] == nil {
            nodes[""] = NodeBuilder(path: "", segment: "")
        }

        var current = ""
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + segment
            if nodes[current] == nil {
                nodes[current] = NodeBuilder(path: current, segment: String(segment))
            }
        }
    }

    private func buildNode(
        _ path: String,
        childrenByParent: [String: [String]]
    ) -> PageTreeNode {
        let builder = nodes[path]!
        let childPaths = childrenByParent[path] ?? []

        let exactPages = builder.exactPages
            .map { page, notes in
                PageTreeExactPage(
                    page: page,
                    notes: PageTree.libraryNotes(
                        NoteOrdering.sorted(notes, by: .updatedDescending)
                    )
                )
            }
            .sorted(by: PageTree.exactPageLess)

        return PageTreeNode(
            path: builder.path,
            segment: builder.segment,
            prefixNotes: PageTree.libraryNotes(
                NoteOrdering.sorted(builder.prefixNotes, by: .updatedDescending)
            ),
            exactPages: exactPages,
            children: childPaths.map { buildNode($0, childrenByParent: childrenByParent) }
        )
    }

    private func parentPath(_ path: String) -> String {
        guard let separator = path.lastIndex(of: "/") else { return "" }
        return String(path[..<separator])
    }
}

private struct NodeBuilder {
    let path: String
    let segment: String
    var prefixNotes: [Note] = []
    var exactPages: [PageURL: [Note]] = [:]
}
