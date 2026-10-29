import Foundation
import Observation
import WebbyCore

/// How the Library content column presents notes.
enum LibraryContentMode: String, CaseIterable, Equatable, Sendable {
    case list
    case compiled
}

/// A validated, immutable export scope. Page and workspace scopes never depend on
/// the current search result; selected notes are the explicit exception.
enum LibraryExportSelection: Equatable, Sendable {
    case workspace(WorkspaceDestination)
    case page(WorkspaceDestination, PageURL)
    case all
    case selected(Set<UUID>)
}

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
        let ids: Set<UUID>
    }

    @ObservationIgnored private let controller: NotesController
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private let workspaceDisplayName: (WorkspaceKey) -> String
    @ObservationIgnored private let userQueryRules: [QueryRule]
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
    /// The table's multi-selection. Repaired on every refresh so it never keeps a
    /// trashed, purged, ephemeral or filtered-out note.
    var selectedNoteIDs: Set<UUID> = []
    /// Set when a deep link routes to a note, so the detail editor can take focus.
    private(set) var detailFocusRequest: UUID?
    var contentMode: LibraryContentMode = .list
    var exportStatus: String?
    var importStatus: String?
    private(set) var pendingEmptyTrash: EmptyTrashConfirmation?

    /// The number of full cache rebuilds since creation. Tests use this to prove a
    /// refresh after an edit updates entries without rebuilding from scratch.
    private(set) var searchCacheRebuildCount: Int

    init(
        controller: NotesController,
        clock: @escaping @MainActor () -> Date = { Date() },
        workspaceDisplayName: @escaping (WorkspaceKey) -> String = { $0.displayName },
        userQueryRules: [QueryRule] = []
    ) {
        let notes = controller.libraryNotes
        assert(notes.allSatisfy { !$0.ephemeral }, "Library snapshots must not contain ephemeral notes")

        self.controller = controller
        self.clock = clock
        self.workspaceDisplayName = workspaceDisplayName
        self.userQueryRules = userQueryRules
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

    /// The detail pane focuses the existing single-note selection. Multi-selection
    /// never replaces it unless the focused row disappears.
    var focusedNoteID: UUID? { selectedNoteID }

    /// Requests focus for the detail editor after a deep link selects its note.
    func requestDetailFocus(_ id: UUID) {
        detailFocusRequest = id
    }

    /// Consumes a matching focus request. The detail view calls this once it has
    /// loaded the routed note.
    func consumeDetailFocus(_ id: UUID) -> Bool {
        guard detailFocusRequest == id else { return false }
        detailFocusRequest = nil
        return true
    }

    /// The store owner, exposed only so the app-level import controller can plan
    /// against the same live snapshot the Library shows.
    var notesController: NotesController { controller }

    struct ExportSnapshot: Equatable, Sendable {
        let notes: [Note]
        let workspaces: [WorkspaceRecord]
        let queryRules: [QueryRule]
    }

    /// A side-effect-free snapshot for export and import planning. Callers commit
    /// editor drafts first.
    func exportSnapshot() -> ExportSnapshot {
        ExportSnapshot(
            notes: controller.libraryNotes,
            workspaces: controller.libraryWorkspaces,
            queryRules: effectiveQueryRules
        )
    }

    /// The explicit scope for a workspace export, when one is selected.
    var workspaceExportSelection: LibraryExportSelection? {
        if selectedSection == .inbox {
            return .workspace(.inbox)
        }
        guard selectedSection == .workspaces, let selectedWorkspace else { return nil }
        return .workspace(selectedWorkspace)
    }

    /// The explicit scope for a page export, only when the current sidebar row is a page.
    var pageExportSelection: LibraryExportSelection? {
        guard selectedSection == .workspaces,
              let selectedWorkspace,
              case .page(let page) = selectedPage
        else { return nil }
        return .page(selectedWorkspace, page)
    }

    /// Explicit row selection, intersected with what is currently visible.
    var selectedNotesExportSelection: LibraryExportSelection? {
        let ids = selectedNoteIDs.intersection(Set(visibleNotes.map(\.id)))
        return ids.isEmpty ? nil : .selected(ids)
    }

    /// The most specific export scope: an explicit row selection first, then a page,
    /// then a workspace, then all notes.
    var exportSelection: LibraryExportSelection {
        if let selection = selectedNotesExportSelection { return selection }
        if let selection = pageExportSelection { return selection }
        if let selection = workspaceExportSelection { return selection }
        return .all
    }

    /// Builds the compiled view from the explicit sidebar scope. Search results are
    /// deliberately ignored, so a query never changes what the compiled pane shows.
    func compiledDocument() -> CompiledDocument? {
        _ = result
        let notes = controller.libraryNotes
        let workspaces = controller.libraryWorkspaces
        let rules = effectiveQueryRules

        if selectedSection == .inbox {
            return CompiledDocument.workspace(
                destination: .inbox,
                notes: notes,
                workspaces: workspaces,
                queryRules: rules
            )
        }

        guard selectedSection == .workspaces, let destination = selectedWorkspace else {
            return nil
        }

        if case .page(let page) = selectedPage {
            return CompiledDocument.page(
                page,
                destination: destination,
                notes: notes,
                workspaces: workspaces,
                queryRules: rules
            )
        }

        return CompiledDocument.workspace(
            destination: destination,
            notes: notes,
            workspaces: workspaces,
            queryRules: rules
        )
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

    /// Toolbar search spans the whole Library, not just the selected sidebar row.
    /// Trash stays out unless the query asks for it with `is:trashed`.
    var visibleNotes: [LibraryNote] {
        guard !searchText.isEmpty else {
            return filteredNotes(baseNotesForSelection)
        }
        let universe = result.all + result.trash
        let byID = Dictionary(uniqueKeysWithValues: universe.map { ($0.id, $0) })
        let matches = searchCache.search(
            effectiveSearchQuery,
            notes: universe.map(\.note),
            workspaces: controller.libraryWorkspaces
        )
        return matches.compactMap { byID[$0] }
    }

    /// Trash searches only Trash unless the query already names another state.
    var effectiveSearchQuery: SearchQuery {
        guard selectedSection == .trash,
              !searchQuery.clauses.contains(where: { clause in
                  if case .state = clause { return true }
                  return false
              })
        else {
            return searchQuery
        }
        return SearchQuery(
            clauses: searchQuery.clauses + [.state(.trashed)],
            diagnostics: searchQuery.diagnostics
        )
    }

    /// Built-ins, the user's rules, and every key still used by a page anchor.
    var effectiveQueryRules: [QueryRule] {
        QueryRules.effective(
            rules: QueryRules.builtIns + userQueryRules,
            anchors: controller.libraryNotes.compactMap(\.anchor)
        )
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
        selectedNoteIDs = [id]
        repairSelection()
        return selectedNoteID == id
    }

    /// Ordinary table row selection: changes only the detail selection, so the sidebar
    /// context and the rest of the rows stay put. A plain row click collapses the
    /// multi-selection to that note; command-click uses `toggleSelection`.
    @discardableResult
    func selectRow(_ id: UUID) -> Bool {
        guard let note = controller.libraryNotes.first(where: { $0.id == id }), !note.ephemeral else {
            return false
        }
        selectedNoteID = id
        selectedNoteIDs = [id]
        repairSelection()
        return selectedNoteID == id
    }

    /// Replaces the table's multi-selection with visible, durable notes only. The
    /// detail selection stays on the current row when it is still selected, else it
    /// moves to the first selected ID.
    func setSelection(_ ids: Set<UUID>) {
        let visible = Set(visibleNotes.map(\.id))
        selectedNoteIDs = ids.intersection(visible)
        if let current = selectedNoteID, selectedNoteIDs.contains(current) {
            // Keep the focused row.
        } else {
            selectedNoteID = selectedNoteIDs
                .min { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        }
        repairSelection()
    }

    /// Toggles one visible row for a multi-selection. Returns whether it is selected.
    @discardableResult
    func toggleSelection(_ id: UUID) -> Bool {
        let visible = Set(visibleNotes.map(\.id))
        guard visible.contains(id),
              controller.libraryNotes.contains(where: { $0.id == id && !$0.ephemeral })
        else { return false }

        if selectedNoteIDs.contains(id) {
            selectedNoteIDs.remove(id)
            if selectedNoteID == id {
                selectedNoteID = selectedNoteIDs
                    .min { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
            }
        } else {
            selectedNoteIDs.insert(id)
            selectedNoteID = id
        }
        repairSelection()
        return selectedNoteIDs.contains(id)
    }

    func clearSelection() {
        selectedNoteID = nil
        selectedNoteIDs.removeAll()
    }

    /// Explicit reveal: clears a stale query, then navigates. Missing and ephemeral IDs
    /// leave the selection and the query untouched.
    @discardableResult
    func revealNote(_ id: UUID) -> Bool {
        guard controller.libraryNotes.contains(where: { $0.id == id && !$0.ephemeral }) else {
            return false
        }
        if !searchText.isEmpty {
            searchText = ""
        }
        return selectNote(id)
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

        let visibleIDs = Set(visibleNotes.map(\.id))
        if let id = selectedNoteID, !visibleIDs.contains(id) {
            selectedNoteID = nil
        }

        // Multi-selection follows the same repair rule as the detail selection, and
        // never keeps an ephemeral ID even when a caller supplied one directly.
        let durableIDs = Set(controller.libraryNotes.filter { !$0.ephemeral }.map(\.id))
        selectedNoteIDs = selectedNoteIDs.intersection(visibleIDs).intersection(durableIDs)
        if let id = selectedNoteID {
            selectedNoteIDs.insert(id)
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
        let ids = Set(result.trash.map(\.id))
        pendingEmptyTrash = EmptyTrashConfirmation(count: ids.count, ids: ids)
    }

    func confirmEmptyTrash() {
        guard let pending = pendingEmptyTrash else { return }
        pendingEmptyTrash = nil
        controller.emptyTrash(ids: pending.ids)
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
        // A blank note cannot match the current query, so clear it before revealing.
        if !searchText.isEmpty {
            searchText = ""
        }
        let id = controller.createLibraryNote(destination: destination)
        refresh()
        if let id {
            _ = revealNote(id)
        }
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
