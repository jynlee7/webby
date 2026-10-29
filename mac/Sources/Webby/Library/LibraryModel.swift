import Foundation
import Observation
import WebbyCore

/// Which part of a workspace's page tree the note list shows.
enum LibraryPageSelection: Hashable, Sendable {
    case all
    case notAttached
    case site(host: String)
    case prefix(host: String, path: String)
    case page(PageURL)
}

/// Human-readable workspace names, including an honest marker for missing apps.
enum LibraryWorkspaceNames {
    static func displayName(for key: WorkspaceKey, appName: (String) -> String?) -> String {
        guard case let .app(bundleID) = key else {
            return key.displayName
        }
        if let name = appName(bundleID)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return "\(bundleID) (not installed)"
    }
}

/// Library presentation state. The model never owns note copies or writes the store
/// directly; `NotesController` remains the only owner of notes and mutations.
@MainActor @Observable
final class LibraryModel {
    struct EmptyTrashConfirmation: Equatable, Sendable {
        let count: Int
    }

    @ObservationIgnored private let controller: NotesController
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private let workspaceDisplayName: (WorkspaceKey) -> String
    @ObservationIgnored private var observerToken: UUID?
    @ObservationIgnored private var searchCache: LibrarySearchCache
    @ObservationIgnored private var cacheBuilt: Bool

    private(set) var result: LibraryResult
    private(set) var searchQuery: SearchQuery
    var searchText: String {
        didSet {
            guard searchText != oldValue else { return }
            searchQuery = SearchQuery(searchText)
            repairSelection()
        }
    }

    var selectedSection: LibrarySection
    var selectedWorkspace: WorkspaceDestination?
    var selectedPage: LibraryPageSelection
    var selectedTagKey: String?
    var selectedNoteID: UUID?
    private(set) var pendingEmptyTrash: EmptyTrashConfirmation?

    /// The number of full cache rebuilds since creation. Tests use this to prove a
    /// refresh after an edit updates entries without rebuilding from scratch.
    private(set) var searchCacheRebuildCount: Int

    init(
        controller: NotesController,
        clock: @escaping @MainActor () -> Date = { Date() },
        workspaceDisplayName: @escaping (WorkspaceKey) -> String = { $0.displayName }
    ) {
        let notes = controller.libraryNotes
        assert(notes.allSatisfy { !$0.ephemeral }, "Library snapshots must not contain ephemeral notes")

        self.controller = controller
        self.clock = clock
        self.workspaceDisplayName = workspaceDisplayName
        self.result = LibraryQuery.evaluate(
            notes: notes,
            workspaces: controller.libraryWorkspaces,
            now: clock()
        )
        self.searchQuery = SearchQuery("")
        self.searchText = ""
        self.selectedSection = .inbox
        self.selectedWorkspace = nil
        self.selectedPage = .all
        self.selectedTagKey = nil
        self.selectedNoteID = nil
        self.pendingEmptyTrash = nil
        self.searchCache = LibrarySearchCache(notes: notes)
        self.cacheBuilt = true
        self.searchCacheRebuildCount = 1
        self.observerToken = nil

        self.observerToken = controller.addLibraryObserver { [weak self] in
            self?.refresh()
        }
    }

    deinit {
        // LibraryModel is MainActor-isolated, so its last release normally happens on
        // the main actor. Trapping off-main is preferable to leaking the registration.
        MainActor.assumeIsolated {
            guard let token = self.observerToken else { return }
            self.controller.removeLibraryObserver(token)
        }
    }

    // MARK: Refresh and cache

    /// Re-evaluates the Library from the controller's current snapshots. Reading and
    /// refreshing never mutates the store.
    func refresh() {
        let notes = controller.libraryNotes
        assert(notes.allSatisfy { !$0.ephemeral }, "Library snapshots must not contain ephemeral notes")
        let workspaces = controller.libraryWorkspaces

        updateSearchCache(with: notes)
        result = LibraryQuery.evaluate(notes: notes, workspaces: workspaces, now: clock())
        repairSelection()
    }

    private func updateSearchCache(with notes: [Note]) {
        guard cacheBuilt else {
            searchCache.rebuild(notes: notes)
            cacheBuilt = true
            searchCacheRebuildCount += 1
            return
        }

        let currentIDs = Set(notes.map(\.id))
        for id in Array(searchCache.entries.keys) where !currentIDs.contains(id) {
            searchCache.remove(id: id)
        }
        for note in notes {
            searchCache.update(note)
        }
    }

