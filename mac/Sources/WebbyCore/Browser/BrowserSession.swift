import Foundation
import CoreGraphics

/// A replayable projection of bridge events. Connection ownership prevents a late
/// disconnect from an old bridge from clearing its replacement's profile.
public struct BrowserSession: Sendable {
    public static let bundleID = "com.google.Chrome"
    private struct Profile: Sendable {
        var connection: Int
        var windows: [BridgeWindow] = []
    }
    private var profiles: [String: Profile] = [:]
    public private(set) var identity: String?

    public init() {}

    public mutating func setIdentity(_ identity: String?) {
        guard self.identity != identity else { return }
        self.identity = identity
        profiles.removeAll()
    }

    public mutating func receive(_ event: BridgeEvent) {
        switch event {
        case .message(let connection, let key, let message):
            if case .hello = message {
                if profiles[key]?.connection != connection {
                    profiles[key] = Profile(connection: connection)
                }
                return
            }
            guard var profile = profiles[key], profile.connection == connection else { return }
            switch message {
            case .inventory(let windows):
                profile.windows = windows
            case .active(let windowID, let incognito, let tab):
                // Activation within a background window must not steal global focus.
                guard let index = profile.windows.firstIndex(where: { $0.id == windowID }) else {
                    // Focus may have reached a newly created window before its inventory.
                    // Retaining the old window here can leak its page at identical bounds.
                    for i in profile.windows.indices { profile.windows[i].focused = false }
                    profiles[key] = profile
                    return
                }
                profile.windows[index].incognito = incognito
                for i in profile.windows[index].tabs.indices {
                    profile.windows[index].tabs[i].active = false
                }
                profile.windows[index].tabs.removeAll { $0.id == tab.id }
                var active = tab
                active.active = true
                profile.windows[index].tabs.append(active)
            case .tabUpdated(let id, let url, let title):
                for w in profile.windows.indices {
                    for t in profile.windows[w].tabs.indices where profile.windows[w].tabs[t].id == id {
                        if let url { profile.windows[w].tabs[t].url = url }
                        if let title { profile.windows[w].tabs[t].title = title }
                    }
                }
            case .tabClosed(let id, _):
                for w in profile.windows.indices { profile.windows[w].tabs.removeAll { $0.id == id } }
            case .tabReplaced(_, let removed):
                // A fresh snapshot supplies the replacement's URL; never inherit stale identity.
                for w in profile.windows.indices { profile.windows[w].tabs.removeAll { $0.id == removed } }
            case .tabMoved(let id, _, _):
                for w in profile.windows.indices { profile.windows[w].tabs.removeAll { $0.id == id } }
            case .tabCreated, .hello:
                break
            }
            profiles[key] = profile
        case .disconnected(let connection, let key):
            if let key, profiles[key]?.connection == connection { profiles.removeValue(forKey: key) }
        case .dropped(let connection, _):
            if let connection { profiles = profiles.filter { $0.value.connection != connection } }
        case .connected:
            break
        }
    }

    /// Unknown, ambiguous, private, or mismatched windows deliberately get app context.
    /// AX and Chrome both report top-left screen coordinates in logical points on macOS.
    public func context(focusedFrame: CGRect?, queryRules: [QueryRule]) -> Context {
        let fallback = Context(appBundleID: Self.bundleID)
        guard let identity, let focusedFrame else { return fallback }
        let candidates = profiles.flatMap { key, profile in
            profile.windows.filter(\.focused).map { (key, $0) }
        }
        guard candidates.count == 1, let (key, window) = candidates.first,
              !window.incognito, let bounds = window.bounds,
              Self.matches(bounds, focusedFrame),
              window.tabs.filter(\.active).count == 1,
              let tab = window.tabs.first(where: \.active),
              let page = PageURL(string: tab.url, queryRules: queryRules) else { return fallback }
        return Context(appBundleID: Self.bundleID, page: page, tab: TabRef(
            browser: Self.bundleID, profile: key, session: identity, tabID: tab.id, windowID: window.id
        ))
    }

    private static func matches(_ bounds: BridgeWindowBounds, _ frame: CGRect) -> Bool {
        abs(Double(bounds.left) - frame.minX) <= 2 && abs(Double(bounds.top) - frame.minY) <= 2
            && abs(Double(bounds.width) - frame.width) <= 2 && abs(Double(bounds.height) - frame.height) <= 2
    }
}
