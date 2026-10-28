import Foundation

private struct BindingIdentity: Hashable {
    let browser: String
    let profile: String
    let session: String
    let tabID: Int

    init(_ binding: TabBinding) {
        browser = binding.browser
        profile = binding.profile
        session = binding.session
        tabID = binding.tabID
    }

    init(_ tab: TabRef) {
        browser = tab.browser
        profile = tab.profile
        session = tab.session
        tabID = tab.tabID
    }
}

/// One open browser tab with the notes attached to it.
public struct LibraryOpenTabGroup: Equatable, Sendable {
    public let tab: TabRef
    public let index: Int
    public let windowOrder: Int
    public let windowFocused: Bool
    public let active: Bool
    public let url: String?
    public let title: String?
    public let notes: [LibraryNote]

    public init(
        tab: TabRef,
        index: Int,
        windowOrder: Int,
        windowFocused: Bool,
        active: Bool,
        url: String?,
        title: String?,
        notes: [LibraryNote]
    ) {
        self.tab = tab
        self.index = index
        self.windowOrder = windowOrder
        self.windowFocused = windowFocused
        self.active = active
        self.url = url
        self.title = title
        self.notes = notes
    }
}

/// One note whose tab binding is closed.
public struct LibraryClosedTabEntry: Equatable, Sendable {
    public let note: LibraryNote
    public let closedAt: Date

    public init(note: LibraryNote, closedAt: Date) {
        self.note = note
        self.closedAt = closedAt
    }
}

/// Pure grouping for the Library's Open Tabs and Closed tabs sections.
public enum LibraryTabGroups {
    /// Groups visible tab-bound notes and matching web-anchored notes by open tab.
    ///
    /// Incognito windows are skipped. App anchors are excluded so an app note
    /// cannot appear once per Chrome tab; a note bound to a tab still appears
    /// through its binding. Hidden and ephemeral notes are included.
    public static func openTabs(
        notes: [Note],
        inventory: LibraryInventory,
        rules: [QueryRule]
    ) -> [LibraryOpenTabGroup] {
        let effectiveRules = QueryRules.effective(
            rules: rules,
            anchors: notes.lazy.filter { $0.trashedAt == nil }.compactMap(\.anchor)
        )
        let ordinary = notes.filter(LibraryEligibility.isOrdinary)
        var boundNotes: [BindingIdentity: [Note]] = [:]
        var webNotesByHost: [String: [Note]] = [:]
        for note in ordinary {
            if let binding = note.tab, binding.closedAt == nil {
                boundNotes[BindingIdentity(binding), default: []].append(note)
            } else if case let .web(page, _)? = note.anchor {
                webNotesByHost[page.host, default: []].append(note)
            }
        }

        var groups: [LibraryOpenTabGroup] = []

        for window in inventory.windows where !window.incognito {
            for tab in window.tabs {
                let page = tab.url.flatMap {
                    PageURL(string: $0, queryRules: effectiveRules)
                }
                let tabRef = TabRef(
                    browser: window.browser,
                    profile: window.profile,
                    session: window.session,
                    tabID: tab.tabID,
                    windowID: window.windowID
                )
                let context = Context(
                    appBundleID: window.appBundleID,
                    page: page,
                    tab: tabRef
                )
                var candidates = boundNotes[BindingIdentity(tabRef)] ?? []
                if let page {
                    candidates.append(contentsOf: webNotesByHost[page.host] ?? [])
                }
                var seen: Set<UUID> = []
                let attached = candidates.filter {
                    seen.insert($0.id).inserted && NoteVisibility.isAttached($0, to: context)
                }
                guard !attached.isEmpty else { continue }

                groups.append(LibraryOpenTabGroup(
                    tab: tabRef,
                    index: tab.index,
                    windowOrder: window.order,
                    windowFocused: window.focused,
                    active: tab.active,
                    url: tab.url,
                    title: tab.title,
                    notes: NoteOrdering.sorted(attached, by: .updatedDescending)
                        .map(LibraryNote.init)
                ))
            }
        }

        return groups.sorted(by: isOrderedBefore)
    }

    /// Ordinary notes whose tab binding has a closure date, newest first.
    public static func closedTabs(notes: [Note]) -> [LibraryClosedTabEntry] {
        let closed = notes.filter { note in
            LibraryEligibility.isOrdinary(note) && note.tab?.closedAt != nil
        }

        return NoteOrdering.sorted(closed, by: .closedDescending).compactMap { note in
            guard let closedAt = note.tab?.closedAt else { return nil }
            return LibraryClosedTabEntry(note: LibraryNote(note: note), closedAt: closedAt)
        }
    }

    private static func isOrderedBefore(
        _ lhs: LibraryOpenTabGroup,
        _ rhs: LibraryOpenTabGroup
    ) -> Bool {
        if lhs.tab.browser != rhs.tab.browser { return lhs.tab.browser < rhs.tab.browser }
        if lhs.tab.profile != rhs.tab.profile { return lhs.tab.profile < rhs.tab.profile }
        if lhs.tab.session != rhs.tab.session { return lhs.tab.session < rhs.tab.session }
        if lhs.windowOrder != rhs.windowOrder { return lhs.windowOrder < rhs.windowOrder }
        if lhs.tab.windowID != rhs.tab.windowID { return lhs.tab.windowID < rhs.tab.windowID }
        if lhs.index != rhs.index { return lhs.index < rhs.index }
        if lhs.tab.tabID != rhs.tab.tabID { return lhs.tab.tabID < rhs.tab.tabID }

        if lhs.url != rhs.url { return (lhs.url ?? "") < (rhs.url ?? "") }
        if lhs.title != rhs.title { return (lhs.title ?? "") < (rhs.title ?? "") }
        if lhs.windowFocused != rhs.windowFocused {
            return falseFirst(lhs.windowFocused, rhs.windowFocused)
        }
        if lhs.active != rhs.active { return falseFirst(lhs.active, rhs.active) }
        return false
    }

    private static func falseFirst(_ lhs: Bool, _ rhs: Bool) -> Bool {
        !lhs && rhs
    }
}
