/// A snapshot of the open browser tabs used to build the Open Tabs view.
///
/// The inventory lists open tabs only. It is a pure input to Library grouping;
/// it does not mutate notes or store any browser state.
public struct LibraryInventory: Equatable, Sendable {
    public let windows: [LibraryInventoryWindow]

    public init(windows: [LibraryInventoryWindow] = []) {
        self.windows = windows
    }
}

public struct LibraryInventoryWindow: Equatable, Sendable {
    public let browser: String
    public let profile: String
    public let session: String
    public let appBundleID: String
    public let windowID: Int
    public let order: Int
    public let focused: Bool
    public let incognito: Bool
    public let tabs: [LibraryInventoryTab]

    public init(
        browser: String,
        profile: String,
        session: String,
        appBundleID: String,
        windowID: Int,
        order: Int,
        focused: Bool,
        incognito: Bool,
        tabs: [LibraryInventoryTab]
    ) {
        self.browser = browser
        self.profile = profile
        self.session = session
        self.appBundleID = appBundleID
        self.windowID = windowID
        self.order = order
        self.focused = focused
        self.incognito = incognito
        self.tabs = tabs
    }
}

public struct LibraryInventoryTab: Equatable, Sendable {
    public let tabID: Int
    public let index: Int
    public let active: Bool
    public let url: String?
    public let title: String?

    public init(
        tabID: Int,
        index: Int,
        active: Bool = false,
        url: String? = nil,
        title: String? = nil
    ) {
        self.tabID = tabID
        self.index = index
        self.active = active
        self.url = url
        self.title = title
    }
}
