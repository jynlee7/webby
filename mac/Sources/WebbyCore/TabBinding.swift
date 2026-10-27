import Foundation

/// A Chrome tab that a note is attached to ("Just this tab").
public struct TabBinding: Hashable, Codable, Sendable {
    public var browser: String
    public var profile: String
    public var session: String
    public var tabID: Int
    public var windowID: Int
    public var index: Int
    public var lastURL: String
    public var lastTitle: String?
    public var closedAt: Date?
    public var pendingRestore: Bool

    public init(
        browser: String,
        profile: String,
        session: String,
        tabID: Int,
        windowID: Int,
        index: Int,
        lastURL: String,
        lastTitle: String? = nil,
        closedAt: Date? = nil,
        pendingRestore: Bool = false
    ) {
        self.browser = browser
        self.profile = profile
        self.session = session
        self.tabID = tabID
        self.windowID = windowID
        self.index = index
        self.lastURL = lastURL
        self.lastTitle = lastTitle
        self.closedAt = closedAt
        self.pendingRestore = pendingRestore
    }
}
