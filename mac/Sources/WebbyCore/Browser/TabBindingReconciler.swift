import Foundation

/// The new value of one note's tab binding. The app applies it with
/// `NoteStore.updateBinding`, which never changes `revision` or `updatedAt`:
/// following a tab is bookkeeping, not an edit (decision 33).
public struct TabBindingUpdate: Equatable, Sendable {
    public let noteID: UUID
    public let binding: TabBinding

    public init(noteID: UUID, binding: TabBinding) {
        self.noteID = noteID
        self.binding = binding
    }
}

/// Keeps "Just this tab" bindings on their tabs (plan §5.1.4).
///
/// Decision: `closedAt` and `pendingRestore` together carry the whole lifecycle, so
/// notes.json keeps schema version 2:
///
/// | closedAt | pendingRestore | Meaning |
/// | --- | --- | --- |
/// | nil | false | Bound to a live tab |
/// | nil | true | Re-attached by a restore match; shows the "Restored" badge |
/// | set | true | Closed by a Chrome quit or session change; awaiting one restore check |
/// | set | false | In Closed tabs: closed by the user, or not matched one-to-one |
///
/// Within one Chrome run a binding follows its tab ID alone and never compares URLs.
/// The reconciler's only state is the list of tabs that closed with their window, which
/// a Chrome quit can turn into restore candidates.
public struct TabBindingReconciler: Sendable {
    /// How close to Chrome's termination a window closure counts as part of the quit.
    public static let quitWindow: TimeInterval = 3

    /// Notes whose tab closed with its window, and when.
    public private(set) var recentWindowClosures: [UUID: Date] = [:]

    public init() {}

    /// Applies one bridge event for the running Chrome `session`. Events that carry no
    /// tab change, disconnects and drops (an extension reload keeps tab IDs) change
    /// nothing. An unknown session never updates a binding.
    public mutating func receive(_ event: BridgeEvent, notes: [Note], session: String?, now: Date) -> [TabBindingUpdate] {
        guard case let .message(_, profile, message) = event,
              let session, session != OpenTabsInventory.unknownSession else { return [] }
        let bound = notes.filter { note in
            guard let binding = note.tab else { return false }
            return binding.closedAt == nil && binding.browser == OpenTabsInventory.bundleID
                && binding.profile == profile && binding.session == session
        }
        guard !bound.isEmpty else { return [] }

        var updates: [TabBindingUpdate] = []
        func update(_ note: Note, _ change: (inout TabBinding) -> Void) {
            guard var binding = note.tab else { return }
            change(&binding)
            if binding != note.tab { updates.append(TabBindingUpdate(noteID: note.id, binding: binding)) }
        }

        switch message {
        case .hello, .tabCreated:
            break
        case let .tabUpdated(tabID, url, title):
            for note in bound where note.tab?.tabID == tabID {
                update(note) { Self.refresh(&$0, url: url, title: title) }
            }
        case let .active(windowID, _, tab):
            for note in bound where note.tab?.tabID == tab.id {
                update(note) {
                    $0.windowID = windowID
                    $0.index = tab.index
                    Self.refresh(&$0, url: tab.url, title: tab.title)
                }
            }
        case let .tabMoved(tabID, windowID, index):
            for note in bound where note.tab?.tabID == tabID {
                update(note) {
                    $0.windowID = windowID
                    $0.index = index
                }
            }
        case let .tabReplaced(added, removed):
            for note in bound where note.tab?.tabID == removed {
                update(note) { $0.tabID = added }
            }
        case let .tabClosed(tabID, windowClosing):
            for note in bound where note.tab?.tabID == tabID {
                update(note) { Self.close(&$0, now: now) }
                if windowClosing { recentWindowClosures[note.id] = now }
            }
        case let .inventory(windows):
            for note in bound {
                guard let tabID = note.tab?.tabID else { continue }
                if let window = windows.first(where: { $0.tabs.contains { $0.id == tabID } }),
                   let tab = window.tabs.first(where: { $0.id == tabID }) {
                    update(note) {
                        $0.windowID = window.id
                        $0.index = tab.index
                        Self.refresh(&$0, url: tab.url, title: tab.title)
                    }
                } else {
                    // A full snapshot without the tab: it closed, possibly with its window,
                    // while no single event said so. Chrome's quit can look like this.
                    update(note) { Self.close(&$0, now: now) }
                    recentWindowClosures[note.id] = now
                }
            }
        }
        return updates
    }

