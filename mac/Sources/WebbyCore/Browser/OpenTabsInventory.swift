import Foundation

/// Reduces bridge events into the set of open Chrome tabs the Library's Open Tabs
/// view shows. Each Chrome profile is owned by the connection that last spoke for it,
/// so a late `disconnected` from an old bridge cannot clear its replacement's tabs.
public struct OpenTabsInventory: Equatable, Sendable {
    /// The browser and app identifier written to `TabBinding.browser` and `Context`.
    public static let bundleID = "com.google.Chrome"

    private struct Window: Equatable, Sendable {
        var id: Int
        var focused: Bool
        var incognito: Bool
        var tabs: [BridgeTab]
    }

    private struct Profile: Equatable, Sendable {
        var connection: Int
        var windows: [Window] = []
    }

    private var profiles: [String: Profile] = [:]

    /// Identifies one run of Chrome, the `session` of every tab binding. Changing it
    /// drops all tabs, because tab IDs from the previous run no longer exist.
    public private(set) var session: String

    /// `unknown` is used until the app can name the running browser.
    public static let unknownSession = "unknown"

    public init(session: String = OpenTabsInventory.unknownSession) {
        self.session = session
    }

    public mutating func setSession(_ session: String) {
        guard self.session != session else { return }
        self.session = session
        profiles.removeAll()
    }

    /// The open tabs, windows ordered by profile key, then by Chrome's window order.
    public var inventory: LibraryInventory {
        var windows: [LibraryInventoryWindow] = []
        for key in profiles.keys.sorted() {
            guard let profile = profiles[key] else { continue }
            for (order, window) in profile.windows.enumerated() {
                windows.append(LibraryInventoryWindow(
                    browser: Self.bundleID,
                    profile: key,
                    session: session,
                    appBundleID: Self.bundleID,
                    windowID: window.id,
                    order: order,
                    focused: window.focused,
                    incognito: window.incognito,
                    tabs: window.tabs.enumerated().map { index, tab in
                        LibraryInventoryTab(
                            tabID: tab.id,
                            index: index,
                            active: tab.active,
                            url: tab.url.isEmpty ? nil : tab.url,
                            title: tab.title.isEmpty ? nil : tab.title
                        )
                    }
                ))
            }
        }
        return LibraryInventory(windows: windows)
    }

    /// Applies an event and returns whether the inventory changed.
    @discardableResult
    public mutating func receive(_ event: BridgeEvent) -> Bool {
        let before = profiles
        switch event {
        case .connected:
            break
        case .message(let connection, let key, let message):
            apply(message, connection: connection, key: key)
        case .disconnected(let connection, let key):
            if let key {
                if profiles[key]?.connection == connection { profiles[key] = nil }
            } else {
                profiles = profiles.filter { $0.value.connection != connection }
            }
        case .dropped(let connection, _):
            if let connection {
                profiles = profiles.filter { $0.value.connection != connection }
            }
        }
        return profiles != before
    }

    private mutating func apply(_ message: ExtensionMessage, connection: Int, key: String) {
        if profiles[key]?.connection != connection {
            // A newer bridge for this profile starts from nothing; its inventory follows.
            profiles[key] = Profile(connection: connection)
        }
        guard var profile = profiles[key] else { return }
        switch message {
        case .hello:
            break
        case .inventory(let windows):
            profile.windows = windows.map {
                Window(id: $0.id, focused: $0.focused, incognito: $0.incognito, tabs: $0.tabs)
            }
        case .active(let windowID, let incognito, let tab):
            var activated = tab
            activated.active = true
            if let id = profile.windows.firstIndex(where: { $0.id == windowID }) {
                profile.windows[id].incognito = incognito
            } else {
                // The window may be new and not yet in an inventory.
                profile.windows.append(Window(id: windowID, focused: false, incognito: incognito, tabs: []))
            }
            Self.remove(tabID: tab.id, from: &profile)
            if let id = profile.windows.firstIndex(where: { $0.id == windowID }) {
                for t in profile.windows[id].tabs.indices { profile.windows[id].tabs[t].active = false }
                Self.insert(activated, at: tab.index, in: &profile.windows[id])
            }
        case .tabCreated(let created):
            // A tab of an unknown window waits for the inventory or `active` that names it.
            guard let id = profile.windows.firstIndex(where: { $0.id == created.windowId }) else { break }
            Self.remove(tabID: created.id, from: &profile)
            let tab = BridgeTab(
                id: created.id,
                index: created.index,
                active: false,
                url: created.url ?? "",
                title: created.title ?? "",
                openerTabId: created.openerTabId
            )
            Self.insert(tab, at: created.index, in: &profile.windows[id])
        case .tabUpdated(let tabID, let url, let title):
            for w in profile.windows.indices {
                for t in profile.windows[w].tabs.indices where profile.windows[w].tabs[t].id == tabID {
                    if let url { profile.windows[w].tabs[t].url = url }
                    if let title { profile.windows[w].tabs[t].title = title }
                }
            }
        case .tabClosed(let tabID, _):
            Self.remove(tabID: tabID, from: &profile)
        case .tabMoved(let tabID, let windowID, let index):
            guard let tab = profile.windows.lazy.flatMap(\.tabs).first(where: { $0.id == tabID }) else { break }
            Self.remove(tabID: tabID, from: &profile)
            if let id = profile.windows.firstIndex(where: { $0.id == windowID }) {
                Self.insert(tab, at: index, in: &profile.windows[id])
            }
        case .tabReplaced(let added, let removed):
            // Chrome swaps a prerendered tab in under a new ID at the same position.
            for w in profile.windows.indices {
                for t in profile.windows[w].tabs.indices where profile.windows[w].tabs[t].id == removed {
                    profile.windows[w].tabs[t].id = added
                }
            }
        }
        // A closed window sends no event of its own, so empty windows go.
        profile.windows.removeAll { $0.tabs.isEmpty }
        profiles[key] = profile
    }

    private static func insert(_ tab: BridgeTab, at index: Int, in window: inout Window) {
        window.tabs.insert(tab, at: min(max(index, 0), window.tabs.count))
    }

    private static func remove(tabID: Int, from profile: inout Profile) {
        for w in profile.windows.indices {
            profile.windows[w].tabs.removeAll { $0.id == tabID }
        }
    }
}
