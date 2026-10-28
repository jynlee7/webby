import Foundation

/// How workspace groups are ordered after pinned groups.
public enum WorkspaceOrder: Equatable, CaseIterable, Sendable {
    case activity
    case alphabetical
}

/// The stable sidebar section order.
public enum LibrarySection: String, CaseIterable, Equatable, Hashable, Sendable {
    case inbox
    case closedTabs
    case pinned
    case recent
    case all
    case workspaces
    case tags
    case trash
}

/// One workspace group, explicit or implicit.
public struct LibraryWorkspaceGroup: Equatable, Sendable {
    public let destination: WorkspaceDestination
    public let record: WorkspaceRecord?
    public let notes: [LibraryNote]
    public let lastActivity: Date?
    public let pinned: Bool

    public var count: Int {
        Set(notes.map(\.id)).count
    }

    /// The visible sidebar name: a custom title, else the record's first key.
    public var displayName: String {
        if let title = record?.title {
            let normalized = title.precomposedStringWithCanonicalMapping
            if !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return normalized
            }
        }
        if let record, let key = record.keys.map(\.displayName).min() {
            return key
        }
        switch destination {
        case .implicit(let key):
            return key.displayName
        case .inbox, .record:
            return "Workspace"
        }
    }

    public init(
        destination: WorkspaceDestination,
        record: WorkspaceRecord?,
        notes: [LibraryNote],
        lastActivity: Date?,
        pinned: Bool
    ) {
        self.destination = destination
        self.record = record
        self.notes = notes
        self.lastActivity = lastActivity
        self.pinned = pinned
    }
}

/// One tag group, merged by case- and diacritic-insensitive search key.
public struct LibraryTagGroup: Equatable, Sendable {
    public let name: String
    public let searchKey: String
    public let notes: [LibraryNote]

    public var tag: LibraryTag {
        LibraryTag(name: name, searchKey: searchKey)
    }

    public var count: Int {
        Set(notes.map(\.id)).count
    }

    public init(name: String, searchKey: String, notes: [LibraryNote]) {
        self.name = name
        self.searchKey = searchKey
        self.notes = notes
    }
}

/// The typed result of evaluating the Library sidebar.
public struct LibraryResult: Equatable, Sendable {
    public static let sectionOrder: [LibrarySection] = [
        .inbox,
        .closedTabs,
        .pinned,
        .recent,
        .all,
        .workspaces,
        .tags,
        .trash,
    ]

    public let inbox: [LibraryNote]
    public let closedTabs: [LibraryNote]
    public let pinned: [LibraryNote]
    public let recent: [LibraryNote]
    public let all: [LibraryNote]
    public let workspaces: [LibraryWorkspaceGroup]
    public let tags: [LibraryTagGroup]
    public let trash: [LibraryNote]

    public var sectionOrder: [LibrarySection] {
        Self.sectionOrder
    }

    public var counts: [LibrarySection: Int] {
        Dictionary(
            uniqueKeysWithValues: Self.sectionOrder.map { ($0, count(for: $0)) }
        )
    }

    public init(
        inbox: [LibraryNote],
        closedTabs: [LibraryNote],
        pinned: [LibraryNote],
        recent: [LibraryNote],
        all: [LibraryNote],
        workspaces: [LibraryWorkspaceGroup],
        tags: [LibraryTagGroup],
        trash: [LibraryNote]
    ) {
        self.inbox = inbox
        self.closedTabs = closedTabs
        self.pinned = pinned
        self.recent = recent
        self.all = all
        self.workspaces = workspaces
        self.tags = tags
        self.trash = trash
    }

    /// Counts distinct note IDs in a section.
    public func count(for section: LibrarySection) -> Int {
        switch section {
        case .inbox:
            return Set(inbox.map(\.id)).count
        case .closedTabs:
            return Set(closedTabs.map(\.id)).count
        case .pinned:
            return Set(pinned.map(\.id)).count
        case .recent:
            return Set(recent.map(\.id)).count
        case .all:
            return Set(all.map(\.id)).count
        case .workspaces:
            return Set(workspaces.flatMap { $0.notes.map(\.id) }).count
        case .tags:
            return Set(tags.flatMap { $0.notes.map(\.id) }).count
        case .trash:
            return Set(trash.map(\.id)).count
        }
    }
}

public enum LibraryQuery {
    private static let recentInterval: TimeInterval = 14 * 86_400
    private static let recentLimit = 100