    /// Chrome's process `session` ended. Its open bindings wait for one restore check,
    /// and so do tabs that closed with their window just before: Chrome's shutdown can
    /// close windows before the process exits.
    public mutating func chromeTerminated(session: String, notes: [Note], now: Date) -> [TabBindingUpdate] {
        defer { recentWindowClosures.removeAll() }
        var updates: [TabBindingUpdate] = []
        for note in notes {
            guard var binding = note.tab, binding.browser == OpenTabsInventory.bundleID,
                  binding.session == session else { continue }
            if binding.closedAt == nil {
                binding.closedAt = now
                binding.pendingRestore = true
            } else if let closed = recentWindowClosures[note.id],
                      now.timeIntervalSince(closed) <= Self.quitWindow, !binding.pendingRestore {
                binding.pendingRestore = true
            }
            if binding != note.tab { updates.append(TabBindingUpdate(noteID: note.id, binding: binding)) }
        }
        return updates
    }

    /// Open bindings from another Chrome run (or any run, when Chrome isn't running,
    /// `current == nil`) close and wait for one restore check. Run at launch and when the
    /// running Chrome changes.
    public static func closeStaleSessions(notes: [Note], current: String?, now: Date) -> [TabBindingUpdate] {
        notes.compactMap { note in
            guard var binding = note.tab, binding.browser == OpenTabsInventory.bundleID,
                  binding.closedAt == nil, binding.session != current else { return nil }
            binding.closedAt = now
            binding.pendingRestore = true
            return TabBindingUpdate(noteID: note.id, binding: binding)
        }
    }

    /// A new binding for the tab `ref` reports. Nil for an unknown session.
    public static func binding(for ref: TabRef, tab: BridgeTab) -> TabBinding? {
        guard ref.session != OpenTabsInventory.unknownSession else { return nil }
        return TabBinding(
            browser: ref.browser,
            profile: ref.profile,
            session: ref.session,
            tabID: ref.tabID,
            windowID: ref.windowID,
            index: tab.index,
            lastURL: strippingFragment(tab.url),
            lastTitle: tab.title.isEmpty ? nil : tab.title
        )
    }

    /// The binding after the user acknowledged a restore ("Keep on this tab", or a text
    /// edit). Nil when there is no badge to clear.
    public static func acknowledgingRestore(_ binding: TabBinding?) -> TabBinding? {
        guard var binding, binding.closedAt == nil, binding.pendingRestore else { return nil }
        binding.pendingRestore = false
        return binding
    }

    /// Whether the note shows the "Restored" badge.
    public static func isRestored(_ binding: TabBinding?) -> Bool {
        guard let binding else { return false }
        return binding.closedAt == nil && binding.pendingRestore
    }

    /// Re-binds a closed (or restored) binding to a live tab of the same browser and
    /// profile. Nil when the profile differs: changing it is not bookkeeping (§6.2).
    public static func reattaching(_ binding: TabBinding, to ref: TabRef, tab: BridgeTab) -> TabBinding? {
        guard binding.browser == ref.browser, binding.profile == ref.profile,
              var updated = Self.binding(for: ref, tab: tab) else { return nil }
        if updated.lastTitle == nil { updated.lastTitle = binding.lastTitle }
        if tab.url.isEmpty { updated.lastURL = binding.lastURL }
        return updated
    }

    static func close(_ binding: inout TabBinding, now: Date) {
        binding.closedAt = now
        binding.pendingRestore = false
    }

    /// Chrome briefly reports an empty URL and title while a tab loads; those never
    /// replace what the binding already knows.
    static func refresh(_ binding: inout TabBinding, url: String?, title: String?) {
        if let url, !url.isEmpty { binding.lastURL = strippingFragment(url) }
        if let title, !title.isEmpty { binding.lastTitle = title }
    }

    /// The URL without its `#fragment`; the query is kept.
    public static func strippingFragment(_ url: String) -> String {
        guard let hash = url.firstIndex(of: "#") else { return url }
        return String(url[..<hash])
    }
}