    var searchCacheEntryCount: Int { searchCache.count }

    // MARK: Derived presentation values

    /// Read-only browsing stays available; mutations and Trash actions do not.
    var isWritable: Bool { controller.isWritable }
    var readOnlyProblem: String? { controller.readOnlyProblem }

    var libraryResult: LibraryResult { result }
    var sidebarCounts: [LibrarySection: Int] { result.counts }
    var sectionCounts: [LibrarySection: Int] { result.counts }

    func count(for section: LibrarySection) -> Int {
        result.count(for: section)
    }

    var searchDiagnostics: [SearchQuery.Diagnostic] { searchQuery.diagnostics }

    var selectedTag: LibraryTag? {
        guard let key = selectedTagKey else { return nil }
        return result.tags.first { $0.searchKey == key }?.tag
    }

    var selectedWorkspaceGroup: LibraryWorkspaceGroup? {
        guard let destination = selectedWorkspace else { return nil }
        return result.workspaces.first { $0.destination == destination }
    }

    var selectedNote: Note? {
        guard let id = selectedNoteID else { return nil }
        return controller.libraryNotes.first { $0.id == id && !$0.ephemeral }
    }

    var pageTree: PageTree? {
        guard let destination = selectedWorkspace else { return nil }
        let notes = result.workspaces
            .first { $0.destination == destination }?
            .notes.map(\.note) ?? []
        return PageTree.build(
            notes: notes,
            destination: destination,
            workspaces: controller.libraryWorkspaces
        )
    }

    var visibleNotes: [LibraryNote] {
        filteredNotes(baseNotesForSelection)
    }

    /// Short alias for views and tests.
    var notes: [LibraryNote] { visibleNotes }

    func displayName(for group: LibraryWorkspaceGroup) -> String {
        if let title = group.record?.title {
            let normalized = title.precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty { return normalized }
        }

        if let record = group.record, !record.keys.isEmpty {
            return record.keys
                .map { workspaceDisplayName($0) }
                .min() ?? group.displayName
        }

        if case .implicit(let key) = group.destination {
            return workspaceDisplayName(key)
        }
        return group.displayName
    }

    func displayName(for key: WorkspaceKey) -> String {
        workspaceDisplayName(key)
    }

    private var baseNotesForSelection: [LibraryNote] {
        switch selectedSection {
        case .inbox:
            return result.inbox
        case .closedTabs:
            return result.closedTabs
        case .pinned:
            return result.pinned
        case .recent:
            return result.recent
        case .all:
            return result.all
        case .workspaces:
            if let destination = selectedWorkspace {
                guard let group = result.workspaces.first(where: { $0.destination == destination }) else {
                    return []
                }
                return notes(in: group, for: selectedPage)
            }
            if selectedPage == .all {
                return result.workspaces.flatMap(\.notes)
            }
            return result.workspaces.flatMap { notes(in: $0, for: selectedPage) }
        case .tags:
            guard let key = selectedTagKey else { return [] }
            return result.tags.first { $0.searchKey == key }?.notes ?? []
        case .trash:
            return result.trash
        }
    }

    private func notes(in group: LibraryWorkspaceGroup, for page: LibraryPageSelection) -> [LibraryNote] {
        guard page != .all else { return group.notes }
        let tree = PageTree.build(
            notes: group.notes.map(\.note),
            destination: group.destination,
            workspaces: controller.libraryWorkspaces
        )
        return notes(in: tree, for: page)
    }

    private func notes(in tree: PageTree, for page: LibraryPageSelection) -> [LibraryNote] {
        switch page {
        case .all:
            return sortedNotes(allNotes(in: tree))

        case .notAttached:
            return tree.notAttached

        case .site(let host):
            let normalized = normalizedHost(host)
            guard let hostNode = tree.hosts.first(where: { $0.host == normalized }) else {
                return []
            }
            var notes = hostNode.siteWide
            appendNotes(from: hostNode.root, to: &notes)
            return sortedNotes(notes)

        case .prefix(let host, let path):
            let normalized = normalizedHost(host)
            guard let hostNode = tree.hosts.first(where: { $0.host == normalized }),
                  let node = findNode(hostNode.root, path: normalizedPath(path, host: hostNode.host))
            else {
                return []
            }
            var notes = node.prefixNotes
            for exact in node.exactPages {
                notes.append(contentsOf: exact.notes)
            }
            for child in node.children {
                appendNotes(from: child, to: &notes)
            }
            return sortedNotes(notes)

        case .page(let page):
            guard let hostNode = tree.hosts.first(where: { $0.host == page.host }) else {
                return []
            }
            return exactPageNotes(in: hostNode.root) { $0.page == page }
        }
    }

