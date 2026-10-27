import Foundation

// Extension protocol v1 (plan.md §5.1.7). Messages are flat JSON objects with a `type`
// field. Decoding validates every message, because browser input is untrusted.
// `extension/tests/fixtures/` holds one example of each message; the Swift and Node
// tests both check against those files.

/// A Chrome tab as the extension reports it in `inventory` and `active`.
public struct BridgeTab: Codable, Equatable, Sendable {
    public var id: Int
    public var index: Int
    public var active: Bool
    public var url: String
    public var title: String
    public var openerTabId: Int?
    public var groupId: Int?
    /// Milliseconds since 1970, as Chrome reports it.
    public var lastAccessed: Double?

    public init(
        id: Int,
        index: Int,
        active: Bool,
        url: String,
        title: String,
        openerTabId: Int? = nil,
        groupId: Int? = nil,
        lastAccessed: Double? = nil
    ) {
        self.id = id
        self.index = index
        self.active = active
        self.url = url
        self.title = title
        self.openerTabId = openerTabId
        self.groupId = groupId
        self.lastAccessed = lastAccessed
    }
}

/// A window's frame as `chrome.windows` reports it.
public struct BridgeWindowBounds: Codable, Equatable, Sendable {
    public var left: Int
    public var top: Int
    public var width: Int
    public var height: Int

    public init(left: Int, top: Int, width: Int, height: Int) {
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }
}

public struct BridgeWindow: Codable, Equatable, Sendable {
    public var id: Int
    public var focused: Bool
    public var incognito: Bool
    public var bounds: BridgeWindowBounds?
    public var tabs: [BridgeTab]

    public init(id: Int, focused: Bool, incognito: Bool, bounds: BridgeWindowBounds? = nil, tabs: [BridgeTab]) {
        self.id = id
        self.focused = focused
        self.incognito = incognito
        self.bounds = bounds
        self.tabs = tabs
    }
}

public struct BridgeHello: Equatable, Sendable {
    /// Protocol version; must equal `BridgeConstants.protocolVersion`.
    public var v: Int
    /// The Chrome profile's key: a UUID the extension keeps in `chrome.storage.local`.
    public var profile: String
    public var extVersion: String
    public var incognitoAllowed: Bool

    public init(v: Int = BridgeConstants.protocolVersion, profile: String, extVersion: String, incognitoAllowed: Bool) {
        self.v = v
        self.profile = profile
        self.extVersion = extVersion
        self.incognitoAllowed = incognitoAllowed
    }
}

/// A tab as `tabs.onCreated` reports it. URL and title are often not known yet.
public struct BridgeCreatedTab: Codable, Equatable, Sendable {
    public var id: Int
    public var windowId: Int
    public var index: Int
    public var url: String?
    public var title: String?
    public var openerTabId: Int?

    public init(id: Int, windowId: Int, index: Int, url: String? = nil, title: String? = nil, openerTabId: Int? = nil) {
        self.id = id
        self.windowId = windowId
        self.index = index
        self.url = url
        self.title = title
        self.openerTabId = openerTabId
    }
}

/// A message from the extension, relayed by the bridge to the app.
public enum ExtensionMessage: Equatable, Sendable {
    case hello(BridgeHello)
    case inventory(windows: [BridgeWindow])
    /// `incognito` is the tab's window mode, so the app can ignore incognito pages (§5.1.8)
    /// even for a window the last inventory didn't include.
    case active(windowId: Int, incognito: Bool, tab: BridgeTab)
    case tabCreated(BridgeCreatedTab)
    case tabUpdated(tabId: Int, url: String?, title: String?)
    case tabClosed(tabId: Int, windowClosing: Bool)
    case tabMoved(tabId: Int, windowId: Int, index: Int)
    case tabReplaced(added: Int, removed: Int)

    public var type: String {
        switch self {
        case .hello: return "hello"
        case .inventory: return "inventory"
        case .active: return "active"
        case .tabCreated: return "tabCreated"
        case .tabUpdated: return "tabUpdated"
        case .tabClosed: return "tabClosed"
        case .tabMoved: return "tabMoved"
        case .tabReplaced: return "tabReplaced"
        }
    }

    public static func decode(_ data: Data) throws -> ExtensionMessage {
        try JSONDecoder().decode(ExtensionMessage.self, from: data)
    }

