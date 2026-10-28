/// The live browser tab that a context reports.
///
/// Equality includes every field, but ``matches(_:)`` deliberately ignores
/// `windowID`: Chrome assigns a new window ID when a tab moves between windows,
/// and a "Just this tab" note must keep following that tab.
public struct TabRef: Hashable, Sendable {
    public var browser: String
    public var profile: String
    public var session: String
    public var tabID: Int
    public var windowID: Int

    public init(
        browser: String,
        profile: String,
        session: String,
        tabID: Int,
        windowID: Int
    ) {
        self.browser = browser
        self.profile = profile
        self.session = session
        self.tabID = tabID
        self.windowID = windowID
    }

    /// Matches a stored binding by browser, profile, session and tab ID.
    public func matches(_ binding: TabBinding) -> Bool {
        browser == binding.browser
            && profile == binding.profile
            && session == binding.session
            && tabID == binding.tabID
    }
}