    public static func evaluate(
        notes: [Note],
        workspaces: [WorkspaceRecord],
        now: Date,
        workspaceOrder: WorkspaceOrder = .activity
    ) -> LibraryResult {
        let ordinary = notes.filter(LibraryEligibility.isOrdinary)
        let trashed = notes.filter(LibraryEligibility.isTrash)

        let inbox = LibraryNote.wrap(
            NoteOrdering.sorted(
                ordinary.filter { WorkspaceResolver.isInbox($0, workspaces: workspaces) },
                by: .updatedDescending
            )
        )

        let closedTabs = LibraryNote.wrap(
            NoteOrdering.sorted(
                ordinary.filter { $0.tab?.closedAt != nil },
                by: .closedDescending
            )
        )

        let pinned = LibraryNote.wrap(
            NoteOrdering.sorted(
                ordinary.filter { $0.pinnedAt != nil },
                by: .pinnedDescending
            )
        )

        let cutoff = now.addingTimeInterval(-recentInterval)
        let recent = LibraryNote.wrap(
            Array(
                NoteOrdering.sorted(
                    ordinary.filter { $0.updatedAt >= cutoff && $0.updatedAt <= now },
                    by: .updatedDescending
                )
                .prefix(recentLimit)
            )
        )

        let all = LibraryNote.wrap(
            NoteOrdering.sorted(ordinary, by: .updatedDescending)
        )

        let workspaceGroups = makeWorkspaceGroups(
            ordinary: ordinary,
            workspaces: workspaces,
            order: workspaceOrder
        )
        let tagGroups = makeTagGroups(ordinary: ordinary)
        let trash = LibraryNote.wrap(
            NoteOrdering.sorted(trashed, by: .trashedDescending)
        )

        return LibraryResult(
            inbox: inbox,
            closedTabs: closedTabs,
            pinned: pinned,
            recent: recent,
            all: all,
            workspaces: workspaceGroups,
            tags: tagGroups,
            trash: trash
        )
    }

    private static func makeWorkspaceGroups(
        ordinary: [Note],
        workspaces: [WorkspaceRecord],
        order: WorkspaceOrder
    ) -> [LibraryWorkspaceGroup] {
        var records: [UUID: WorkspaceRecord] = [:]
        for record in workspaces where records[record.id] == nil {
            records[record.id] = record
        }

        var notesByDestination: [WorkspaceDestination: [Note]] = [:]
        for record in workspaces where notesByDestination[.record(record.id)] == nil {
            notesByDestination[.record(record.id)] = []
        }

        for note in ordinary {
            let destination = WorkspaceResolver.resolve(note, workspaces: workspaces)
            guard destination != .inbox else { continue }
            notesByDestination[destination, default: []].append(note)
        }

        var groups = notesByDestination.map { destination, notes -> LibraryWorkspaceGroup in
            let record: WorkspaceRecord?
            if case let .record(id) = destination {
                record = records[id]
            } else {
                record = nil
            }

            let sortedNotes = LibraryNote.wrap(
                NoteOrdering.sorted(notes, by: .updatedDescending)
            )

            return LibraryWorkspaceGroup(
                destination: destination,
                record: record,
                notes: sortedNotes,
                lastActivity: notes.map(\.updatedAt).max(),
                pinned: record?.pinned ?? false
            )
        }

        groups.sort { compareWorkspaceGroups($0, $1, order: order) }
        return groups
    }

    private static func compareWorkspaceGroups(
        _ lhs: LibraryWorkspaceGroup,
        _ rhs: LibraryWorkspaceGroup,
        order: WorkspaceOrder
    ) -> Bool {
        if lhs.pinned != rhs.pinned {
            return lhs.pinned
        }

        switch order {
        case .activity:
            switch (lhs.lastActivity, rhs.lastActivity) {
            case let (lhsDate?, rhsDate?):
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                break
            }
        case .alphabetical:
            let folded = { (group: LibraryWorkspaceGroup) in
                group.displayName.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: nil
                )
            }
            let lhsKey = folded(lhs)
            let rhsKey = folded(rhs)
            if lhsKey != rhsKey {
                return lhsKey < rhsKey
            }
            if lhs.displayName != rhs.displayName {
                return lhs.displayName < rhs.displayName
            }
        }

        return destinationSortKey(lhs.destination) < destinationSortKey(rhs.destination)
    }

    private static func workspaceDisplayKey(_ group: LibraryWorkspaceGroup) -> String {
        group.displayName
    }

    private static func destinationSortKey(_ destination: WorkspaceDestination) -> String {
        switch destination {
        case .inbox:
            return "inbox"
        case let .implicit(key):
            return keySortKey(key)
        case let .record(id):
            return "record:\(id.uuidString.lowercased())"
        }
    }

    private static func keySortKey(_ key: WorkspaceKey) -> String {
        switch key {
        case let .host(name):
            return "host:\(name)"
        case let .app(bundleID):
            return "app:\(bundleID)"
        case .localFiles:
            return "localFiles"
        case .tabsWithoutPage:
            return "tabsWithoutPage"
        }
    }

    private static func makeTagGroups(ordinary: [Note]) -> [LibraryTagGroup] {
        var namesBySearchKey: [String: [String]] = [:]
        var notesBySearchKey: [String: [Note]] = [:]

        for note in ordinary {
            var seenInNote: Set<String> = []
            for tag in Tags.parse(note.text) {
                guard seenInNote.insert(tag.searchKey).inserted else { continue }
                namesBySearchKey[tag.searchKey, default: []].append(tag.name)
                notesBySearchKey[tag.searchKey, default: []].append(note)
            }
        }

        var groups = notesBySearchKey.map { searchKey, notes -> LibraryTagGroup in
            let names = namesBySearchKey[searchKey] ?? []
            let name = names
                .map { $0.precomposedStringWithCanonicalMapping }
                .min() ?? searchKey

            return LibraryTagGroup(
                name: name,
                searchKey: searchKey,
                notes: LibraryNote.wrap(
                    NoteOrdering.sorted(notes, by: .updatedDescending)
                )
            )
        }

        groups.sort { $0.searchKey < $1.searchKey }
        return groups
    }
}

private extension LibraryNote {
    static func wrap(_ notes: [Note]) -> [LibraryNote] {
        notes.map(LibraryNote.init(note:))
    }
}