    public func encoded() throws -> Data {
        try JSONEncoder.bridge.encode(self)
    }
}

/// A command from the app, relayed by the bridge to the extension.
public enum AppCommand: Equatable, Sendable {
    /// Send `hello`, `inventory` and `active` again.
    case resend
    /// Open the URLs as tabs of one new window. Only http and https URLs are allowed.
    case openTabs(urls: [String])
    /// Activate the tab and focus its window.
    case focusTab(id: Int)

    public var type: String {
        switch self {
        case .resend: return "resend"
        case .openTabs: return "openTabs"
        case .focusTab: return "focusTab"
        }
    }

    public static func decode(_ data: Data) throws -> AppCommand {
        try JSONDecoder().decode(AppCommand.self, from: data)
    }

    public func encoded() throws -> Data {
        try validate()
        return try JSONEncoder.bridge.encode(self)
    }
}

public enum BridgeMessageError: Error, Equatable, CustomStringConvertible {
    case unknownType(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .unknownType(let type): return "unknown message type \"\(type)\""
        case .invalid(let reason): return reason
        }
    }
}

// MARK: - Coding

private enum MessageKeys: String, CodingKey {
    case type
    case v, profile, extVersion, incognitoAllowed
    case windows, windowId, incognito, tab
    case tabId, url, title, windowClosing, index, added, removed
    case urls, id
}

extension ExtensionMessage: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: MessageKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            self = .hello(BridgeHello(
                v: try c.decode(Int.self, forKey: .v),
                profile: try c.decode(String.self, forKey: .profile),
                extVersion: try c.decode(String.self, forKey: .extVersion),
                incognitoAllowed: try c.decode(Bool.self, forKey: .incognitoAllowed)
            ))
        case "inventory":
            self = .inventory(windows: try c.decode([BridgeWindow].self, forKey: .windows))
        case "active":
            self = .active(
                windowId: try c.decode(Int.self, forKey: .windowId),
                incognito: try c.decode(Bool.self, forKey: .incognito),
                tab: try c.decode(BridgeTab.self, forKey: .tab)
            )
        case "tabCreated":
            self = .tabCreated(try c.decode(BridgeCreatedTab.self, forKey: .tab))
        case "tabUpdated":
            self = .tabUpdated(
                tabId: try c.decode(Int.self, forKey: .tabId),
                url: try c.decodeIfPresent(String.self, forKey: .url),
                title: try c.decodeIfPresent(String.self, forKey: .title)
            )
        case "tabClosed":
            self = .tabClosed(
                tabId: try c.decode(Int.self, forKey: .tabId),
                windowClosing: try c.decode(Bool.self, forKey: .windowClosing)
            )
        case "tabMoved":
            self = .tabMoved(
                tabId: try c.decode(Int.self, forKey: .tabId),
                windowId: try c.decode(Int.self, forKey: .windowId),
                index: try c.decode(Int.self, forKey: .index)
            )
        case "tabReplaced":
            self = .tabReplaced(
                added: try c.decode(Int.self, forKey: .added),
                removed: try c.decode(Int.self, forKey: .removed)
            )
        default:
            throw BridgeMessageError.unknownType(type)
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: MessageKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .hello(let hello):
            try c.encode(hello.v, forKey: .v)
            try c.encode(hello.profile, forKey: .profile)
            try c.encode(hello.extVersion, forKey: .extVersion)
            try c.encode(hello.incognitoAllowed, forKey: .incognitoAllowed)
        case .inventory(let windows):
            try c.encode(windows, forKey: .windows)
        case .active(let windowId, let incognito, let tab):
            try c.encode(windowId, forKey: .windowId)
            try c.encode(incognito, forKey: .incognito)
            try c.encode(tab, forKey: .tab)
        case .tabCreated(let tab):
            try c.encode(tab, forKey: .tab)
        case .tabUpdated(let tabId, let url, let title):
            try c.encode(tabId, forKey: .tabId)
            try c.encodeIfPresent(url, forKey: .url)
            try c.encodeIfPresent(title, forKey: .title)
        case .tabClosed(let tabId, let windowClosing):
            try c.encode(tabId, forKey: .tabId)
            try c.encode(windowClosing, forKey: .windowClosing)
        case .tabMoved(let tabId, let windowId, let index):
            try c.encode(tabId, forKey: .tabId)
            try c.encode(windowId, forKey: .windowId)
            try c.encode(index, forKey: .index)
        case .tabReplaced(let added, let removed):
            try c.encode(added, forKey: .added)
            try c.encode(removed, forKey: .removed)
        }
    }
}