    private func allNotes(in tree: PageTree) -> [LibraryNote] {
        var notes = tree.notAttached
        for host in tree.hosts {
            notes.append(contentsOf: host.siteWide)
            appendNotes(from: host.root, to: &notes)
        }
        return notes
    }

    private func appendNotes(from node: PageTreeNode, to notes: inout [LibraryNote]) {
        notes.append(contentsOf: node.prefixNotes)
        for exact in node.exactPages {
            notes.append(contentsOf: exact.notes)
        }
        for child in node.children {
            appendNotes(from: child, to: &notes)
        }
    }

    private func findNode(_ node: PageTreeNode, path: String) -> PageTreeNode? {
        if node.path == path { return node }
        for child in node.children {
            if let found = findNode(child, path: path) { return found }
        }
        return nil
    }

    private func exactPageNotes(
        in node: PageTreeNode,
        matching predicate: (PageTreeExactPage) -> Bool
    ) -> [LibraryNote] {
        var notes: [LibraryNote] = []
        for exact in node.exactPages where predicate(exact) {
            notes.append(contentsOf: exact.notes)
        }
        for child in node.children {
            notes.append(contentsOf: exactPageNotes(in: child, matching: predicate))
        }
        return sortedNotes(notes)
    }

    private func sortedNotes(_ notes: [LibraryNote]) -> [LibraryNote] {
        NoteOrdering.sorted(notes.map(\.note), by: .updatedDescending)
            .map { LibraryNote(note: $0) }
    }