extension AppCommand: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: MessageKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "resend":
            self = .resend
        case "openTabs":
            self = .openTabs(urls: try c.decode([String].self, forKey: .urls))
        case "focusTab":
            self = .focusTab(id: try c.decode(Int.self, forKey: .id))
        default:
            throw BridgeMessageError.unknownType(type)
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: MessageKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .resend:
            break
        case .openTabs(let urls):
            try c.encode(urls, forKey: .urls)
        case .focusTab(let id):
            try c.encode(id, forKey: .id)
        }
    }
}

extension JSONEncoder {
    fileprivate static var bridge: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

// MARK: - Validation

/// Chrome's own URL length limit.
private let maxURLLength = 2 * 1024 * 1024
private let maxTitleLength = 64 * 1024
private let maxVersionLength = 64

private func requireID(_ value: Int, _ field: String) throws {
    guard value >= 0 else { throw BridgeMessageError.invalid("\(field) must not be negative") }
}

private func requireLength(_ value: String?, max: Int, _ field: String) throws {
    guard let value else { return }
    guard value.utf8.count <= max else { throw BridgeMessageError.invalid("\(field) is longer than \(max) bytes") }
}

extension BridgeTab {
    fileprivate func validate() throws {
        try requireID(id, "tab id")
        try requireID(index, "tab index")
        try requireLength(url, max: maxURLLength, "tab url")
        try requireLength(title, max: maxTitleLength, "tab title")
        if let openerTabId { try requireID(openerTabId, "openerTabId") }
        if let groupId { try requireID(groupId, "groupId") }
    }
}

extension ExtensionMessage {
    fileprivate func validate() throws {
        switch self {
        case .hello(let hello):
            guard hello.v == BridgeConstants.protocolVersion else {
                throw BridgeMessageError.invalid("unsupported protocol version \(hello.v)")
            }
            guard UUID(uuidString: hello.profile) != nil else {
                throw BridgeMessageError.invalid("profile is not a UUID")
            }
            try requireLength(hello.extVersion, max: maxVersionLength, "extVersion")
        case .inventory(let windows):
            for window in windows {
                try requireID(window.id, "window id")
                for tab in window.tabs { try tab.validate() }
            }
        case .active(let windowId, _, let tab):
            try requireID(windowId, "windowId")
            try tab.validate()
        case .tabCreated(let tab):
            try requireID(tab.id, "tab id")
            try requireID(tab.windowId, "windowId")
            try requireID(tab.index, "tab index")
            try requireLength(tab.url, max: maxURLLength, "tab url")
            try requireLength(tab.title, max: maxTitleLength, "tab title")
            if let openerTabId = tab.openerTabId { try requireID(openerTabId, "openerTabId") }
        case .tabUpdated(let tabId, let url, let title):
            try requireID(tabId, "tabId")
            try requireLength(url, max: maxURLLength, "url")
            try requireLength(title, max: maxTitleLength, "title")
        case .tabClosed(let tabId, _):
            try requireID(tabId, "tabId")
        case .tabMoved(let tabId, let windowId, let index):
            try requireID(tabId, "tabId")
            try requireID(windowId, "windowId")
            try requireID(index, "index")
        case .tabReplaced(let added, let removed):
            try requireID(added, "added")
            try requireID(removed, "removed")
        }
    }
}

extension AppCommand {
    fileprivate func validate() throws {
        switch self {
        case .resend:
            break
        case .openTabs(let urls):
            guard !urls.isEmpty else { throw BridgeMessageError.invalid("openTabs needs at least one URL") }
            for url in urls {
                try requireLength(url, max: maxURLLength, "url")
                guard let scheme = URLComponents(string: url)?.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                    throw BridgeMessageError.invalid("openTabs only opens http and https URLs")
                }
            }
        case .focusTab(let id):
            try requireID(id, "id")
        }
    }
}