    private func filteredNotes(_ notes: [LibraryNote]) -> [LibraryNote] {
        guard !searchText.isEmpty else { return notes }

        let ids = searchCache.search(
            queryForCurrentSection,
            notes: notes.map(\.note),
            workspaces: controller.libraryWorkspaces
        )
        let byID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    private var queryForCurrentSection: SearchQuery {
        guard selectedSection == .trash else { return searchQuery }
        guard !searchQuery.clauses.contains(.state(.trashed)) else { return searchQuery }
        return SearchQuery(
            clauses: searchQuery.clauses + [.state(.trashed)],
            diagnostics: searchQuery.diagnostics
        )
    }

    // MARK: Selection

    func select(section: LibrarySection) {
        selectedSection = section
        if section != .workspaces {
            selectedWorkspace = nil
            selectedPage = .all
        }
        if section != .tags {
            selectedTagKey = nil
        }
        repairSelection()
    }

    func select(workspace destination: WorkspaceDestination?) {
        selectedSection = .workspaces
        selectedWorkspace = destination
        selectedPage = .all
        selectedTagKey = nil
        repairSelection()
    }

    func select(page: LibraryPageSelection) {
        selectedSection = .workspaces
        selectedPage = page
        selectedTagKey = nil
        repairSelection()
    }

    func select(tag: LibraryTag) {
        select(tagKey: tag.searchKey)
    }

    func select(tagKey: String) {
        selectedSection = .tags
        selectedTagKey = tagKey
        selectedWorkspace = nil
        selectedPage = .all
        repairSelection()
    }

    func select(_ section: LibrarySection) { select(section: section) }
    func select(_ workspace: WorkspaceDestination?) { select(workspace: workspace) }
    func select(_ page: LibraryPageSelection) { select(page: page) }
    func select(_ tag: LibraryTag) { select(tag: tag) }

    /// Selects the Library destination that contains a note. Trashed notes select
    /// Trash. Missing and ephemeral IDs return false without changing the selection.
    @discardableResult
    func selectNote(_ id: UUID) -> Bool {
        guard let note = controller.libraryNotes.first(where: { $0.id == id }), !note.ephemeral else {
            return false
        }

        if note.trashedAt != nil {
            selectedSection = .trash
            selectedWorkspace = nil
            selectedPage = .all
            selectedTagKey = nil
        } else {
            let destination = WorkspaceResolver.resolve(note, workspaces: controller.libraryWorkspaces)
            if destination == .inbox {
                selectedSection = .inbox
                selectedWorkspace = nil
                selectedPage = .all
                selectedTagKey = nil
            } else {
                selectedSection = .workspaces
                selectedWorkspace = destination
                selectedPage = pageSelection(for: note)
                selectedTagKey = nil
            }
        }

        selectedNoteID = id
        repairSelection()
        return selectedNoteID == id
    }

    private func pageSelection(for note: Note) -> LibraryPageSelection {
        guard note.tab == nil, let anchor = note.anchor else { return .notAttached }
        switch anchor {
        case .app:
            return .notAttached
        case .web(let page, let scope):
            switch scope {
            case .site:
                return .site(host: page.host)
            case .prefix(let path):
                return .prefix(host: page.host, path: normalizedPath(path, host: page.host))
            case .page:
                return .page(page)
            }
        }
    }

    private func repairSelection() {
        if let destination = selectedWorkspace,
           !result.workspaces.contains(where: { $0.destination == destination }) {
            selectedWorkspace = nil
            selectedPage = .all
        }

        if let key = selectedTagKey,
           !result.tags.contains(where: { $0.searchKey == key }) {
            selectedTagKey = nil
        }

        if !pageSelectionIsValid {
            selectedPage = .all
        }

        if let id = selectedNoteID,
           !visibleNotes.contains(where: { $0.id == id }) {
            selectedNoteID = nil
        }
    }

    private var pageSelectionIsValid: Bool {
        switch selectedPage {
        case .all:
            return true
        case .notAttached:
            return selectedWorkspace != nil
        case .site(let host):
            guard selectedWorkspace != nil else { return false }
            let normalized = normalizedHost(host)
            return pageTree?.hosts.contains { $0.host == normalized } ?? false
        case .prefix(let host, let path):
            guard selectedWorkspace != nil else { return false }
            let normalized = normalizedHost(host)
            guard let hostNode = pageTree?.hosts.first(where: { $0.host == normalized }),
                  findNode(hostNode.root, path: normalizedPath(path, host: hostNode.host)) != nil
            else {
                return false
            }
            return true
        case .page(let page):
            guard selectedWorkspace != nil else { return false }
            guard let hostNode = pageTree?.hosts.first(where: { $0.host == page.host }) else {
                return false
            }
            return exactPageNotes(in: hostNode.root) { $0.page == page }.isEmpty == false
        }
    }

    // MARK: Destructive confirmation

    func requestEmptyTrash() {
        pendingEmptyTrash = EmptyTrashConfirmation(count: result.trash.count)
    }

    func confirmEmptyTrash() {
        pendingEmptyTrash = nil
        controller.emptyTrash()
        refresh()
    }

    func cancelEmptyTrash() {
        pendingEmptyTrash = nil
    }

    // MARK: Mutations

    func updateText(id: UUID, text: String) {
        controller.updateLibraryText(id: id, text: text)
        refresh()
    }

    func attach(id: UUID, anchor: Anchor?, workspace: UUID?) {
        controller.setLibraryAttachment(id: id, anchor: anchor, workspace: workspace)
        refresh()
    }

    func setPinned(id: UUID, pinned: Bool) {
        controller.setPinned(id: id, pinned: pinned)
        refresh()
    }

    func setHidden(id: UUID, hidden: Bool) {
        controller.setHidden(id: id, hidden: hidden)
        refresh()
    }

    func setExcludedFromAgent(id: UUID, excluded: Bool) {
        controller.setExcludedFromAgent(id: id, excluded: excluded)
        refresh()
    }

    func trash(id: UUID) {
        controller.trashLibraryNote(id: id)
        refresh()
    }

    func restore(id: UUID) {
        controller.restoreLibraryNote(id: id)
        refresh()
    }

    @discardableResult
    func createNote(destination: LibraryDestination) -> UUID? {
        let id = controller.createLibraryNote(destination: destination)
        refresh()
        return id
    }

    // MARK: Normalization

    private func normalizedHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return PageURL(host: trimmed, path: "").host
    }

    private func normalizedPath(_ path: String, host: String) -> String {
        guard !host.isEmpty else { return path }
        return PageURL(host: host, path: path).path
    }
}
